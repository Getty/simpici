#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

sub git {
  my ( $fixture, @command ) = @_;
  system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
    '-c', 'user.email=test@example.invalid', @command) == 0
    or croak 'git '.$command[0].' failed';
}

# An empty commit on the branch, and its id.
sub commit {
  my ( $fixture, $message ) = @_;
  git($fixture, 'commit', '-q', '--allow-empty', '-m', $message);
  my $id = qx{git -C "$fixture" rev-parse HEAD};
  chomp $id;
  croak 'git rev-parse failed' unless $id =~ /\A[0-9a-f]{40,64}\z/;
  return $id;
}

sub state_file {
  my ( $state, $repository ) = @_;
  return $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json');
}

# Ref and commit of every run in a state root, in run order. The queue of the
# dispatcher mode projects what it accepted to the same place.
sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { join ' ', $json->decode($_->slurp_utf8)->@{qw( ref commit )} }
    sort { $a->basename('.json') <=> $b->basename('.json') }
    grep { $_->basename =~ /\A[1-9][0-9]*\.json\z/ } $directory->children ];
}

my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);

# One polling cycle in this process: what it returned, what it warned, and
# what it died of.
sub once {
  my ( $config ) = @_;
  my ( $status, $warnings );
  my $died = dies {
    $warnings = warnings {
      $status = SimpiCI::App::Eventd->run('--config', "$config", '--once',
        '--runner', "$runner_script");
    };
  };
  return [ $died, $status, $warnings // [] ];
}

my $quiet = [ undef, 0, [] ];

# The recorded tips are merged in the poll, which the daemon calls with a
# runner in local mode and with the queue in dispatcher mode.
for my $mode (qw( local dispatcher )) {
  my $fixture = $root->child($mode.'.git');
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'v1');
  my $second = commit($fixture, 'second');
  git($fixture, 'tag', 'v2');

  my $repository = { name => 'owner/'.$mode, clone_url => "$fixture",
    refs => ['refs/heads/main', 'refs/tags/*'], build_initial => JSON->false };
  my $config = $root->child($mode.'.json');
  $config->spew_utf8($json->encode({
    root => $root->child($mode)->stringify, mode => $mode, repositories => [ $repository ]
  }));
  my $state = state_file($mode, $repository);
  # The tips of the state; what else it holds is the matter of t/48.
  my $recorded = sub { $json->decode($state->slurp_utf8)->{tips} };

  #### The baseline

  is once($config), $quiet, $mode.': the baseline cycle is quiet';
  is runs_of($mode), [], $mode.': and builds neither the branch nor the tags';
  is $recorded->(), {
    'refs/heads/main' => $second, 'refs/tags/v1' => $first, 'refs/tags/v2' => $second
  }, $mode.': which are recorded';

  #### Some refs disappear, the branch stays

  git($fixture, 'tag', '-d', 'v1');
  git($fixture, 'tag', '-d', 'v2');
  my $third = commit($fixture, 'third');
  is once($config), $quiet, $mode.': a cycle without the tags is quiet';
  is runs_of($mode), ['refs/heads/main '.$third], $mode.': and builds the branch that moved';
  is $recorded->(), {
    'refs/heads/main' => $third, 'refs/tags/v1' => $first, 'refs/tags/v2' => $second
  }, $mode.': the tags that are gone keep their last tips, next to the new one of the branch';

  #### They come back where they were

  git($fixture, 'tag', 'v1', $first);
  git($fixture, 'tag', 'v2', $second);
  is once($config), $quiet, $mode.': the cycle that gets the tags back is quiet';
  is scalar(runs_of($mode)->@*), 1, $mode.': tags that are back on their recorded commits are not built';

  #### One comes back on another commit

  git($fixture, 'tag', '-d', 'v1');
  is once($config), $quiet, $mode.': a tag that is deleted starts no run';
  is scalar(runs_of($mode)->@*), 1, $mode.': neither for itself nor for another ref';
  git($fixture, 'tag', 'v1', $third);
  is once($config), $quiet, $mode.': the cycle that sees it elsewhere is quiet';
  is runs_of($mode), ['refs/heads/main '.$third, 'refs/tags/v1 '.$third],
    $mode.': a tag that is back on another commit is built once, at that commit';
  is $recorded->()->{'refs/tags/v1'}, $third, $mode.': which is its recorded tip now';
  once($config);
  is scalar(runs_of($mode)->@*), 2, $mode.': and not built a second time';

  #### A ref that was never recorded

  git($fixture, 'tag', 'v3', $first);
  is once($config), $quiet, $mode.': the cycle that sees a new tag is quiet';
  is runs_of($mode)->[-1], 'refs/tags/v3 '.$first, $mode.': a tag that was never recorded is built';
  is scalar(runs_of($mode)->@*), 3, $mode.': and nothing else';
  is $recorded->(), {
    'refs/heads/main' => $third, 'refs/tags/v1' => $third,
    'refs/tags/v2'    => $second, 'refs/tags/v3' => $first
  }, $mode.': the state holds every ref that was ever observed';
}

done_testing;
