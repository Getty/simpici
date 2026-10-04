use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Fcntl qw( LOCK_EX LOCK_UN );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX ();
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;
use Time::HiRes qw( sleep );

# A lease that ran out is ended by one step, whoever takes it: a request of a
# worker or the polling daemon. The run becomes interrupted and its secret
# snapshot is removed, and a completion that arrives at the same moment is
# either accepted with its redacted log or refused, never both and never
# published as it came.

{
  # Lets the step happen at a chosen point inside another call, as a second
  # process would between two lines of this one.
  package InterleavedQueue;
  use Moo;
  extends 'SimpiCI::Queue';
  has before_finish => (is => 'rw');
  around finish => sub {
    my ( $orig, $self, @arguments ) = @_;
    if (my $step = $self->before_finish) {
      $self->before_finish(undef);
      $step->();
    }
    return $self->$orig(@arguments);
  };
  # Which runs were ended, by whichever process: one line for each time.
  has ended_log => (is => 'rw');
  around _expire_leases => sub {
    my ( $orig, $self, @records ) = @_;
    my @reports = $self->$orig(@records);
    $self->ended_log->append_utf8(map { $_->{run}."\n" } @reports) if $self->ended_log && @reports;
    return @reports;
  };
}

{
  package InterleavedDispatcher;
  use Moo;
  extends 'SimpiCI::Dispatcher';
  has before_snapshot => (is => 'rw');
  has steps => (is => 'rw', default => sub { 0 });
  around _snapshot => sub {
    my ( $orig, $self, @arguments ) = @_;
    if (my $step = $self->before_snapshot) {
      $self->before_snapshot(undef);
      $step->();
    }
    return $self->$orig(@arguments);
  };
  around expire_leases => sub {
    my ( $orig, $self, @arguments ) = @_;
    $self->steps($self->steps + 1);
    return $self->$orig(@arguments);
  };
}

{
  # Dies in place of one write, once: a process that is killed there.
  package CrashingStore;
  use Moo;
  extends 'SimpiCI::Store';
  has crash_on => (is => 'rw');
  around write_json => sub {
    my ( $orig, $self, $relative, $value ) = @_;
    my $pattern = $self->crash_on;
    if ($pattern && $relative =~ $pattern) {
      $self->crash_on(undef);
      Carp::croak('killed before '.$relative.' was written');
    }
    return $self->$orig($relative, $value);
  };
}

umask 0077;
my $json = JSON::MaybeXS->new;
my $value = 'lease-secret-value';
my $success = { state => 'success', exit_code => 0 };

my $commit = 0;
sub setup {
  my ( %option ) = @_;
  my $root = tempdir;
  my $store = ( $option{store_class} // 'SimpiCI::Store' )->new(root => $root);
  my $queue = ( $option{queue_class} // 'SimpiCI::Queue' )->new(store => $store);
  my $token = $root->child('token');
  $token->spew_utf8($value."\n");
  my $dispatcher = ( $option{dispatcher_class} // 'SimpiCI::Dispatcher' )->new(
    queue => $queue, config => {
      repositories => [{ name => 'owner/repo', clone_url => '/fixture', secrets => [{
        name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
      }] }]
    });
  return ( $root, $queue, $dispatcher, $token );
}

sub enqueue {
  my ( $queue ) = @_;
  return $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
    repository => 'owner/repo', clone_url => '/fixture', ref => 'refs/heads/main',
    commit => sprintf('%040x', ++$commit)))->{run};
}

sub finish {
  my ( $claim, %override ) = @_;
  return { operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => $success, log => 'token='.$value."\n", %override };
}

sub record { $json->decode($_[0]->child('queue/'.$_[1].'.json')->slurp_utf8) }

sub report { $json->decode($_[0]->child('public/runs/'.$_[1].'.json')->slurp_utf8) }

sub expire {
  my ( $root, $run, $at ) = @_;
  my $record = record($root, $run);
  $record->{expires} = $at // time - 1;
  SimpiCI::Store->new(root => $root)->write_json('queue/'.$run.'.json', $record);
}

sub everything_below {
  my ( $root ) = @_;
  my $content = '';
  $root->visit(sub { $content .= $_->slurp_raw if $_->is_file && $_->basename ne 'token' },
    { recurse => 1 });
  return $content;
}

subtest 'the queue ends the leases that ran out' => sub {
  my ( $root, $queue ) = setup();
  ok $queue->can('expire_leases'), 'SimpiCI::Queue can expire leases' or return;
  is [ $queue->expire_leases ], [], 'none in a queue without a run';
  enqueue($queue) for 1 .. 4;
  my @claim = map { $queue->claim('vm'.$_) } 1 .. 3;
  is [ map { $_->{run} } @claim ], [ 1, 2, 3 ], 'three runs are leased, a fourth is queued';
  $queue->finish('vm3', 3, $claim[2]{token}, $success, "done\n");
  my %before = map { $_ => $root->child('queue/'.$_.'.json')->slurp_raw } 1 .. 4;
  is [ $queue->expire_leases ], [], 'none while every lease stands';
  is { map { $_ => $root->child('queue/'.$_.'.json')->slurp_raw } 1 .. 4 }, \%before,
    'and no run is written for it';

  expire($root, 1);
  # A completed run keeps the end of its lease: that it is over means nothing.
  expire($root, 3);
  my @ended = $queue->expire_leases;
  is [ map { $_->{run} } @ended ], [1], 'the one whose lease ran out is returned';
  is $ended[0]{state}, 'interrupted', 'as the report of an interrupted run';
  is $ended[0], report($root, 1), 'which is the one that is published';
  is [ map { record($root, $_)->{state} } 1 .. 4 ], [qw( interrupted running success queued )],
    'the leased, the completed and the queued run stay as they were';
  ok !exists record($root, 1)->{result}, 'an interrupted run has no result';
  is [ $queue->expire_leases ], [], 'a second call finds nothing to end';

  like dies { $queue->finish('vm1', 1, $claim[0]{token}, $success, 'late') }, qr/expired claim/,
    'the completion of the interrupted run is refused';
  ok !$root->child('public/runs/1.log')->exists, 'and publishes no log';
  is $queue->claim('vm4')->{run}, 4, 'the queued run is claimed, not the interrupted one';
  expire($root, 2);
  expire($root, 4);
  is [ map { $_->{run} } $queue->expire_leases ], [ 2, 4 ], 'every expired lease is ended at once';
};

subtest 'a claim ends them with the same step' => sub {
  my ( $root, $queue ) = setup();
  enqueue($queue) for 1 .. 2;
  $queue->claim('vm1');
  $queue->claim('vm2');
  # An expired lease behind a queued run: no claim leaves them in that order,
  # a queue entry that was put back by hand does.
  expire($root, 2);
  my $first = record($root, 1);
  SimpiCI::Store->new(root => $root)->write_json('queue/1.json',
    { ( map { $_ => $first->{$_} } qw( run key event ) ), state => 'queued' });
  is $queue->claim('vm3')->{run}, 1, 'the claim takes the queued run';
  is record($root, 2)->{state}, 'interrupted', 'and has ended the expired lease behind it';
};

subtest 'the dispatcher removes the snapshot with it' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  ok $dispatcher->can('expire_leases'), 'SimpiCI::Dispatcher can expire leases' or return;
  enqueue($queue) for 1 .. 2;
  my @claim = map { $dispatcher->request('vm'.$_, { operation => 'claim' }) } 1 .. 2;
  is [ $dispatcher->expire_leases ], [], 'nothing is ended while the leases stand';
  ok $root->child('claims/'.$_.'.json')->is_file, 'run '.$_.' keeps its snapshot' for 1 .. 2;

  expire($root, 1);
  my @ended = $dispatcher->expire_leases;
  is [ map { [ $_->@{qw( run state )} ] } @ended ], [ [ 1, 'interrupted' ] ],
    'the expired run is returned as interrupted';
  is record($root, 1)->{state}, 'interrupted', 'and recorded so, with no worker asking';
  is report($root, 1)->{state}, 'interrupted', 'the published report says the same';
  ok !$root->child('claims/1.json')->exists, 'its snapshot is removed';
  ok $root->child('claims/2.json')->is_file, 'that of the leased run stays';
  unlike everything_below($root->child('public')), qr/\Q$value\E/, 'nothing public holds the value';

  is $dispatcher->request('vm1', finish($claim[0])), { rejected => 'expired claim' },
    'the late completion is refused';
  ok !$root->child('public/runs/1.log')->exists, 'and publishes no log';
  is $dispatcher->request('vm2', finish($claim[1]))->{state}, 'success',
    'the leased run is completed';
  is $root->child('public/runs/2.log')->slurp_utf8, "token=[REDACTED]\n", 'with its log redacted';
  unlike everything_below($root), qr/\Q$value\E/, 'no file of the state holds the value any more';
};

subtest 'every request takes the same step first' => sub {
  my ( $root, $queue, $dispatcher, $token ) = setup(dispatcher_class => 'InterleavedDispatcher');
  enqueue($queue) for 1 .. 3;
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  is $dispatcher->steps, 1, 'a claim';
  expire($root, 1);
  is $dispatcher->request('vm', finish($claim)), { rejected => 'expired claim' },
    'a completion that is refused';
  is $dispatcher->steps, 2, 'takes it too';
  is record($root, 1)->{state}, 'interrupted', 'so the run it came too late for is interrupted';
  ok !$root->child('claims/1.json')->exists, 'and its snapshot is removed';

  my $second = $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 2);
  $token->remove;
  like dies { $dispatcher->request('other', { operation => 'claim' }) }, qr/cannot read secret file/,
    'a claim that fails on an unusable grant';
  is record($root, 2)->{state}, 'interrupted', 'has ended the expired lease before that';
  ok !$root->child('claims/2.json')->exists, 'and removed its snapshot';
  is record($root, 3)->{state}, 'queued', 'without taking a lease';
};

subtest 'a lease that is ended while its completion is served' => sub {
  for my $case (
    [ 'before the snapshot is read', 'before_snapshot', sub { $_[1] } ],
    [ 'after the log is redacted',   'before_finish',   sub { $_[0] } ]
  ) {
    my ( $name, $hook, $holder ) = @$case;
    my ( $root, $queue, $dispatcher ) = setup(
      queue_class => 'InterleavedQueue', dispatcher_class => 'InterleavedDispatcher');
    enqueue($queue);
    my $claim = $dispatcher->request('vm', { operation => 'claim' });
    # What the daemon does in another process, once the lease has run out.
    my @ended;
    $holder->($queue, $dispatcher)->$hook(sub {
      expire($root, 1);
      @ended = SimpiCI::Dispatcher->new(queue => SimpiCI::Queue->new(store => $queue->store),
        config => $dispatcher->config)->expire_leases;
    });
    my $response;
    my $died = dies { $response = $dispatcher->request('vm', finish($claim)) };
    is [ map { $_->{run} } @ended ], [1], $name.': the daemon ends the lease';
    like $died, qr/SimpiCI::Queue expired claim/, $name.': the completion fails';
    is $response, undef, $name.': and is not answered as accepted';
    is record($root, 1)->{state}, 'interrupted', $name.': the run stays interrupted';
    ok !exists record($root, 1)->{result}, $name.': without a result';
    ok !$root->child('public/runs/1.log')->exists, $name.': no log is published';
    ok !$root->child('claims/1.json')->exists, $name.': the snapshot is gone';
    unlike everything_below($root), qr/\Q$value\E/, $name.': nothing holds the value';
    is $dispatcher->request('vm', finish($claim)), { rejected => 'expired claim' },
      $name.': the worker sends it again and is refused for good';
    ok !$root->child('public/runs/1.log')->exists, $name.': still without a log';
  }
};

subtest 'the step waits for the lock of the queue' => sub {
  # A completion is recorded under that lock. While somebody holds it, the
  # step ends nothing: it decides after the other one, not beside it.
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 1);
  open my $lock, '>>', $root->child('queue.lock')->stringify or croak 'cannot open the queue lock';
  flock $lock, LOCK_EX or croak 'cannot lock the queue';
  my $done = $root->child('done');
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    my @ended = eval { $queue->expire_leases };
    $done->spew_utf8(join ' ', map { $_->{run} } @ended);
    POSIX::_exit(0);
  }
  sleep 0.5;
  ok !$done->exists, 'the step has not returned while the queue is locked';
  is record($root, 1)->{state}, 'running', 'and has ended nothing';
  flock $lock, LOCK_UN;
  waitpid($pid, 0);
  is $done->slurp_utf8, '1', 'it ends the lease once the lock is free';
  is record($root, 1)->{state}, 'interrupted', 'and the run is interrupted';
};

subtest 'a step that is cut off' => sub {
  # The daemon is stopped and started at any moment. Wherever the step ends,
  # the next one finishes it: the run is not left running in its report.
  for my $case (
    [ 'before anything is written', qr{\A(?:queue|public/runs)/1\.json\z} ],
    [ 'before the queue has it',    qr{\Aqueue/1\.json\z} ],
    [ 'before the report has it',   qr{\Apublic/runs/1\.json\z} ]
  ) {
    my ( $name, $write ) = @$case;
    my ( $root, $queue, $dispatcher ) = setup(store_class => 'CrashingStore');
    enqueue($queue);
    my $claim = $dispatcher->request('vm', { operation => 'claim' });
    expire($root, 1);
    $queue->store->crash_on($write);
    like dies { $dispatcher->expire_leases }, qr/killed before \S+ was written/,
      $name.': the step is cut off';
    is $queue->store->crash_on, undef, $name.': at that write';
    ok $root->child('claims/1.json')->is_file, $name.': the snapshot is still there';
    is [ map { $_->{run} } $dispatcher->expire_leases ], [1], $name.': the next step ends the lease';
    is [ record($root, 1)->{state}, report($root, 1)->{state} ], [ 'interrupted', 'interrupted' ],
      $name.': queue and report agree that the run is interrupted';
    ok !$root->child('claims/1.json')->exists, $name.': and the snapshot is removed';
    is $dispatcher->request('vm', finish($claim)), { rejected => 'expired claim' },
      $name.': the late completion is refused';
    is [ $dispatcher->expire_leases ], [], $name.': and nothing is left to end';
  }
};

subtest 'a completion that was accepted first' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  is $dispatcher->request('vm', finish($claim))->{state}, 'success', 'is accepted';
  expire($root, 1);
  is [ $dispatcher->expire_leases ], [], 'the step does not end a run that has its result';
  is [ record($root, 1)->@{qw( state result )} ], [ 'success', $success ], 'the result stays';
  is report($root, 1)->{state}, 'success', 'and so does the report';
  is $root->child('public/runs/1.log')->slurp_utf8, "token=[REDACTED]\n", 'and the log';
  is $dispatcher->request('vm', finish($claim))->{state}, 'success',
    'the completion can still be repeated';
};

subtest 'completions and the step at the same time' => sub {
  my ( $root, $queue, $dispatcher ) = setup(queue_class => 'InterleavedQueue');
  ok $dispatcher->can('expire_leases'), 'SimpiCI::Dispatcher can expire leases' or return;
  # The completions take the step too, as every request does: a lease is
  # ended by whoever sees first that it ran out, and by nobody after that.
  my $ended_log = $root->child('ended');
  $ended_log->touch;
  $queue->ended_log($ended_log);
  my $runs = 12;
  enqueue($queue) for 1 .. $runs;
  my @claim = map { $dispatcher->request('vm'.$_, { operation => 'claim' }) } 1 .. $runs;
  # Every lease runs out in the same second, while the completions arrive.
  my $end = time + 2;
  expire($root, $_, $end) for 1 .. $runs;
  my $answers = $root->child('answers');
  $answers->mkpath;
  my @children;
  for my $claim (@claim) {
    my $pid = fork;
    croak 'fork failed' unless defined $pid;
    unless ($pid) {
      # Spread over the fifth of a second before the end and the one after it.
      my $wait = $end - 0.2 + ( $claim->{run} - 1 ) * 0.4 / $runs - Time::HiRes::time();
      sleep $wait if $wait > 0;
      my $answer;
      for my $attempt (1 .. 2) {
        $answer = eval { $dispatcher->request($claim->{worker}, finish($claim)) };
        last if $answer;
      }
      $answers->child($claim->{run})->spew_utf8($json->encode($answer // { failed => 1 }));
      POSIX::_exit(0);
    }
    push @children, $pid;
  }
  # The daemon, in cycles that are far shorter than any real one.
  until (time > $end + 1) {
    $dispatcher->expire_leases;
    sleep 0.01;
  }
  waitpid($_, 0) for @children;
  $dispatcher->expire_leases;
  my %ended;
  $ended{$_}++ for $ended_log->lines_utf8({ chomp => 1 });

  my ( $accepted, $refused ) = ( 0, 0 );
  for my $run (1 .. $runs) {
    my $answer = $json->decode($answers->child($run)->slurp_utf8);
    my $record = record($root, $run);
    my $log = $root->child('public/runs/'.$run.'.log');
    if (( $answer->{state} // '' ) eq 'success') {
      $accepted++;
      is [ $record->{state}, $record->{result}, $ended{$run} // 0 ], [ 'success', $success, 0 ],
        'run '.$run.' was accepted: it has its result and was never ended';
      is $log->slurp_utf8, "token=[REDACTED]\n", 'run '.$run.': with its redacted log';
    }
    else {
      $refused++;
      is $answer, { rejected => 'expired claim' }, 'run '.$run.' was refused for its lease';
      is [ $record->{state}, exists $record->{result} ? 1 : 0, $ended{$run} // 0 ],
        [ 'interrupted', 0, 1 ], 'run '.$run.': it is interrupted, ended once and has no result';
      ok !$log->exists, 'run '.$run.': and no log';
    }
  }
  note $accepted.' accepted, '.$refused.' refused';
  is [ $root->child('claims')->children ], [], 'no snapshot is left';
  unlike everything_below($root), qr/\Q$value\E/, 'and no file of the state holds the value';
};

done_testing;
