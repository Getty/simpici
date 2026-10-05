use strict;
use warnings;
use Test2::V0;
use Carp qw( confess croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# A claim the worker cannot execute: no secret file stays behind, and the
# dispatcher hears a failed run with the reason instead of nothing. The reason
# is one of a list, for the log is published; what the error said is for
# standard error. t/78-worker-abort-reasons.t goes through the list.

{
  package TestWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has dispatcher => (is => 'ro');
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->dispatcher->request('vm', $request);
  }
}

{
  package FixedClaim;
  use Moo;
  has claim => (is => 'ro');
  has operations => (is => 'ro', default => sub { [] });
  sub request {
    my ( $self, $worker, $request ) = @_;
    push $self->operations->@*, $request->{operation};
    return $self->claim;
  }
}

{
  package AbortingWorker;
  use Moo;
  extends 'TestWorker';
  has raise => (is => 'ro');
  sub _run_claim { $_[0]->raise->() }
}

umask 0077;
my $json = JSON::MaybeXS->new;
my $secret = 'test-secret-value';
my $password = 'hunter2-in-url';

my $fixture = tempdir;
for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
    ['config', 'user.email', 'test@example.invalid']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
}
$fixture->child('tracked')->spew_utf8('exact revision');
for my $command (['add', '.'], ['commit', '-qm', 'fixture']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
}
my $commit = `git -C $fixture rev-parse HEAD`;
chomp $commit;

my $root = tempdir;
my $store = SimpiCI::Store->new(root => $root);
my $queue = SimpiCI::Queue->new(store => $store);
my $legacy_url = 'ftp://builder:'.$password.'@forge.invalid/legacy.git';

# Runs 1 and 2 are written by hand, as an older dispatcher or an operator
# would leave them: SimpiCI::Queue only enqueues what SimpiCI::Event accepts.
$store->allocate_run for 1 .. 2;
$store->write_json('queue/1.json', {
  run => 1, key => 'hand-written-1', state => 'queued',
  event => { source => 'git-poll', event => 'push', repository => 'legacy',
    clone_url => $legacy_url, ref => 'refs/heads/main', commit => 'a' x 40, payload => {} }
});
# The refused value is the secret itself here, so that the reason quotes it.
$store->write_json('queue/2.json', {
  run => 2, key => 'hand-written-2', state => 'queued',
  event => { source => $secret, event => 'push', repository => 'fixture',
    clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit, payload => {} }
});
is $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
  repository => 'fixture', clone_url => "$fixture", ref => 'refs/heads/main',
  commit => $commit))->{run}, 3, 'the accepted event is run 3';

my $token = $root->child('token');
$token->spew_utf8($secret);
my @grant = (secrets => [{
  name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
}]);
my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
  timeout => 10, repositories => [
    { name => 'legacy', clone_url => $legacy_url, @grant },
    { name => 'fixture', clone_url => "$fixture", @grant }
  ]
});

my $worker_root = tempdir;
my $executor = $worker_root->child('executor');
# Runs with the secret file in place, then turns the report of its own run
# into a directory: SimpiCI::Runner croaks when it publishes the final state.
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$SIMPICI_SECRETS_DIR/publish.env" ]]
cat "$SIMPICI_SECRETS_DIR/publish.env"
report="$CICD_WORKSPACE/../../public/runs/$CICD_RUN_NUMBER.json"
rm "$report"
mkdir "$report"
SCRIPT
$executor->chmod(0755);
my $worker_store = SimpiCI::Store->new(root => $worker_root);
my $worker = TestWorker->new(host => 'unused', store => $worker_store,
  runner => SimpiCI::Runner->new(store => $worker_store, runner_script => $executor),
  dispatcher => $dispatcher);

sub attempt {
  my ( $response, $error );
  my $warnings = warnings { $response = eval { $worker->once }; $error = $@ };
  return ( $response, $error, join('', @$warnings) );
}

sub report { $json->decode($root->child('public/runs/'.$_[0].'.json')->slurp_utf8) }

# Where Perl says an error was raised, " at FILE line N." after the message,
# or a file of this installation: the directories its modules and programs
# were loaded from, and the path of each of its modules below any directory.
# A module of somebody else that a job names is none of them.
my $raised_at = do {
  my @modules = grep { m{\ASimpiCI(?:/|\.pm\z)} } keys %INC;
  my %directory = map { path($_)->absolute->stringify => 1 } path('lib'), path('bin'),
    map { $INC{$_} =~ s{/\Q$_\E\z}{}r } @modules;
  my $files = join '|', map { quotemeta } sort( keys %directory ), sort @modules;
  qr/ at \S.* line \d+|$files/;
};
ok 'died at /opt/simpici/lib/SimpiCI/Worker.pm line 7.' =~ $raised_at
  && path('lib/SimpiCI/Runner.pm')->absolute->stringify =~ $raised_at
  && 'see SimpiCI/Store.pm' =~ $raised_at,
  'the pattern finds where an error was raised and a file of the installation';
ok 'cpanm installs Moo.pm and Path/Tiny.pm' !~ $raised_at, 'and takes no other module for one';

sub log_of {
  my $log = $root->child('public/runs/'.$_[0].'.log');
  return $log->is_file ? $log->slurp_utf8 : '';
}

subtest 'an event the worker refuses' => sub {
  my ( $response, $error, $warned ) = attempt();
  is $error, '', 'the refusal does not escape the worker';
  ok !$worker_root->child('secrets')->exists, 'no secret file is written for it';
  is report(1)->{state}, 'failed', 'the run is failed at the dispatcher';
  is report(1)->{exit_code}, 125, 'with the exit code of a claim that was not executed';
  is $json->decode($root->child('queue/1.json')->slurp_utf8)->{state}, 'failed',
    'and holds no lease';
  is log_of(1), "SimpiCI::Worker run 1 aborted: invalid event in claim\n",
    'the log is the reason, one of the list, and nothing else';
  unlike log_of(1), qr/\Q$secret\E|\Q$password\E/, 'without a secret value or the URL';
  # What the rule says of this URL, asked of the rule: its wording is not
  # repeated here.
  my $refused_for = SimpiCI::Event->clone_url_rejection($legacy_url);
  ok defined $refused_for && $refused_for !~ /\n/, 'the clone URL rule refuses the URL of the claim, in one line';
  like $warned, qr/\ASimpiCI::Worker run 1 aborted: invalid event in claim: SimpiCI::Event \Q$refused_for\E at [^\n]+ line \d+\.\n\z/,
    'standard error has the reason and what the event was refused for, in one line';
  unlike $warned, qr/\Q$secret\E|\Q$password\E/, 'without a value there either';
  unlike log_of(1), qr/$raised_at|\Q$worker_root\E/,
    'the log names neither a file of the installation nor the store of the worker';
  ok !$worker_root->child('completion.json')->exists, 'the completion was delivered';
};

subtest 'a reason that quotes a secret value' => sub {
  my ( $response, $error, $warned ) = attempt();
  is $error, '', 'the refusal does not escape the worker';
  ok !$worker_root->child('secrets')->exists, 'no secret file is written for it';
  is report(2)->{state}, 'failed', 'the run is failed at the dispatcher';
  my ( $finish ) = grep { $_->{operation} eq 'finish' && $_->{run} == 2 } $worker->requests->@*;
  is $finish->{log}, "SimpiCI::Worker run 2 aborted: invalid event in claim\n",
    'the worker sends the reason, which quotes nothing';
  unlike $finish->{log} // $secret, qr/\Q$secret\E/, 'the value does not leave the worker';
  like $warned,
    qr/\ASimpiCI::Worker run 2 aborted: invalid event in claim: [^\n]*\[REDACTED\][^\n]*\n\z/,
    'what the error quoted reaches standard error with the value redacted';
  unlike $warned, qr/\Q$secret\E/, 'and not the value';
  unlike $finish->{log}, qr/$raised_at|\Q$worker_root\E/,
    'the log names neither a file of the installation nor the store of the worker';
  unlike log_of(2), qr/\Q$secret\E/, 'the published log is free of it';
};

subtest 'a run that croaks with the secret files in place' => sub {
  my ( $response, $error, $warned ) = attempt();
  is $error, '', 'the failure does not escape the worker';
  ok !$worker_root->child('secrets/3')->exists, 'the secret files of the run are removed';
  is report(3)->{state}, 'failed', 'the run is failed at the dispatcher';
  is report(3)->{exit_code}, 125, 'with the exit code of an aborted claim';
  like log_of(3), qr/PUBLISH_TOKEN=\[REDACTED\]/,
    'the output up to the failure arrives, redacted';
  like log_of(3), qr/\nSimpiCI::Worker run 3 aborted: run supervisor failed\n\z/,
    'followed by the reason';
  unlike log_of(3), qr/\Q$secret\E/, 'without the secret value';
  unlike log_of(3), qr/$raised_at|\Q$worker_root\E|cannot publish/,
    'and without the file that could not be published, or where in the installation it croaked';
  like $warned,
    qr/\ASimpiCI::Worker run 3 aborted: run supervisor failed: SimpiCI::Store->write_json cannot publish \Q$worker_root\E\/public\/runs\/3\.json: [^\n]+\n\z/,
    'the worker names the file on standard error, in one line';
  ok !$worker_root->child('completion.json')->exists, 'the completion was delivered';
};

subtest 'a completion that cannot be saved' => sub {
  is $store->allocate_run, 4, 'run 4 is next';
  $store->write_json('queue/4.json', {
    run => 4, key => 'hand-written-4', state => 'queued',
    event => { source => 'git-poll', event => 'push', repository => 'fixture',
      clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit, payload => {} }
  });
  my $completion = $worker_root->child('completion.json');
  $completion->mkpath;
  my ( $response, $error, $warned ) = attempt();
  like $error,
    qr/\ASimpiCI::Worker cannot save the completion of run 4: SimpiCI::Store->write_json cannot publish \Q$worker_root\E\/completion\.json: [^\n]+ at \S+ line \d+\.\n\z/,
    'is an error of the worker, in one line with the file it could not write';
  ok -d $worker_root->child('public/runs/4.json'), 'the job ran with its secret file';
  ok !$worker_root->child('secrets/4')->exists, 'which is removed all the same';
  ok !$worker_root->child('public/runs/4.log')->exists, 'and so is the log it printed the secret to';
  is report(4)->{state}, 'running', 'the run keeps its lease, as after any lost worker';
  $completion->remove_tree;
};

subtest 'the worker goes on' => sub {
  my ( $response, $error, $warned ) = attempt();
  is $error, '', 'the next claim is served';
  is $response, undef, 'and finds the queue empty';
  is $warned, '', 'without a warning';
  is [ map { report($_)->{state} } 1 .. 3 ], [ ('failed') x 3 ],
    'no run that was reported is left running';
};

subtest 'an event whose fields have the wrong type' => sub {
  my %shape = (
    'a list as clone_url' => { clone_url => [$legacy_url] },
    'a string as payload' => { clone_url => "$fixture", payload => $legacy_url }
  );
  for my $name (sort keys %shape) {
    my $private = tempdir;
    my $fixed = FixedClaim->new(claim => {
      run => 7, token => 'unused', timeout => 10,
      event => { source => 'git-poll', event => 'push', repository => 'fixture',
        ref => 'refs/heads/main', commit => $commit, $shape{$name}->%* },
      secrets => { publish => { PUBLISH_TOKEN => $secret } }
    });
    my $private_store = SimpiCI::Store->new(root => $private);
    my $refusing = TestWorker->new(host => 'unused', store => $private_store,
      runner => SimpiCI::Runner->new(store => $private_store, runner_script => $executor),
      dispatcher => $fixed);
    my $caught = warnings { $refusing->once };
    my $warned = join '', @$caught;
    my $finish = $refusing->requests->[-1];
    is $finish->{result}, { state => 'failed', exit_code => 125 },
      $name.' is reported as a failed run';
    is $finish->{log}, "SimpiCI::Worker run 7 aborted: invalid event in claim\n",
      'with a reason that names the claim';
    unlike $finish->{log}.$warned, qr/\Q$password\E|forge\.invalid/,
      'and quotes nothing of the event';
    unlike $finish->{log}.$warned, qr/$raised_at|\Q$private\E/,
      'nor names a file of the installation or the store of the worker';
    ok !$private->child('secrets')->exists, 'no secret file is written for it';
  }
};

subtest 'what an error says is no reason' => sub {
  my $read = "one\ntwo\n";
  my @raised = (
    [ 'a croak whose message says " at " itself',
      qr/cannot reach git at forge\.invalid at \S+ line \d+\./,
      sub { croak 'cannot reach git at forge.invalid' } ],
    [ 'a die', qr/no supervisor at \S+ line \d+\./, sub { die 'no supervisor' } ],
    # Perl then appends ", <$input> line 1." to where it died.
    [ 'a die with a file handle that was read',
      qr/counter is empty at \S+ line \d+, <\$input> line 1\./, sub {
        open my $input, '<', \$read or croak 'cannot read';
        my $line = <$input>;
        die 'counter is empty';
      } ],
    [ 'a backtrace', qr/deep failure at \S+ line \d+\./, sub { confess 'deep failure' } ],
    [ 'a message that ends in a newline', qr/look at this, in line 5 of it/,
      sub { die "look at this, in line 5 of it\n" } ],
    # (I) The end of this message was taken for where it was raised, and cut.
    [ 'a message that itself ends like a place in a file',
      qr/cannot read the counter at byte 3 line 7/,
      sub { die "cannot read the counter at byte 3 line 7\n" } ],
    # (J) Of this path, what stands before its " at " stayed in the reason.
    [ 'an installation whose path has " at " in it',
      qr{boom at /opt/simpici at ci/lib/SimpiCI/Runner\.pm line 5\.},
      sub { die "boom at /opt/simpici at ci/lib/SimpiCI/Runner.pm line 5.\n" } ]
  );
  for my $case (@raised) {
    my ( $name, $said, $raise ) = @$case;
    my $private = tempdir;
    my $private_store = SimpiCI::Store->new(root => $private);
    my $aborting = AbortingWorker->new(host => 'unused', store => $private_store,
      runner => SimpiCI::Runner->new(store => $private_store, runner_script => $executor),
      raise => $raise, dispatcher => FixedClaim->new(claim => {
        run => 7, token => 'unused', timeout => 10, event => {}, secrets => {}
      }));
    my $caught = warnings { $aborting->once };
    is $aborting->requests->[-1]{log}, "SimpiCI::Worker run 7 aborted: internal error\n",
      $name.' is reported as an internal error, with nothing of its message';
    like join('', @$caught), qr/\ASimpiCI::Worker run 7 aborted: internal error: $said\n\z/,
      'and warned with all of its first line';
  }
};

subtest 'a claim whose run is not a run number' => sub {
  my $state = tempdir;
  my $private = $state->child('private/worker');
  my $fixed = FixedClaim->new(claim => {
    run => '../../escape', token => 'unused', timeout => 10,
    event => { source => 'git-poll', event => 'push', repository => 'fixture',
      clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit },
    secrets => { publish => { PUBLISH_TOKEN => $secret } }
  });
  my $private_store = SimpiCI::Store->new(root => $private);
  my $refusing = TestWorker->new(host => 'unused', store => $private_store,
    runner => SimpiCI::Runner->new(store => $private_store, runner_script => $executor),
    dispatcher => $fixed);
  like dies { $refusing->once }, qr/SimpiCI::Worker invalid run in claim/,
    'is refused: it can be neither executed nor reported';
  ok !$state->child('private/escape')->exists, 'nothing is written outside the secret directory';
  ok !$private->child('secrets')->exists, 'and nothing inside it';
  is $fixed->operations, ['claim'], 'no completion is sent';
  ok !$private->child('completion.json')->exists, 'and none is kept for a retry';
};

done_testing;
