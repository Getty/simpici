#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Event;

my %args = (
  source     => 'git-poll',
  event      => 'push',
  repository => 'LEDaquaristik/sunriser',
  clone_url  => 'git@src.ci:ledaquaristik/sunriser.git',
  ref        => 'refs/heads/master',
  commit     => 'a' x 40
);

my $event = SimpiCI::Event->new(%args);
is $event->as_hash, { %args, payload => {} }, 'event has canonical shape';

is length($event->deduplication_key), 64, 'deduplication key is SHA-256';
is $event->deduplication_key,
  SimpiCI::Event->new(%args, source => 'webhook')->deduplication_key,
  'source does not split otherwise identical runs';

like dies { SimpiCI::Event->new(%args, ref => '../master') },
  qr/ref must start with refs\//,
  'rejects non-canonical refs';
like dies { SimpiCI::Event->new(%args, commit => 'abc123') },
  qr/full hexadecimal object id/,
  'rejects abbreviated commits';

done_testing;
