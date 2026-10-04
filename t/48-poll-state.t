#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::Queue;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;
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

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name.'.git');
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  return $fixture;
}

# The configuration of one repository in a state root of its name. Written
# again, it is the same repository with another filter.
sub configure {
  my ( $state, $fixture, @refs ) = @_;
  my $repository = { name => 'owner/'.$state, clone_url => "$fixture",
    refs => \@refs, build_initial => JSON->false };
  my $config = $root->child($state.'.json');
  $config->spew_utf8($json->encode({
    root => $root->child($state)->stringify, repositories => [ $repository ]
  }));
  return ( $config, $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json') );
}

# Ref and commit of every run in a state root, in run order.
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

# A file that is replaced gets another inode, and one that is written in
# place another time: aged, a state file shows either.
my $long_ago = 1_000_000_000;
sub age {
  my ( $file ) = @_;
  utime $long_ago, $long_ago, "$file" or croak 'cannot age '.$file.': '.$!;
  return join ' ', ( stat "$file" )[ 1, 9 ];
}

sub aged { join ' ', ( stat "$_[0]" )[ 1, 9 ] }

#### A ref outside the filter keeps its tip

# Written down as it was before the state changed its form: what is asserted
# here are the runs.
{
  my $fixture = git_fixture('filter');
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'v1');
  my @wide = ( 'refs/heads/main', 'refs/tags/*' );
  my ( $config ) = configure('filter', $fixture, @wide);
  is once($config), $quiet, 'the baseline of a branch and a tag is quiet';
  is runs_of('filter'), [], 'and builds neither';

  configure('filter', $fixture, 'refs/heads/main');
  is once($config), $quiet, 'a cycle with the filter narrowed to the branch is quiet';
  configure('filter', $fixture, @wide);
  is once($config), $quiet, 'and so is the one with the filter widened again';
  is runs_of('filter'), [],
    'a tag that left the filter and is back in it where it was builds nothing';

  configure('filter', $fixture, 'refs/heads/main');
  my $second = commit($fixture, 'second');
  git($fixture, 'update-ref', 'refs/tags/v1', 'HEAD');
  once($config);
  is runs_of('filter'), ['refs/heads/main '.$second],
    'outside the filter a tag that moves builds nothing, the branch does';
  configure('filter', $fixture, @wide);
  is once($config), $quiet, 'the cycle that sees the moved tag again is quiet';
  is runs_of('filter'), ['refs/heads/main '.$second, 'refs/tags/v1 '.$second],
    'a tag that moved while it was outside the filter is built once it is back in it';
  once($config);
  is scalar(runs_of('filter')->@*), 2, 'and once only';
}

#### The state is written when it changes, and only then

{
  my $fixture = git_fixture('written');
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'v1');
  my ( $config, $state ) = configure('written', $fixture, 'refs/heads/main', 'refs/tags/*');
  my $recorded = sub { $json->decode($state->slurp_utf8) };

  is once($config), $quiet, 'the baseline cycle is quiet';
  is $recorded->(), {
    tips => { 'refs/heads/main' => $first, 'refs/tags/v1' => $first }, absent => []
  }, 'and records the tips, none of them absent';

  my $before = age($state);
  is once($config), $quiet, 'a cycle without a change is quiet';
  is aged($state), $before, 'and does not write the state';

  my $second = commit($fixture, 'second');
  once($config);
  isnt aged($state), $before, 'a ref that moved is written';
  is $recorded->()->{tips}{'refs/heads/main'}, $second, 'with its new tip';

  #### What the last poll did not see

  git($fixture, 'update-ref', '-d', 'refs/tags/v1');
  $before = age($state);
  is once($config), $quiet, 'a cycle without the tag is quiet';
  isnt aged($state), $before, 'a ref that disappeared is written';
  is $recorded->(), {
    tips => { 'refs/heads/main' => $second, 'refs/tags/v1' => $first },
    absent => ['refs/tags/v1']
  }, 'as absent, with the tip it had';
  $before = age($state);
  once($config);
  is aged($state), $before, 'and not written again while it stays away';

  git($fixture, 'tag', 'v1', $first);
  once($config);
  is $recorded->()->{absent}, [], 'back, it is absent no longer';
  is runs_of('written'), ['refs/heads/main '.$second], 'and was not built for it';

  #### An empty baseline is a state

  my ( $empty_config, $empty_state ) = configure('unmatched', $fixture, 'refs/heads/develop');
  is once($empty_config), $quiet, 'a repository without a configured ref is quiet';
  is $json->decode($empty_state->slurp_utf8), { tips => {}, absent => [] },
    'and gets its empty baseline written';
  $before = age($empty_state);
  once($empty_config);
  is aged($empty_state), $before, 'once';
}

#### A state of the earlier form

{
  my $fixture = git_fixture('earlier');
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'v1');
  my ( $config, $state ) = configure('earlier', $fixture, 'refs/heads/main', 'refs/tags/*');
  my $flat = $json->encode({ 'refs/heads/main' => $first, 'refs/tags/v1' => $first });
  $state->touchpath->spew_utf8($flat);

  is once($config), $quiet, 'a cycle over a flat hash of tips is quiet';
  is runs_of('earlier'), [], 'its tips are the recorded ones: nothing is built';
  is $state->slurp_utf8, $flat, 'and it is left as it is while nothing changes';

  my $second = commit($fixture, 'second');
  once($config);
  is runs_of('earlier'), ['refs/heads/main '.$second], 'a ref that moved is built from it';
  is $json->decode($state->slurp_utf8), {
    tips => { 'refs/heads/main' => $second, 'refs/tags/v1' => $first }, absent => []
  }, 'and written in the form of today';

  $state->spew_utf8('["refs/heads/main"]');
  my $outcome = once($config);
  like $outcome->[0], qr/SimpiCI::Source::GitPoll invalid state in state\/repositories\/[0-9a-f]{64}\.json/,
    'a state that is no object ends the daemon, by its name';
  is $outcome->[2], [], 'and is not reported as a repository that was not polled';

  #### Read and corrected without a runner

  my $store = SimpiCI::Store->new(root => $root->child('earlier'));
  my $poller = SimpiCI::Source::GitPoll->new(store => $store,
    repository => { name => 'owner/earlier', clone_url => "$fixture", refs => ['refs/heads/main'] });
  $state->spew_utf8($flat);
  is $poller->recorded, {
    tips => { 'refs/heads/main' => $first, 'refs/tags/v1' => $first }, absent => [],
    file => $state->relative($store->root)->stringify, bytes => length $flat
  }, 'what is recorded is given with its file and size, a flat hash as tips that were all seen';
  is $poller->rejection({}), 'remote returned no refs, configured refs seen at the last poll: 1',
    'of which the configured ones are missed by an empty observation';
  is $poller->forget('refs/tags/v1'), $first, 'forgetting a ref returns the commit it was recorded at';
  is $json->decode($state->slurp_utf8), { tips => { 'refs/heads/main' => $first }, absent => [] },
    'and writes the state without it, in the form of today';
  is [ $poller->forget('refs/tags/v1') ], [], 'a ref that is not recorded is not forgotten';
  like dies { $poller->forget(undef) }, qr/SimpiCI::Source::GitPoll->forget needs the name of a ref/,
    'and a ref has to be named';
  like dies { $poller->poll({}) }, qr/SimpiCI::Source::GitPoll cannot poll without a runner/,
    'a poller without a runner does not poll';
  my $unpolled = SimpiCI::Source::GitPoll->new(store => $store,
    repository => { name => 'owner/unpolled', clone_url => "$fixture", refs => [] });
  is [ $unpolled->recorded, $unpolled->forget('refs/heads/main') ], [],
    'a repository without a state has nothing recorded and nothing to forget';
}

#### The filter, as git applies it

{
  my $fixture = git_fixture('patterns');
  commit($fixture, 'first');
  git($fixture, 'branch', $_) for qw( feature/a/b fix-1 release/1.0 x/refs/heads/main );
  git($fixture, 'tag', 'v1');
  git($fixture, 'tag', '-a', '-m', 'annotated', 'v2');
  git($fixture, 'update-ref', 'refs/pull/1/head', 'HEAD');
  my $store = SimpiCI::Store->new(root => $root->child('patterns'));
  my $poller = sub {
    return SimpiCI::Source::GitPoll->new(store => $store,
      repository => { name => 'owner/patterns', clone_url => "$fixture", refs => [ @_ ] });
  };
  my @all = sort keys $poller->()->observe->%*;
  is scalar(@all), 9, 'the fixture has nine names, HEAD among them';
  for my $filter (
    [], ['refs/heads/main'], ['main'], ['ain'], ['*ain'], ['heads/*'], ['refs/heads/*'],
    ['refs/heads/feature/*'], ['refs/*/a/b'], ['refs/heads/f?x-1'], ['refs/heads/fi[xy]-1'],
    ['refs/heads/fi[!x]-1'], ['refs/heads/fi[^x]-1'], ['refs/tags/v[0-9]'],
    ['refs/tags/v[[:digit:]]'], ['refs/heads/release/1.0'], ['refs/heads/release/1?0'],
    ['refs/heads/feature?a/b'], ['refs/heads/**'], ['refs\\/heads/main'], ['refs/heads/['],
    ['refs/heads/fi\\x-1'], ['refs/heads/fix-1/'], ['refs/tags/v2'], ['v2*'], ['HEAD'],
    ['refs/heads/main', 'refs/tags/*'], ['refs/pull/*']
  ) {
    my $filtered = $poller->(@$filter);
    is [ grep { $filtered->configured($_) } @all ], [ sort keys $filtered->observe->%* ],
      'configured selects what git ls-remote shows for '.$json->encode($filter);
  }
}

#### The signal of a repository that lost its refs

{
  my $fixture = git_fixture('signal');
  commit($fixture, 'first');
  git($fixture, 'tag', 'v1');
  git($fixture, 'tag', 'v2');
  my ( $config, $state ) = configure('signal', $fixture, 'refs/heads/main', 'refs/tags/*');
  my $recorded = sub { $json->decode($state->slurp_utf8) };
  my $line = sub {
    my ( $count ) = @_;
    return qr/\Asimpicid: repository owner\/signal \(\Q$fixture\E\) not polled: remote returned no refs, configured refs seen at the last poll: $count\n\z/;
  };

  is once($config), $quiet, 'the baseline of a branch and two tags is quiet';
  git($fixture, 'update-ref', '-d', 'refs/tags/v2');
  is once($config), $quiet, 'and so is the cycle that misses one tag';
  is $recorded->()->{absent}, ['refs/tags/v2'], 'which is absent now';

  # The filter loses the branch and the repository its last tag in one step:
  # of three recorded tips, one is a configured ref the last poll saw.
  configure('signal', $fixture, 'refs/tags/*');
  git($fixture, 'update-ref', '-d', 'refs/tags/v1');
  my $before = age($state);
  my $outcome = once($config);
  is [ $outcome->@[ 0, 1 ] ], [ undef, 1 ], 'a filter that finds nothing any more is reported by --once';
  is scalar($outcome->[2]->@*), 1, 'with one line';
  like $outcome->[2][0], $line->(1),
    'counting neither the ref outside the filter nor the one that was gone before';
  unlike $outcome->[2][0], qr/keeping|state\/repositories/,
    'and no longer speaking of tips it keeps or of their file';
  is aged($state), $before, 'the state is not written';
  like once($config)->[2][0], $line->(1), 'the line repeats in the next cycle';

  # The same from the poller, with the filter the configuration has now.
  my $store = SimpiCI::Store->new(root => $root->child('signal'));
  my $poller = SimpiCI::Source::GitPoll->new(
    store => $store, runner => SimpiCI::Queue->new(store => $store),
    repository => $json->decode($config->slurp_utf8)->{repositories}[0]);
  is $poller->rejection({}), 'remote returned no refs, configured refs seen at the last poll: 1',
    'the reason is the one the poller gives';
  like dies { $poller->poll({}) },
    qr/SimpiCI::Source::GitPoll remote returned no refs, configured refs seen at the last poll: 1 /,
    'and what a poll refuses the observation with';

  # No recorded ref is asked for any more: the empty answer is what the
  # filter expects, not a repository that lost its refs.
  configure('signal', $fixture, 'refs/pull/*');
  is once($config), $quiet, 'a filter that selects no recorded ref is polled without a line';
  is [ sort keys $recorded->()->{tips}->%* ], ['refs/heads/main', 'refs/tags/v1', 'refs/tags/v2'],
    'every tip is still recorded';
  is $recorded->()->{absent}, ['refs/heads/main', 'refs/tags/v1', 'refs/tags/v2'],
    'each as absent';

  # Refs that were absent at the last poll are not missed either.
  configure('signal', $fixture, 'refs/heads/main', 'refs/tags/*');
  git($fixture, 'branch', '-m', 'trunk');
  is once($config), $quiet, 'refs that were away at the last poll already are not reported again';
  is runs_of('signal'), [], 'and nothing was built in all of it';
}

done_testing;
