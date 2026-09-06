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

done_testing;
