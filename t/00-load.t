#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

for my $module (qw(
  SimpiCI
  SimpiCI::App::Eventd
  SimpiCI::App::Run
  SimpiCI::Event
  SimpiCI::Runner
  SimpiCI::Source::GitPoll
  SimpiCI::Store
)) {
  my $loaded = eval "use $module; 1";
  ok $loaded, 'loaded '.$module;
  diag $@ unless $loaded;
}

done_testing;
