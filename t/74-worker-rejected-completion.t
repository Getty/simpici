use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# A completion the dispatcher refuses for good is put aside and the worker
# goes on. One it could not deliver stays where it is and is sent again.

{
  package TestWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has dispatcher => (is => 'ro');
  has before_finish => (is => 'rw');
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    $self->before_finish->($request) if $request->{operation} eq 'finish' && $self->before_finish;
    return $self->dispatcher->request('vm', $request);
  }
}

{
  package ScriptedWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has answer => (is => 'rw', required => 1);
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->answer->($request);
  }
}

umask 0077;
my $json = JSON::MaybeXS->new(canonical => 1);
my $secret = 'rejected-secret-value';

my $fixture = tempdir;
for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
    ['config', 'user.email', 'test@example.invalid']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
}
my @commits;
for my $content (qw( first second third )) {
  $fixture->child('tracked')->spew_utf8($content);
  for my $command (['add', '.'], ['commit', '-qm', $content]) {
    system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
  }
  my $commit = `git -C $fixture rev-parse HEAD`;
  chomp $commit;
  push @commits, $commit;
}

my $root = tempdir;
my $store = SimpiCI::Store->new(root => $root);
my $queue = SimpiCI::Queue->new(store => $store);
$queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
  clone_url => "$fixture", ref => 'refs/heads/main', commit => $_)) for @commits;
my $token = $root->child('token');
$token->spew_utf8($secret);
my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
  timeout => 10, repositories => [{ name => 'fixture', clone_url => "$fixture", secrets => [{
    name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
  }]}]
});

my $worker_root = tempdir;
my $executor = $worker_root->child('executor');
# Prints its secret, as a careless job would, and ends as TEST_SIGNAL says.
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
cat "$SIMPICI_SECRETS_DIR/publish.env"
printf '%s\n' "$CICD_RUN_NUMBER" >> "$CICD_WORKSPACE/../../executions"
[[ -z "${TEST_SIGNAL:-}" ]] || kill -s "$TEST_SIGNAL" $$
SCRIPT
$executor->chmod(0755);
# A run whose executor is ended asks docker for its containers. There are none.
my $tools = tempdir;
$tools->child('docker')->spew_utf8("#!/bin/sh\nexit 0\n");
$tools->child('docker')->chmod(0755);
local $ENV{PATH} = $tools.':'.$ENV{PATH};
my $worker_store = SimpiCI::Store->new(root => $worker_root);
my $worker = TestWorker->new(host => 'unused', store => $worker_store,
  runner => SimpiCI::Runner->new(store => $worker_store, runner_script => $executor),
  dispatcher => $dispatcher);

sub attempt {
  my ( $subject ) = @_;
  my ( $response, $error );
  my $warnings = warnings { $response = eval { $subject->once }; $error = $@ };
  return ( $response, $error, join('', @$warnings) );
}

sub record { $json->decode($root->child('queue/'.$_[0].'.json')->slurp_utf8) }

sub mode { sprintf '%04o', $_[0]->stat->mode & 07777 }

my $pending = $worker_root->child('completion.json');
my $rejected = $worker_root->child('rejected');

subtest 'a completion whose lease expired during the run' => sub {
  # The lease is over when the completion arrives, as after a run that took
  # longer than the dispatcher waits for it.
  $worker->before_finish(sub {
    my $record = record(1);
    $record->{expires} = time - 1;
    $store->write_json('queue/1.json', $record);
  });
  my ( $response, $error, $warned ) = attempt($worker);
  $worker->before_finish(undef);
  is $error, '', 'does not fail the worker';
  is $response, { rejected => 'expired claim' }, 'once returns the answer of the dispatcher';
  ok !$pending->exists, 'the completion does not wait to be sent again';
  my $kept = $rejected->child('1.json');
  ok $kept->is_file, 'it is kept as rejected/1.json';
  is $json->decode($kept->slurp_utf8), $worker->requests->[-1], 'as it was sent';
  like $kept->slurp_utf8, qr/PUBLISH_TOKEN=\[REDACTED\]/, 'with the log of the run';
  unlike $kept->slurp_utf8, qr/\Q$secret\E/, 'and without the secret value the job printed';
  is [ mode($kept), mode($rejected) ], [ '0600', '0700' ], 'readable by the account alone';
  ok !$worker_root->child('secrets/1')->exists, 'the secret files of the run are removed';
  is $warned, 'SimpiCI::Worker completion of run 1 rejected by the dispatcher: expired claim;'
    ." kept as rejected/1.json\n", 'the worker says so on standard error, in one line';
  unlike $warned, qr/\Q$secret\E|\Q$worker_root\E| line \d+/,
    'without a value, a path of its store or a place in the installation';
};

subtest 'the worker goes on' => sub {
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'the next cycle does not fail';
  is $response->{state}, 'success', 'it claims and completes the next run';
  is $response->{run}, 2, 'which is run 2';
  is $worker_root->child('executions')->slurp_utf8, "1\n2\n", 'every run was executed once';
  is [ map { $_->{operation} } $worker->requests->@* ], [qw( claim finish claim finish )],
    'the refused completion was sent once and not again';
  is [ map { $_->basename } $rejected->children ], ['1.json'], 'and nothing else was put aside';
  is $warned, '', 'without a warning';
};

subtest 'a run that a signal ended' => sub {
  local $ENV{TEST_SIGNAL} = 'KILL';
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'is completed like any other';
  is [ $response->@{qw( run state exit_code )} ], [ 3, 'signalled', 137 ],
    'the dispatcher records it as signalled with 128 + 9, not with exit code 0';
  ok !$pending->exists, 'and the completion is delivered';
};

sub scripted {
  my ( $answer ) = @_;
  my $private = tempdir;
  my $private_store = SimpiCI::Store->new(root => $private);
  return ( $private, ScriptedWorker->new(host => 'unused', store => $private_store, answer => $answer,
    runner => SimpiCI::Runner->new(store => $private_store, runner_script => $executor)) );
}

my %completion = ( operation => 'finish', run => 7, token => 'a' x 64,
  result => { state => 'success', exit_code => 0 }, log => "done\n" );

subtest 'a saved completion that is refused after a restart' => sub {
  my ( $private, $restarted ) = scripted(sub { { rejected => 'stale claim' } });
  $private->child('completion.json')->spew_utf8($json->encode(\%completion));
  my $orphan = $private->child('secrets/7');
  $orphan->mkpath;
  $orphan->child('publish.env')->spew_utf8('PUBLISH_TOKEN='.$secret."\n");
  my ( $response, $error, $warned ) = attempt($restarted);
  is $error, '', 'does not fail the worker';
  is $response, { rejected => 'stale claim' }, 'once returns the answer';
  is $restarted->requests, [ \%completion ], 'it was sent as saved, and nothing was claimed';
  ok !$private->child('completion.json')->exists, 'it does not wait to be sent again';
  is $json->decode($private->child('rejected/7.json')->slurp_utf8), \%completion,
    'it is kept as rejected/7.json';
  ok !$orphan->exists, 'the secret files of its run are gone';
  like $warned, qr/^SimpiCI::Worker completion of run 7 rejected by the dispatcher: stale claim; kept as rejected\/7\.json$/m,
    'and the worker names run, reason and file';
  $restarted->answer(sub { {} });
  ( $response, $error, $warned ) = attempt($restarted);
  is [ $error, $response ], [ '', undef ], 'the next cycle asks for work';
  is $restarted->requests->[-1], { operation => 'claim' }, 'with a claim';
};

subtest 'a completion that is refused a second time' => sub {
  my ( $private, $again ) = scripted(sub { { rejected => 'expired claim' } });
  $private->child('rejected')->mkpath;
  $private->child('rejected/7.json')->spew_utf8($json->encode({ %completion, log => "earlier\n" }));
  # An operator put it back to have it delivered once more.
  $private->child('completion.json')->spew_utf8($json->encode(\%completion));
  my ( $response, $error, $warned ) = attempt($again);
  is $error, '', 'does not fail the worker';
  is $json->decode($private->child('rejected/7.json')->slurp_utf8), \%completion,
    'replaces what was kept for the run';
  is [ map { $_->basename } $private->child('rejected')->children ], ['7.json'],
    'so that a run has one file there';
};

subtest 'the report of a claim that was not executed' => sub {
  my ( $private, $refusing ) = scripted(sub {
    my ( $request ) = @_;
    return { rejected => 'unknown run' } if $request->{operation} eq 'finish';
    return { run => 7, token => 'a' x 64, timeout => 10, event => {},
      secrets => { publish => { PUBLISH_TOKEN => $secret } } };
  });
  my ( $response, $error, $warned ) = attempt($refusing);
  is $error, '', 'does not fail the worker when it is refused';
  my $kept = $json->decode($private->child('rejected/7.json')->slurp_utf8);
  is $kept->{result}, { state => 'failed', exit_code => 125 }, 'it is kept with its result';
  like $kept->{log}, qr/\ASimpiCI::Worker run 7 aborted: /, 'and its reason';
  ok !$private->child('completion.json')->exists, 'and does not wait to be sent again';
  ok !$private->child('secrets')->exists, 'no secret file was written for it';
  unlike $warned.$private->child('rejected/7.json')->slurp_utf8, qr/\Q$secret\E/,
    'and no secret value is kept or said';
};

subtest 'a dispatcher that could not be reached' => sub {
  my ( $private, $cut_off ) = scripted(sub { croak 'SimpiCI::Worker dispatcher connection failed' });
  $private->child('completion.json')->spew_utf8($json->encode(\%completion));
  for my $cycle (1 .. 3) {
    my ( $response, $error, $warned ) = attempt($cut_off);
    like $error, qr/dispatcher connection failed/, 'fails cycle '.$cycle;
    is $json->decode($private->child('completion.json')->slurp_utf8), \%completion,
      'and leaves the completion to be sent again';
  }
  ok !$private->child('rejected')->exists, 'nothing is put aside';
  $cut_off->answer(sub { { run => 7, state => 'success' } });
  my ( $response, $error, $warned ) = attempt($cut_off);
  is [ $error, $response->{state} ], [ '', 'success' ], 'it is delivered once the dispatcher answers';
  is scalar $cut_off->requests->@*, 4, 'by the fourth request';
  ok !$private->child('completion.json')->exists, 'and then removed';
  ok !$private->child('rejected')->exists, 'not put aside';
};

subtest 'an answer that only looks like a refusal' => sub {
  my %answer = (
    'no reason'                 => { rejected => undef },
    'an empty reason'           => { rejected => '' },
    'a reason that is a list'   => { rejected => ['expired claim'] },
    'a reason of several lines' => { rejected => "expired claim\nSimpiCI::Worker run 8 aborted" },
    'a reason that is a path'   => { rejected => '/var/lib/simpici/queue/7.json' },
    'a reason without end'      => { rejected => join ' ', ('expired') x 40 }
  );
  for my $name (sort keys %answer) {
    my ( $private, $unsure ) = scripted(sub { $answer{$name} });
    $private->child('completion.json')->spew_utf8($json->encode(\%completion));
    my ( $response, $error, $warned ) = attempt($unsure);
    like $error, qr/\ASimpiCI::Worker invalid dispatcher response at /, $name.' is an error';
    ok $private->child('completion.json')->is_file, 'the completion stays to be sent again';
    ok !$private->child('rejected')->exists, 'and nothing is put aside';
    is $warned, '', 'or said in the words of the answer';
  }
};

subtest 'a refused completion that names no run' => sub {
  my $state = tempdir;
  my $private = $state->child('private/worker');
  my $private_store = SimpiCI::Store->new(root => $private);
  my $escaping = ScriptedWorker->new(host => 'unused', store => $private_store,
    answer => sub { { rejected => 'unknown run' } },
    runner => SimpiCI::Runner->new(store => $private_store, runner_script => $executor));
  $private->mkpath;
  $private->child('completion.json')->spew_utf8($json->encode({ %completion, run => '../../escape' }));
  my ( $response, $error, $warned ) = attempt($escaping);
  like $error, qr/SimpiCI::Worker invalid run in completion/, 'is an error';
  ok $private->child('completion.json')->is_file, 'it stays where it is';
  ok !$state->child('private/escape.json')->exists && !$state->child('escape.json')->exists,
    'and nothing is written outside rejected/';
};

subtest 'every reason of the queue' => sub {
  for my $reason ($queue->refusal_reasons) {
    my ( $private, $refused ) = scripted(sub { { rejected => $reason } });
    $private->child('completion.json')->spew_utf8($json->encode(\%completion));
    my ( $response, $error, $warned ) = attempt($refused);
    is $error, '', '"'.$reason.'" is a reason the worker accepts';
    like $warned, qr/rejected by the dispatcher: \Q$reason\E; kept as/, 'and names';
  }
};

done_testing;
