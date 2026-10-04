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
use Time::HiRes qw( time );

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

# Every git of this test goes through a wrapper that writes down the patterns
# of each ls-remote, one query a line, and can make the query without
# patterns fail or hang and the one with patterns slow.
my ( $real_git ) = grep { -x } map { path($_)->child('git')->stringify }
  grep { length } split /:/, $ENV{PATH};
croak 'no git in PATH' unless defined $real_git;
my $query_log = $root->child('queries.log');
my $wrapper = $root->child('bin', 'git');
$wrapper->parent->mkpath;
$wrapper->spew_utf8('#!'.$^X."\n".<<'WRAPPER'."exec { '$real_git' } 'git', \@ARGV;\n");
use strict;
use warnings;
if (@ARGV && $ARGV[0] eq 'ls-remote') {
  my @patterns = @ARGV[3 .. $#ARGV];
  open my $log, '>>', $ENV{SIMPICI_TEST_QUERIES} or die 'no query log: '.$!;
  print {$log} join(' ', @patterns)."\n";
  close $log;
  my $whole = $ENV{SIMPICI_TEST_WHOLE} // '';
  if (@patterns) {
    select undef, undef, undef, $ENV{SIMPICI_TEST_DELAY} if $ENV{SIMPICI_TEST_DELAY};
  } elsif ($whole eq 'fail') {
    print STDERR "fatal: the whole repository is not shown\n";
    exit 128;
  } elsif ($whole eq 'hang') {
    sleep 30;
  }
}
WRAPPER
$wrapper->chmod(0755);
$ENV{PATH} = $wrapper->parent.':'.$ENV{PATH};
$ENV{SIMPICI_TEST_QUERIES} = "$query_log";

# The patterns of every ls-remote since the last call.
sub queries {
  # A query without patterns is an empty line, and it may be the only one.
  my @queries = $query_log->is_file ? split /\n/, $query_log->slurp_utf8, -1 : ();
  pop @queries;
  $query_log->remove;
  return \@queries;
}

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
  my ( $name, $branch ) = @_;
  my $fixture = $root->child($name);
  system('git', 'init', '-q', '-b', $branch // 'main', "$fixture") == 0
    or croak 'git init failed';
  return $fixture;
}

sub git_fixture {
  my ( $name, $branch ) = @_;
  my $fixture = empty_fixture($name, $branch);
  commit($fixture, 'fixture');
  return $fixture;
}

# A commit HEAD points at, and no branch.
sub detached_fixture {
  my ( $name ) = @_;
  my $fixture = git_fixture($name);
  git($fixture, 'checkout', '-q', '--detach');
  git($fixture, 'update-ref', '-d', 'refs/heads/main');
  return $fixture;
}

# What git ls-remote prints and how it exits.
sub ls_remote {
  my ( @arguments ) = @_;
  open my $pipe, '-|', 'git', 'ls-remote', '--', @arguments or croak 'cannot run git';
  my $output = do { local $/; <$pipe> } // '';
  close $pipe;
  return [ $? >> 8, [ map { ( split /\t/ )[1] } split /\n/, $output ] ];
}

sub repository {
  my ( $clone_url, %override ) = @_;
  return { name => 'owner/'.path($clone_url)->basename, clone_url => "$clone_url",
    refs => ['refs/heads/main', 'refs/tags/*'], build_initial => JSON->false, %override };
}

sub daemon_config {
  my ( $state, $repositories, %top ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, %top, repositories => $repositories
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

my $store = SimpiCI::Store->new(root => $root->child('library'));

sub poller {
  my ( $repository ) = @_;
  return SimpiCI::Source::GitPoll->new(
    store => $store, runner => SimpiCI::Queue->new(store => $store),
    repository => $repository);
}

my $configured = 'refs/heads/main refs/tags/*';
my $no_refs = qr/SimpiCI::Source::GitPoll repository has no refs yet/;

#### What git says about a repository without refs

# The rule below rests on these answers of the installed git.
my $unborn = empty_fixture('unborn');
is ls_remote("$unborn"), [ 0, [] ], 'a repository without a commit lists nothing, not even HEAD';
system('git', 'init', '-q', '--bare', '-b', 'main', $root->child('bare.git')->stringify) == 0
  or croak 'git init failed';
is ls_remote($root->child('bare.git')->stringify), [ 0, [] ], 'and neither does a bare one';
my $detached = detached_fixture('detached');
is ls_remote("$detached"), [ 0, ['HEAD'] ], 'a commit without a branch is listed as HEAD alone';
my $foreign = detached_fixture('foreign');
git($foreign, 'update-ref', 'refs/pull/1/head', 'HEAD');
git($foreign, 'update-ref', 'refs/notes/commits', 'HEAD');
git($foreign, 'symbolic-ref', 'HEAD', 'refs/heads/main');
is ls_remote("$foreign"), [ 0, ['refs/notes/commits', 'refs/pull/1/head'] ],
  'refs outside branches and tags are listed without patterns';
is ls_remote("$foreign", 'refs/heads/main', 'refs/tags/*'), [ 0, [] ],
  'and not with the configured ones';
queries();

#### A mirror that is not synchronised yet

# The mirror comes first, so the repository behind it is only reached when
# the cycle goes on.
my $mirror = empty_fixture('mirror');
my $behind = git_fixture('behind');
my @repositories = ( repository($mirror), repository($behind, build_initial => JSON->true) );
my $config = daemon_config('local', \@repositories);
my $mirror_state = state_file('local', $repositories[0]);

for my $cycle ('first', 'second') {
  my ( $died, $status, $warnings ) = once($config);
  is $died, undef, 'simpicid survives a repository without refs in the '.$cycle.' cycle';
  is $status, 1, '--once reports it in its exit status';
  is scalar(@$warnings), 1, 'with one message';
  like $warnings->[0],
    qr/\Asimpicid: repository owner\/mirror \(\Q$mirror\E\) not polled: SimpiCI::Source::GitPoll repository has no refs yet at /,
    'naming the repository and the reason';
  unlike $warnings->[0], qr/ls-remote failed/, 'which is not a git failure';
  ok !$mirror_state->exists, 'no baseline is written for it';
  is queries(), [ $configured, '', $configured ],
    'it is asked a second time without patterns, the repository behind it once';
}
is runs_of('local'), ['owner/behind refs/heads/main'],
  'the repository behind the mirror is polled and built';

# The synchronisation brings a branch and a tag that was never built.
commit($mirror, 'first');
git($mirror, 'tag', 'old');
my ( $died, $status, $warnings ) = once($config);
is [ $died, $status, $warnings ], [ undef, 0, [] ], 'the cycle that sees the refs is quiet';
is runs_of('local'), ['owner/behind refs/heads/main'],
  'and builds neither the branch nor the old tag';
is [ sort keys $json->decode($mirror_state->slurp_utf8)->%* ],
  ['refs/heads/main', 'refs/tags/old'], 'they are the baseline';
is queries(), [ $configured, $configured ], 'no repository is asked twice';

commit($mirror, 'second');
once($config);
is runs_of('local'), ['owner/behind refs/heads/main', 'owner/mirror refs/heads/main'],
  'a new commit is built as before';

#### build_initial decides once the refs are there

my $initial = empty_fixture('initial');
my $initial_repository = repository($initial, build_initial => JSON->true);
my $initial_config = daemon_config('initial.state', [ $initial_repository ]);
( $died, $status, $warnings ) = once($initial_config);
is [ $died, $status, scalar @$warnings ], [ undef, 1, 1 ],
  'a repository without refs is not polled with build_initial either';
ok !state_file('initial.state', $initial_repository)->exists, 'and gets no baseline';
commit($initial, 'first');
( $died, $status, $warnings ) = once($initial_config);
is [ $died, $status, $warnings ], [ undef, 0, [] ], 'its first refs are a first observation';
is runs_of('initial.state'), ['owner/initial refs/heads/main'], 'which build_initial builds';
queries();

#### Refs, but none of the configured ones

my $untagged = git_fixture('untagged', 'develop');
my $untagged_repository = repository($untagged);
my $untagged_config = daemon_config('untagged.state', [ $untagged_repository ]);
my $untagged_state = state_file('untagged.state', $untagged_repository);
( $died, $status, $warnings ) = once($untagged_config);
is [ $died, $status, $warnings ], [ undef, 0, [] ],
  'a repository that has refs, but none of the configured ones, is quiet';
is $json->decode($untagged_state->slurp_utf8), {}, 'and gets an empty baseline';
is queries(), [ $configured, '' ], 'after one query without patterns';
( $died, $status, $warnings ) = once($untagged_config);
is [ $died, $status, $warnings ], [ undef, 0, [] ], 'a second empty answer is quiet as well';
is queries(), [ $configured ], 'and the baseline spares the second query';
git($untagged, 'tag', 'v1');
once($untagged_config);
is runs_of('untagged.state'), ['owner/untagged refs/tags/v1'],
  'the first tag after an empty baseline is built';
queries();

#### What counts as a ref

like dies { poller(repository($detached))->observe }, $no_refs,
  'HEAD alone is not a ref of the repository';
is poller(repository($foreign))->observe, {},
  'a ref outside branches and tags is one: its repository has been filled';
queries();

like dies { poller(repository($unborn, refs => []))->observe }, $no_refs,
  'without configured refs the one answer is the whole repository';
is queries(), [''], 'and is not asked for again';

#### Recorded tips are not asked about twice

my $kept = git_fixture('kept');
my $kept_poller = poller(repository($kept));
$kept_poller->poll;
rename "$kept", "$kept.synced" or croak 'cannot move fixture: '.$!;
empty_fixture('kept');
queries();
like dies { $kept_poller->poll }, qr/remote returned no refs, keeping recorded tips: 1 /,
  'an empty answer against recorded tips is refused as before';
is queries(), [ $configured ], 'with the one query';

#### The second query is an observation like the first

my $flaky = empty_fixture('flaky');
my $flaky_repository = repository($flaky);
my $flaky_state = state_file('flaky.state', $flaky_repository);
{
  local $ENV{SIMPICI_TEST_WHOLE} = 'fail';
  ( $died, $status, $warnings ) = once(daemon_config('flaky.state', [ $flaky_repository ]));
  is [ $died, $status, scalar @$warnings ], [ undef, 1, 1 ],
    'simpicid survives a second query that fails';
  like $warnings->[0],
    qr/not polled: SimpiCI::Source::GitPoll git ls-remote failed: fatal: the whole repository is not shown/,
    'and reports what git printed';
  ok !$flaky_state->exists, 'without a baseline';
}
{
  # Two seconds of the three are spent on the first query.
  local $ENV{SIMPICI_TEST_DELAY} = 2;
  local $ENV{SIMPICI_TEST_WHOLE} = 'hang';
  my $started = time;
  ( $died, $status, $warnings ) = once(
    daemon_config('flaky.state', [ $flaky_repository ], ls_remote_timeout => 3));
  my $elapsed = time - $started;
  is [ $died, $status, scalar @$warnings ], [ undef, 1, 1 ],
    'simpicid survives a second query that hangs';
  like $warnings->[0], qr/not polled: SimpiCI::Source::GitPoll git ls-remote timed out after 3 s/,
    'and reports the limit';
  ok $elapsed < 5, 'which both queries share: '.sprintf('%.1f', $elapsed).' s'
    or diag 'a limit for each query would take 6 s';
  ok !$flaky_state->exists, 'without a baseline';
}
queries();

#### Callers without the daemon

my $direct = poller(repository(empty_fixture('direct')));
my $direct_state = state_file('library', $direct->repository);
like dies { $direct->poll }, $no_refs, 'a poll that observes by itself refuses a repository without refs';
ok !$direct_state->exists, 'and writes no baseline';
is $direct->rejection({}), undef, 'the rejection stays a matter of the recorded tips';
# Whether the repository has refs is known to the observation alone.
is $direct->poll({}), [], 'an observation that is handed over is taken as observed';
is $json->decode($direct_state->slurp_utf8), {}, 'and becomes the baseline';

done_testing;
