#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Store;
use File::Temp qw( tempdir );
use JSON::MaybeXS;
use Path::Tiny qw( path );

my $root = path(tempdir(CLEANUP => 1));
my $store = SimpiCI::Store->new(root => $root);

is $store->allocate_run, 1, 'first run is one';
is $store->allocate_run, 2, 'run counter increases';

my $target = $store->write_json('public/runs/2.json', { state => 'running' });
is(
  JSON::MaybeXS->new->decode($target->slurp_utf8),
  { state => 'running' },
  'publishes valid JSON'
);
is(
  [ $target->parent->children(qr/\.tmp\./) ],
  [],
  'leaves no temporary file behind'
);

like dies { $store->write_json('../escape.json', {}) },
  qr/path escapes root/,
  'refuses paths outside state root';

done_testing;
