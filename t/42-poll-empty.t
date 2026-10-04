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

sub commit {
  my ( $fixture, $message ) = @_;
  git($fixture, 'commit', '-q', '--allow-empty', '-m', $message);
}

# A reachable repository without a single ref, as a mirror is before its
# first synchronisation.
sub empty_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name);
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  return $fixture;
}

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = empty_fixture($name);
  commit($fixture, 'fixture');
  return $fixture;
}

sub swap {
  my ( $from, $to ) = @_;
  rename "$from", "$to" or croak 'cannot move fixture: '.$!;
}

sub repository {
  my ( $clone_url, %override ) = @_;
  return { name => 'owner/'.path($clone_url)->basename, clone_url => "$clone_url",
    refs => ['refs/heads/main', 'refs/tags/*'], build_initial => JSON->false, %override };
}

sub daemon_config {
  my ( $state, $repositories ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, repositories => $repositories
  }));
  return $file;
}

sub state_file {
  my ( $state, $repository ) = @_;
  return $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json');
}

# Repository and ref of every run in a state root, in run order.
sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { join ' ', $json->decode($_->slurp_utf8)->@{qw( repository ref )} }
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
  return ( $died, $status, $warnings // [] );
}

#### A mirror answers without refs and gets them back

# The mirror comes first, so the repository behind it is only reached when
# the cycle goes on. The mirror carries a tag that is never built: it is part
# of the baseline.
my $mirror = git_fixture('mirror');
git($mirror, 'tag', 'old');
my $behind = git_fixture('behind');
my @repositories = ( repository($mirror), repository($behind, build_initial => JSON->true) );
my $config = daemon_config('local', \@repositories);
my $mirror_state = state_file('local', $repositories[0]);

my ( $died, $status, $warnings ) = once($config);
is [ $died, $status, $warnings ], [ undef, 0, [] ], 'the baseline cycle is quiet';
is runs_of('local'), ['owner/behind refs/heads/main'], 'and builds no tip of the mirror';
my $baseline = $mirror_state->slurp_utf8;
is [ sort keys $json->decode($baseline)->%* ], ['refs/heads/main', 'refs/tags/old'],
  'whose branch and tag are recorded';

swap($mirror, "$mirror.synced");
empty_fixture('mirror');
commit($behind, 'second');
( $died, $status, $warnings ) = once($config);
is $died, undef, 'simpicid survives a mirror that answers without refs';
is $status, 1, '--once reports it in its exit status';
is scalar(@$warnings), 1, 'with one message';
like $warnings->[0],
  qr/\Asimpicid: repository owner\/mirror \(\Q$mirror\E\) not polled: remote returned no refs, keeping recorded tips: 2 in state\/repositories\/[0-9a-f]{64}\.json\n\z/,
  'naming the repository, the reason and the state that is kept';
unlike $warnings->[0], qr/ls-remote failed/, 'which is not a git failure';
is $mirror_state->slurp_utf8, $baseline, 'the recorded tips stay as they were';
is runs_of('local'), ['owner/behind refs/heads/main', 'owner/behind refs/heads/main'],
  'and the repository behind the mirror is polled and built';

path($mirror)->remove_tree;
swap("$mirror.synced", $mirror);
( $died, $status, $warnings ) = once($config);
is [ $died, $status, $warnings ], [ undef, 0, [] ], 'the cycle that gets the refs back is quiet';
is scalar(runs_of('local')->@*), 2, 'and builds neither the branch nor the old tag';

commit($mirror, 'second');
once($config);
is runs_of('local')->[-1], 'owner/mirror refs/heads/main', 'a new commit is built as before';
is scalar(runs_of('local')->@*), 3, 'and nothing else';

#### An empty baseline has nothing to keep

# A repository without refs at its first poll gets no baseline at all, see
# t/44-poll-no-refs.t. This one has a branch then, only not a configured one,
# and loses every ref afterwards.
my $fresh = git_fixture('fresh');
git($fresh, 'branch', '-m', 'develop');
my $fresh_repository = repository($fresh);
my $fresh_config = daemon_config('fresh.state', [ $fresh_repository ]);
my $fresh_state = state_file('fresh.state', $fresh_repository);
( $died, $status, $warnings ) = once($fresh_config);
is [ $died, $status, $warnings ], [ undef, 0, [] ],
  'a repository without a configured ref is quiet when nothing is recorded for it';
is $json->decode($fresh_state->slurp_utf8), {}, 'and gets an empty baseline';
swap($fresh, "$fresh.synced");
empty_fixture('fresh');
( $died, $status, $warnings ) = once($fresh_config);
is [ $died, $status, $warnings ], [ undef, 0, [] ],
  'which a repository that lost all its refs leaves alone';
is $json->decode($fresh_state->slurp_utf8), {}, 'and empty';
# The documented rule for refs that appear after the first poll.
commit($fresh, 'first');
once($fresh_config);
is runs_of('fresh.state'), ['owner/fresh refs/heads/main'],
  'a ref that appears after an empty baseline is built';

#### Only the observation is survivable

# Recorded tips that cannot be read are not a reason to keep them.
my $unsynced = empty_fixture('unsynced');
my $unsynced_repository = repository($unsynced);
my $unsynced_state = state_file('corrupt', $unsynced_repository);
$unsynced_state->parent->mkpath;
$unsynced_state->spew_utf8('{"refs/heads/main":');
( $died, $status, $warnings ) = once(daemon_config('corrupt', [ $unsynced_repository ]));
ok $died, 'unreadable recorded tips still end the daemon';
is $warnings, [], 'and are not reported as a repository that was not polled';

#### The rule belongs to the poll

my $store = SimpiCI::Store->new(root => $root->child('library'));
my $tagged = git_fixture('tagged');
git($tagged, 'tag', 'v1');
my $poller = SimpiCI::Source::GitPoll->new(
  store => $store, runner => SimpiCI::Queue->new(store => $store),
  repository => repository($tagged, refs => ['refs/tags/*']));
my $tagged_state = state_file('library', $poller->repository);

is $poller->rejection({}), undef, 'no refs are acceptable while nothing is recorded';
is $poller->poll, [], 'the baseline of a tag pattern enqueues nothing';
my $recorded = $tagged_state->slurp_utf8;
is $poller->rejection($json->decode($recorded)), undef, 'an observation with refs is acceptable';

# The remote has refs, but none the configured pattern matches.
git($tagged, 'tag', '-d', 'v1');
is $poller->observe, {}, 'a pattern that matches nothing is observed as no refs';
like $poller->rejection({}),
  qr/\Aremote returned no refs, keeping recorded tips: 1 in state\/repositories\/[0-9a-f]{64}\.json\z/,
  'which is refused against recorded tips';
like dies { $poller->poll }, qr/SimpiCI::Source::GitPoll remote returned no refs, keeping recorded tips: 1 /,
  'a poll that observes by itself refuses it';
like dies { $poller->poll({}) }, qr/remote returned no refs/, 'and so does a poll that is handed it';
is $tagged_state->slurp_utf8, $recorded, 'neither touches the recorded tips';

git($tagged, 'tag', 'v1');
is $poller->poll, [], 'the tag that is back at its recorded commit enqueues nothing';
commit($tagged, 'second');
git($tagged, 'tag', 'v2');
is [ map { $_->{ref} } $poller->poll->@* ], ['refs/tags/v2'], 'a new tag is enqueued as before';

$tagged_state->spew_utf8('{}');
is $poller->rejection({}), undef, 'no refs are acceptable against an empty baseline';

done_testing;
