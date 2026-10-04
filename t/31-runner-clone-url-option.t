#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;
use Path::Tiny qw( path tempdir );

umask 0077;
my $root = tempdir;

# What a clone URL of this shape would run if git took it for the option it
# names, at any of the commands the runner gives.
my $marker = $root->child('executed');
my $program = $root->child('upload-pack.sh');
$program->spew_utf8("#!/bin/sh\ntouch '".$marker."'\nexit 1\n");
$program->chmod(0755);

my %fields = (source => 'manual', event => 'push', repository => 'owner/project',
  ref => 'refs/heads/main', commit => 'a' x 40);

# An event has no such clone URL: its constructor refuses it.
like dies { SimpiCI::Event->new(%fields, clone_url => '--upload-pack='.$program) },
  qr/\ASimpiCI::Event clone URL must not begin with "-" at /,
  'SimpiCI::Event refuses a clone URL that begins with a dash';

# The runner does not rely on that. This is an event that never passed its
# constructor: of the right class, with whatever it was made of.
sub unchecked_event {
  my ( %given ) = @_;
  return bless { payload => {}, %fields, %given }, 'SimpiCI::Event';
}

my $number = 0;
sub checkout_of {
  my ( $clone_url ) = @_;
  my $state = $root->child('state'.++$number);
  my $report = SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $state),
    timeout => 30, runner_script => $root->child('never-started'))
    ->run(unchecked_event(clone_url => $clone_url));
  chomp(my $remote = qx(git -C '@{[ $state->child('work', $report->{run}) ]}' config --get remote.origin.url));
  return ( $report, $remote, $state->child('public', 'runs', $report->{run}.'.log')->slurp_utf8 );
}

# -f, --tags and --mirror=fetch are options of "git remote add"; the others
# are options of the commands around it.
for my $clone_url ( '--upload-pack='.$program, '--mirror=fetch', '--tags', '-f', '-h',
    '--detach', '-oProxyCommand='.$program ) {
  my ( $report, $remote, $log ) = checkout_of($clone_url);
  is $remote, $clone_url, 'the workspace has '.$clone_url.' as the URL of its remote';
  unlike $log, qr/usage: git remote add|unknown option|unknown switch/,
    'and git did not read it as an option';
  is $report->{state}, 'failed', 'the run fails, since nothing can be fetched from it';
}
ok !$marker->exists, 'and nothing a URL named was executed';

done_testing;
