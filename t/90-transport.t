use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( path tempdir );
use JSON::MaybeXS;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

my $root = tempdir;
my $store = SimpiCI::Store->new(root => $root->child('dispatcher'));
my $queue = SimpiCI::Queue->new(store => $store);
$queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
  repository => 'fixture', clone_url => '/fixture', ref => 'refs/heads/main', commit => 'a' x 40));
my $config = $root->child('config.json');
$config->spew_utf8(JSON::MaybeXS->new(canonical => 1)->encode({
  root => $store->root->stringify, repositories => []
}));
$root->child('bin')->mkpath;
my $ssh = $root->child('bin/ssh');
$ssh->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
# An ssh that cannot connect ends with 255 and has read nothing.
[[ -z "${TEST_SSH_UNREACHABLE:-}" ]] || exit 255
# One whose connection breaks after the request passes on part of an answer.
if [[ -n "${TEST_SSH_ANSWER+set}" ]]; then cat >/dev/null; printf '%s' "$TEST_SSH_ANSWER"; exit 0; fi
"$TEST_PERL" -I"$TEST_LIB" "$TEST_DISPATCH" --config "$TEST_CONFIG" --worker test-vm \
  | tee -a "$TEST_RESPONSES"
SCRIPT
$ssh->chmod(0755);
local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
local $ENV{TEST_PERL} = $^X;
local $ENV{TEST_LIB} = path('lib')->absolute->stringify;
local $ENV{TEST_DISPATCH} = path('bin/simpici-dispatch')->absolute->stringify;
local $ENV{TEST_CONFIG} = "$config";
# What the dispatcher answered, in the order it was asked.
my $responses = $root->child('responses');
local $ENV{TEST_RESPONSES} = "$responses";
my $worker_store = SimpiCI::Store->new(root => $root->child('worker'));
my $worker = SimpiCI::Worker->new(host => 'test-host', store => $worker_store,
  runner => SimpiCI::Runner->new(store => $worker_store));
my $claim = $worker->_request({operation => 'claim'});
is $claim->{run}, 1, 'real dispatcher process accepts client JSON through stdin';
is $claim->{worker}, 'test-vm', 'endpoint binds forced worker identity';
my $result = $worker->_request({operation => 'finish', run => $claim->{run},
  token => $claim->{token}, result => {state => 'success', exit_code => 0},
  log => 'transport complete'});
is $result->{state}, 'success', 'completion crosses process boundary';
is $store->root->child('public/runs/1.log')->slurp_utf8, 'transport complete',
  'received log is published';

# The same boundary with both programs, for a claim the worker refuses: a
# queue entry written by hand, whose clone URL no event may carry any more.
my $token = $root->child('token');
$token->spew_utf8("transport-secret-value\n");
my $refused_url = 'ftp://builder:hunter2-in-url@forge.invalid/legacy.git';
$config->spew_utf8(JSON::MaybeXS->new(canonical => 1)->encode({
  root => $store->root->stringify, repositories => [{
    name => 'legacy', clone_url => $refused_url, secrets => [{
      name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
    }]
  }]
}));
is $store->allocate_run, 2, 'run 2 is next';
$store->write_json('queue/2.json', {
  run => 2, key => 'hand-written', state => 'queued',
  event => { source => 'git-poll', event => 'push', repository => 'legacy',
    clone_url => $refused_url, ref => 'refs/heads/main', commit => 'b' x 40, payload => {} }
});
my $program = path('bin/simpici-worker')->absolute;
my $output = qx{"$ENV{TEST_PERL}" -I"$ENV{TEST_LIB}" "$program" --dispatcher test-host --root "@{[ $worker_store->root ]}" --once 2>&1};
is $? >> 8, 0, 'simpici-worker survives a claim it refuses';
like $output,
  qr/\ASimpiCI::Worker run 2 aborted: invalid event in claim: SimpiCI::Event clone URL must not contain a password[^\n]* runs git at [^\n]+\n\z/,
  'and names the run, the reason and what the event was refused for in one line on standard error';
unlike $output, qr/transport-secret-value|hunter2-in-url/, 'without the secret or the URL';
# What the error said, and where it was raised, is no part of the reason:
# the log is public.
my $private_path = qr/ line \d+|\.pm\b|\Q$ENV{TEST_LIB}\E|\Q@{[ $worker_store->root ]}\E/;
like $responses->slurp_utf8, qr/"PUBLISH_TOKEN":"transport-secret-value"/,
  'the claim did carry the secret';
is [ $store->root->child('claims')->children ], [],
  'and the dispatcher keeps no snapshot of it once the completion is accepted';
ok !$worker_store->root->child('secrets')->exists, 'no secret file is written on the worker';
my $report = JSON::MaybeXS->new->decode($store->root->child('public/runs/2.json')->slurp_utf8);
is [ $report->@{qw( state exit_code )} ], [ 'failed', 125 ],
  'the dispatcher records a failed run instead of an expiring lease';
is $store->root->child('public/runs/2.log')->slurp_utf8,
  "SimpiCI::Worker run 2 aborted: invalid event in claim\n",
  'with the reason as its log, which is one of a list and nothing the error said';
unlike $store->root->child('public/runs/2.log')->slurp_utf8, $private_path,
  'and names no file of the installation or of the worker store';
unlike $store->root->child('public/runs/2.log')->slurp_utf8,
  qr/transport-secret-value|hunter2-in-url/, 'and no value in it';
ok !$worker_store->root->child('completion.json')->exists, 'no completion is left to retry';

# From here on simpici-worker delivers a completion that is already saved,
# as after a restart: what it does with the answer is what is looked at.
my $json = JSON::MaybeXS->new(canonical => 1);
my $pending = $worker_store->root->child('completion.json');
my $rejected = $worker_store->root->child('rejected');

sub claimed_completion {
  my ( $commit, $log ) = @_;
  $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
    clone_url => '/fixture', ref => 'refs/heads/main', commit => $commit));
  my $claim = $worker->_request({ operation => 'claim' });
  my $completion = { operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => { state => 'success', exit_code => 0 }, log => $log };
  $pending->spew_utf8($json->encode($completion));
  return $completion;
}

sub worker_once {
  my $output = qx{"$ENV{TEST_PERL}" -I"$ENV{TEST_LIB}" "$program" --dispatcher test-host --root "@{[ $worker_store->root ]}" --once 2>&1};
  return ( $?, $output );
}

sub queued { $json->decode($store->root->child('queue/'.$_[0].'.json')->slurp_utf8) }

subtest 'a completion the dispatcher refuses for good' => sub {
  my $completion = claimed_completion('c' x 40, "late\n");
  is $completion->{run}, 3, 'run 3 is claimed';
  $store->write_json('queue/3.json', { queued(3)->%*, expires => time - 1 });
  my ( $status, $output ) = worker_once();
  is $status, 0, 'does not fail simpici-worker';
  like $responses->slurp_utf8, qr/\}\{"rejected":"expired claim"\}\z/,
    'simpici-dispatch answers with the reason and nothing else';
  is $output, 'SimpiCI::Worker completion of run 3 rejected by the dispatcher: expired claim;'
    ." kept as rejected/3.json\n", 'the worker says in one line what became of it';
  ok !$pending->exists, 'the completion does not wait to be sent again';
  is $json->decode($rejected->child('3.json')->slurp_utf8), $completion,
    'it is kept as rejected/3.json, as it was';
  ok !$store->root->child('public/runs/3.log')->exists, 'the dispatcher published nothing of it';
};

subtest 'the worker goes on after it' => sub {
  is $store->allocate_run, 4, 'run 4 is next';
  $store->write_json('queue/4.json', {
    run => 4, key => 'hand-written-4', state => 'queued',
    event => { source => 'git-poll', event => 'push', repository => 'legacy',
      clone_url => $refused_url, ref => 'refs/heads/main', commit => 'e' x 40, payload => {} }
  });
  my ( $status, $output ) = worker_once();
  is $status, 0, 'the next cycle does not fail';
  like $output, qr/\ASimpiCI::Worker run 4 aborted: /, 'it claims run 4';
  is [ queued(4)->{result}->@{qw( state exit_code )} ], [ 'failed', 125 ], 'and completes it';
  is queued(3)->{state}, 'interrupted', 'the run it was refused for is interrupted';
  is [ map { $_->basename } $rejected->children ], ['3.json'], 'and one file is kept for it';
};

subtest 'a dispatcher that cannot be asked' => sub {
  # More than a pipe holds: an ssh that ends without reading leaves the
  # worker writing to nobody.
  my $completion = claimed_completion('d' x 40, 'x' x (2 * 1024 * 1024));
  is $completion->{run}, 5, 'run 5 is claimed';
  my $kept = sub {
    my ( $name ) = @_;
    ok $pending->is_file && $json->decode($pending->slurp_utf8)->{token} eq $completion->{token},
      $name.': the completion stays to be sent again';
    ok !$rejected->child('5.json')->exists, $name.': and is not put aside';
  };
  {
    local $ENV{TEST_SSH_UNREACHABLE} = 1;
    my ( $status, $output ) = worker_once();
    # The shell that runs the program reports a SIGPIPE as exit code 141.
    is $status >> 8, 0, 'an ssh that does not connect neither kills nor fails simpici-worker';
    like $output, qr/\Asimpici-worker: SimpiCI::Worker dispatcher connection failed at /,
      'the worker reports the connection';
    $kept->('unreachable');
  }
  {
    local $ENV{TEST_CONFIG} = $root->child('missing.json')->stringify;
    my ( $status, $output ) = worker_once();
    is $status, 0, 'a dispatcher that fails does not fail simpici-worker';
    like $output, qr/^simpici-worker: SimpiCI::Worker dispatcher connection failed at /m,
      'the worker reports it as a request that failed, not as a refusal';
    $kept->('failing dispatcher');
  }
  my %answer = (
    'no answer'                    => '',
    'an answer that was cut short' => '{"rejec',
    'an answer that is a list'     => '["rejected"]',
    'a reason in other words'      => '{"rejected":"SimpiCI::Queue expired claim at /usr/lib line 113."}'
  );
  for my $name (sort keys %answer) {
    local $ENV{TEST_SSH_ANSWER} = $answer{$name};
    my ( $status, $output ) = worker_once();
    is $status, 0, $name.' does not fail simpici-worker';
    like $output, qr/\Asimpici-worker: SimpiCI::Worker invalid dispatcher response at /,
      $name.' is reported as no answer of the dispatcher';
    $kept->($name);
  }
  my ( $status, $output ) = worker_once();
  is [ $status, $output ], [ 0, '' ], 'once the dispatcher answers, the completion is delivered';
  ok !$pending->exists, 'and removed';
  is queued(5)->{state}, 'success', 'the run has its result';
  is length $store->root->child('public/runs/5.log')->slurp_utf8, 2 * 1024 * 1024,
    'and its whole log';
  is [ map { $_->basename } $rejected->children ], ['3.json'], 'nothing more was put aside';
};

subtest 'a cycle that fails' => sub {
  # Standard error is the log of the operator: it names the file, and it
  # has one line for one event.
  is $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
    clone_url => '/fixture', ref => 'refs/heads/main', commit => 'f' x 40))->{run}, 6, 'run 6 is queued';
  $pending->mkpath;
  my ( $status, $output ) = worker_once();
  is $status, 0, 'does not fail simpici-worker';
  like $output,
    qr/\Asimpici-worker: SimpiCI::Worker cannot save the completion of run 6: SimpiCI::Store->write_json cannot publish \Q$pending\E: [^\n]+ at [^\n]+ line \d+\.\n\z/,
    'is one line on standard error, with the file that could not be written';
  $pending->remove_tree;
};

done_testing;
