#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;
use Carp qw( croak );
use Path::Tiny qw( path tempdir );

# The runner puts the commit of its event on the command line of git, where
# "--upload-pack=PROGRAM" is an option that runs PROGRAM. That the commit is
# an object id is a rule of SimpiCI::Event, so the runner takes nothing else
# for an event, and it gives git no chance to read the commit as an option.

umask 0077;
my $root = tempdir;

my $fixture = $root->child('fixture');
system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
  '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty',
  '-m', 'fixture') == 0 or croak 'git commit failed';
chomp(my $commit = qx(git -C '$fixture' rev-parse HEAD));

# What git runs if it reads the commit as that option: the fixture is a
# local repository, so the program would be started on this machine.
my $marker = $root->child('executed');
my $program = $root->child('upload-pack.sh');
$program->spew_utf8("#!/bin/sh\ntouch '".$marker."'\nexit 1\n");
$program->chmod(0755);
my $option = '--upload-pack='.$program;

my $executor = $root->child('executor.sh');
$executor->spew_utf8("#!/bin/sh\nexit 0\n");
$executor->chmod(0755);

my %fields = (source => 'manual', event => 'push', repository => 'owner/project',
  clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit);

my $number = 0;
sub runner {
  my $state = $root->child('state'.++$number);
  return ( $state, SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $state),
    timeout => 30, runner_script => $executor) );
}

#### What is no event

# Answers everything the runner asks of an event, and is none.
{
  package Local::Lookalike;
  sub new { my ( $class, %fields ) = @_; return bless { payload => {}, %fields }, $class }
  sub as_hash { return { $_[0]->%* } }
  for my $field (qw( source event repository clone_url ref commit payload )) {
    no strict 'refs';
    *{$field} = sub { $_[0]->{$field} };
  }
}

for my $case (
  [ 'the fields of an event as a hash', { %fields, commit => $option } ],
  [ 'a string', $option ],
  [ 'nothing', undef ],
  [ 'the name of the class', 'SimpiCI::Event' ],
  [ 'an object of another class', Local::Lookalike->new(%fields, commit => $option) ],
  [ 'such an object with a commit that is one', Local::Lookalike->new(%fields) ]
) {
  my ( $label, $given ) = @$case;
  my ( $state, $runner ) = runner();
  my $died = dies { $runner->run($given) };
  like $died, qr/\ASimpiCI::Runner event must be a SimpiCI::Event at /, 'the runner refuses '.$label;
  unlike $died, qr/upload-pack|\Q$fixture\E/, 'without repeating what it was given';
  ok !$state->exists, 'no run is allocated and nothing is written';
  ok !$marker->exists, 'and nothing is executed';
  $marker->remove;
}

like dies { ( runner() )[1]->run(Local::Lookalike->new(%fields), 7) },
  qr/\ASimpiCI::Runner event must be a SimpiCI::Event at /, 'also for an assigned run';

is(SimpiCI::Runner->event_class, 'SimpiCI::Event', 'the class is named in one place')
  if ok(SimpiCI::Runner->can('event_class'), 'the runner names the class of its events');

#### An event

my ( $state, $runner ) = runner();
my $report = $runner->run(SimpiCI::Event->new(%fields));
is $report->{state}, 'success', 'an event is run';
chomp(my $head = qx(git -C '@{[ $state->child('work', $report->{run}) ]}' rev-parse HEAD));
is $head, $commit, 'with its exact commit checked out';

# A subclass is an event too.
{
  package Local::Event;
  use Moo;
  extends 'SimpiCI::Event';
}
( $state, $runner ) = runner();
is $runner->run(Local::Event->new(%fields))->{state}, 'success', 'an event of a subclass is run';

#### An event that never passed its constructor

# Of the right class, with a commit SimpiCI::Event refuses. Nothing makes
# such an event; the command line of git holds without the rule all the same.
for my $hostile ( $option, '--upload-pack', '-u'.$program, '--force', '-f', '--all', '--' ) {
  ( $state, $runner ) = runner();
  my $unchecked = bless { payload => {}, %fields, commit => $hostile }, 'SimpiCI::Event';
  my $failed = $runner->run($unchecked);
  is $failed->{state}, 'failed', 'a run with the commit '.$hostile.' fails';
  ok !$marker->exists, 'git executed nothing for it';
  $marker->remove;
  my $workspace = $state->child('work', $failed->{run});
  is scalar( qx(git -C '$workspace' rev-parse --verify --quiet HEAD) ), '',
    'and nothing is checked out';
  ok !$state->child('runs', $failed->{run}, 'event.json')->exists, 'the executor is not started';
}

done_testing;
