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
exec "$TEST_PERL" -I"$TEST_LIB" "$TEST_DISPATCH" --config "$TEST_CONFIG" --worker test-vm
SCRIPT
$ssh->chmod(0755);
local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
local $ENV{TEST_PERL} = $^X;
local $ENV{TEST_LIB} = path('lib')->absolute->stringify;
local $ENV{TEST_DISPATCH} = path('bin/simpici-dispatch')->absolute->stringify;
local $ENV{TEST_CONFIG} = "$config";
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
like $output, qr/SimpiCI::Worker run 2 aborted: SimpiCI::Event clone URL must not contain a password/,
  'and names the run and the reason on standard error';
unlike $output, qr/transport-secret-value|hunter2-in-url/, 'without the secret or the URL';
# Where the error was raised is no part of the reason: the log is public.
my $private_path = qr/ line \d+|\.pm\b|\Q$ENV{TEST_LIB}\E|\Q@{[ $worker_store->root ]}\E/;
unlike $output, $private_path, 'or a file of the installation or of the worker store';
ok $store->root->child('claims/2.json')->slurp_utf8 =~ /transport-secret-value/,
  'the claim did carry the secret';
ok !$worker_store->root->child('secrets')->exists, 'no secret file is written on the worker';
my $report = JSON::MaybeXS->new->decode($store->root->child('public/runs/2.json')->slurp_utf8);
is [ $report->@{qw( state exit_code )} ], [ 'failed', 125 ],
  'the dispatcher records a failed run instead of an expiring lease';
like $store->root->child('public/runs/2.log')->slurp_utf8,
  qr/\ASimpiCI::Worker run 2 aborted: SimpiCI::Event clone URL must not contain a password[^\n]* runs git\n\z/,
  'with the reason as its log, which ends where the message of the event ends';
unlike $store->root->child('public/runs/2.log')->slurp_utf8, $private_path,
  'and names no file of the installation or of the worker store';
unlike $store->root->child('public/runs/2.log')->slurp_utf8,
  qr/transport-secret-value|hunter2-in-url/, 'and no value in it';
ok !$worker_store->root->child('completion.json')->exists, 'no completion is left to retry';

done_testing;
