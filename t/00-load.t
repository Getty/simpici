#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

for my $module (qw(
  App::SimpiCI
  App::SimpiCI::Event
  App::SimpiCI::Runner
  App::SimpiCI::Source::GitPoll
  App::SimpiCI::Store
)) {
  my $loaded = eval "use $module; 1";
  ok $loaded, 'loaded '.$module;
  diag $@ unless $loaded;
}

done_testing;
