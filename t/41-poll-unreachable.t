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
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $daemon;

END {
  if ($daemon) {
    local $?;
    kill 'KILL', $daemon;
    waitpid($daemon, 0);
  }
}

sub commit {
  my ( $fixture, $message ) = @_;
  system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
    '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty',
    '-m', $message) == 0 or croak 'git commit failed';
}

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name);
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  commit($fixture, 'fixture');
  return $fixture;
}

sub repository {
  my ( $clone_url, %override ) = @_;
  return { name => 'owner/'.path($clone_url)->basename, clone_url => "$clone_url",
    refs => ['refs/heads/main'], build_initial => JSON->true, %override };
}

sub daemon_config {
  my ( $state, $repositories, %top ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, interval => 1, %top,
    repositories => $repositories
  }));
  return $file;
}

sub state_file {
  my ( $state, $repository ) = @_;
  return $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json');
}

# Reports of every run in a state root, in run order.
sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { $json->decode($_->slurp_utf8) }
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

#### One polling cycle

# The unreadable repository comes first, so the readable one is only reached
# when the cycle goes on.
my $good = git_fixture('good');
my $late = $root->child('late');
my $parked = git_fixture('late.parked');
my @repositories = ( repository($late, build_initial => JSON->false), repository($good) );
my $config = daemon_config('local', \@repositories);

my ( $died, $status, $warnings ) = once($config);
is $died, undef, 'simpicid survives a repository it cannot read';
is $status, 1, '--once reports the unread repository in its exit status';
is scalar(@$warnings), 1, 'one message for the one unread repository';
like $warnings->[0],
  qr/\Asimpicid: repository owner\/late \(\Q$late\E\) not polled: .*git ls-remote failed: .*does not appear to be a git repository/,
  'naming the repository, its clone URL and the git error';
is scalar(() = $warnings->[0] =~ /\n/g), 1, 'on a single line';
is [ map { $_->@{qw( repository state )} } runs_of('local')->@* ], ['owner/good', 'success'],
  'the repository behind it is polled and built';
ok !state_file('local', $repositories[0])->exists, 'the unread repository gets no state';
my $observed = state_file('local', $repositories[1])->slurp_utf8;

#### A known repository goes away and comes back

rename "$good", "$good.away" or croak 'cannot move fixture: '.$!;
( $died, $status, $warnings ) = once($config);
is $died, undef, 'simpicid survives a known repository going away';
is $status, 1, 'and reports it';
like $warnings->[1], qr/\Asimpicid: repository owner\/good /, 'and names it';
is state_file('local', $repositories[1])->slurp_utf8, $observed,
  'its recorded observation stays as it was';

rename "$good.away", "$good" or croak 'cannot move fixture: '.$!;
( $died, $status, $warnings ) = once($config);
is scalar(@$warnings), 1, 'the repository is read again once it is back';
is scalar(runs_of('local')->@*), 1, 'and its unchanged tip is not built a second time';

commit($good, 'second');
rename "$parked", "$late" or croak 'cannot move fixture: '.$!;
( $died, $status, $warnings ) = once($config);
is [ $died, $status, $warnings ], [ undef, 0, [] ],
  'a cycle that reads every repository is quiet and returns zero';
is [ map { $_->{repository} } runs_of('local')->@* ], ['owner/good', 'owner/good'],
  'a new commit is built, a repository that appears late only gets its baseline';
ok state_file('local', $repositories[0])->is_file, 'which is recorded now';

commit($late, 'second');
once($config);
is [ map { $_->{repository} } runs_of('local')->@* ], ['owner/good', 'owner/good', 'owner/late'],
  'and its next commit is built';

#### Only the observation is survivable

# A state root below a regular file: the remote is readable, the run is not
# startable.
( $died, $status, $warnings ) = once(daemon_config('broken', [ repository($good) ],
  root => $runner_script->child('state')->stringify));
like $died, qr/\Q$runner_script\E/, 'a run that cannot start still ends the daemon';
is $warnings, [], 'and is not reported as an unread repository';

#### An HTTPS clone URL

{
  # No network: git refuses the transport before it connects.
  local $ENV{GIT_ALLOW_PROTOCOL} = 'file';
  ( $died, $status, $warnings ) = once(daemon_config('https', [
    repository('https://forge.invalid/owner/private.git') ]));
  is $status, 1, 'an unreadable HTTPS repository is reported';
  like $warnings->[0], qr/\(https:\/\/forge\.invalid\/owner\/private\.git\)/,
    'with its clone URL';
}
# The daemon refuses credentials in a clone URL before it polls, see
# t/45-config-clone-url.t. The line itself still leaves them out.
is(SimpiCI::App::Eventd->unread_message(
    repository('https://user:s3cr3t@forge.invalid/owner/private.git'),
    "fatal: unable to access 'https://user:s3cr3t\@forge.invalid/owner/private.git/':\n refused\n"),
  'simpicid: repository owner/private.git (https://forge.invalid/owner/private.git) not polled: '
    ."fatal: unable to access 'https://forge.invalid/owner/private.git/': refused\n",
  'an error text that repeats the clone URL loses the credentials as well');
# The user part the rule refuses is the one the line leaves out, whatever the
# scheme; a user name the rule accepts stays.
for my $case (
  [ 'ssh://user:s3cr3t@forge.invalid/owner/private.git', 'ssh://forge.invalid/owner/private.git' ],
  [ 'ftps://user:s3cr3t@forge.invalid/owner/private.git', 'ftps://forge.invalid/owner/private.git' ],
  [ 'user:s3cr3t@forge.invalid:owner/private.git', 'forge.invalid:owner/private.git' ],
  [ 'ssh://git@forge.invalid/owner/private.git', 'ssh://git@forge.invalid/owner/private.git' ],
  [ 'git@forge.invalid:owner/private.git', 'git@forge.invalid:owner/private.git' ]
) {
  my ( $configured, $shown ) = @$case;
  is(SimpiCI::App::Eventd->unread_message(repository($configured),
      "fatal: '".$configured."' is\n not readable\n"),
    'simpicid: repository owner/private.git ('.$shown.") not polled: fatal: '".$shown
      ."' is not readable\n",
    'the line shows '.$shown);
}

#### The daemon keeps polling

my $absent = $root->child('absent');
my $absent_parked = git_fixture('absent.parked');
my $daemon_config = daemon_config('daemon', [ repository($absent), repository($good) ],
  mode => 'dispatcher');
my $daemon_log = $root->child('daemon.log');

sub queued {
  my ( $name ) = @_;
  return scalar grep { $_->{repository} eq $name } runs_of('daemon')->@*;
}

# False as soon as the daemon is gone, so a daemon that died fails fast.
sub wait_for {
  my ( $check ) = @_;
  my $deadline = time + 30;
  until ($check->()) {
    return 0 if !$daemon || time > $deadline;
    if (waitpid($daemon, WNOHANG) != 0) {
      undef $daemon;
      return 0;
    }
    sleep 0.1;
  }
  return 1;
}

$daemon = fork;
croak 'fork failed' unless defined $daemon;
unless ($daemon) {
  open STDOUT, '>', $daemon_log->stringify or POSIX::_exit(97);
  open STDERR, '>&', \*STDOUT or POSIX::_exit(97);
  exec $^X, '-I'.path('lib')->absolute, path('bin/simpicid')->absolute->stringify,
    '--config', "$daemon_config" or POSIX::_exit(98);
}

ok wait_for(sub { queued('owner/good') }), 'the running daemon queues the readable repository';
like $daemon_log->slurp_utf8, qr/^simpicid: repository owner\/absent \(\Q$absent\E\) not polled: /m,
  'and logs the unreadable one';
rename "$absent_parked", "$absent" or croak 'cannot move fixture: '.$!;
ok wait_for(sub { queued('owner/absent') }), 'a later cycle reads the repository that appeared';
ok $daemon && waitpid($daemon, WNOHANG) == 0, 'and the daemon is still running';
if ($daemon) {
  kill 'TERM', $daemon;
  waitpid($daemon, 0);
  undef $daemon;
}

#### The observation is its own step

my $store = SimpiCI::Store->new(root => $root->child('library'));
my $poller = SimpiCI::Source::GitPoll->new(
  store => $store, runner => SimpiCI::Queue->new(store => $store),
  repository => repository($root->child('never')));
like dies { $poller->observe }, qr/git ls-remote failed: .*does not appear to be a git repository/,
  'an unreadable remote fails the observation';
like dies { $poller->poll }, qr/git ls-remote failed/, 'and a poll that observes by itself';
ok !$store->root->child('state')->exists, 'neither leaves state behind';
my $tips = SimpiCI::Source::GitPoll->new(
  store => $store, runner => $poller->runner, repository => repository($good))->observe;
is [ keys %$tips ], ['refs/heads/main'], 'a readable remote yields its tips';
is scalar($poller->poll($tips)->@*), 1, 'a poll works on the observation it is handed';
is $json->decode(state_file('library', $poller->repository)->slurp_utf8), $tips,
  'and records it without reading the remote again';

done_testing;
