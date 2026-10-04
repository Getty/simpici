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
use Fcntl qw( LOCK_EX LOCK_NB LOCK_UN );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use Time::HiRes qw( sleep time );

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

#### A remote that does not answer

# git runs this in place of ssh. It holds a shared lock for as long as it or
# its child is alive, which is how the test sees whether anything survived: a
# process that is gone has released it, reaped or not. Every sleep is bounded,
# so nothing outlives a broken test for long.
my $helper_log = $root->child('helper.log');
my $helper = $root->child('helper.pl');
$helper->spew_utf8(<<'HELPER');
use strict;
use warnings;
use Fcntl qw( LOCK_SH );
use POSIX qw( setsid );

my $mode = $ENV{SIMPICI_TEST_HELPER_MODE} // 'hang';
if ($mode eq 'noisy') {
  # More than a pipe holds, before anything is written to standard output.
  print STDERR 'noise '.( 'x' x 1017 )."\n" for 1 .. 300;
  exit 1;
}
open my $lock, '>>', $ENV{SIMPICI_TEST_HELPER_LOG} or exit 97;
flock $lock, LOCK_SH or exit 97;
$lock->autoflush(1);
$SIG{TERM} = 'IGNORE';
print STDERR "helper: still connecting\n";
my $child = fork // exit 97;
setsid if $mode eq 'escape' && !$child;
print {$lock} $$."\n";
sleep 60;
HELPER

# Whether a helper or one of its children is still alive.
sub helper_alive {
  open my $lock, '>>', "$helper_log" or croak 'cannot open '.$helper_log.': '.$!;
  return 1 unless flock $lock, LOCK_EX | LOCK_NB;
  flock $lock, LOCK_UN;
  return 0;
}

sub helper_pids {
  return $helper_log->is_file ? grep { /\A[1-9][0-9]*\z/ } $helper_log->lines({ chomp => 1 }) : ();
}

# A process killed a moment ago still holds its lock until the kernel has
# torn it down.
sub helper_gone {
  my $deadline = time + 5;
  while (helper_alive()) {
    return 0 if time > $deadline;
    sleep 0.05;
  }
  return 1;
}

END {
  local $?;
  kill 'KILL', helper_pids() if defined $helper_log && helper_alive();
}

# The emergency brake: a poller without a limit must fail this test, not hang
# it. Returns what the code returned, what it died of and how long it took.
sub bounded {
  my ( $code ) = @_;
  my $started = time;
  my $result;
  my $died = dies {
    local $SIG{ALRM} = sub { die "emergency brake of the test: no answer for 12 s\n" };
    alarm 12;
    $result = $code->();
    alarm 0;
  };
  alarm 0;
  return ( $result, $died, time - $started );
}

sub git {
  my ( $fixture, @command ) = @_;
  system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
    '-c', 'user.email=test@example.invalid', @command) == 0
    or croak 'git '.$command[0].' failed';
}

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name);
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  git($fixture, 'commit', '-q', '--allow-empty', '-m', 'fixture');
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
    root => $root->child($state)->stringify, %top, repositories => $repositories
  }));
  return $file;
}

sub state_file {
  my ( $state, $repository ) = @_;
  return $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json');
}

# Repository and state of every run in a state root, in run order.
sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { join ' ', $json->decode($_->slurp_utf8)->@{qw( repository state )} }
    sort { $a->basename('.json') <=> $b->basename('.json') }
    grep { $_->basename =~ /\A[1-9][0-9]*\.json\z/ } $directory->children ];
}

my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);

# One polling cycle in this process: what it returned, what it warned, what it
# died of and how long it took.
sub once {
  my ( $config ) = @_;
  my $warnings;
  my ( $status, $died, $elapsed ) = bounded(sub {
    my $returned;
    $warnings = warnings {
      $returned = SimpiCI::App::Eventd->run('--config', "$config", '--once',
        '--runner', "$runner_script");
    };
    return $returned;
  });
  return ( $died, $status, $warnings // [], $elapsed );
}

sub poller {
  my ( $state, $repository, @arguments ) = @_;
  my $store = SimpiCI::Store->new(root => $root->child($state));
  return SimpiCI::Source::GitPoll->new(store => $store,
    runner => SimpiCI::Queue->new(store => $store), repository => $repository, @arguments);
}

# No network and no ssh: git starts the helper for this URL and waits for it.
local $ENV{GIT_SSH_COMMAND} = "'".$^X."' '".$helper."'";
local $ENV{SIMPICI_TEST_HELPER_LOG} = "$helper_log";
delete local $ENV{GIT_SSH};
# Otherwise git first asks the helper which ssh it is, with its output discarded.
local $ENV{GIT_SSH_VARIANT} = 'simple';
delete local $ENV{GIT_ALLOW_PROTOCOL};
delete local $ENV{SIMPICI_TEST_HELPER_MODE};
my $silent = 'ssh://forge.invalid/owner/silent.git';

#### One polling cycle

# The silent repository comes first, so the readable one is only reached when
# the cycle goes on. It has recorded tips that must survive.
my $good = git_fixture('good');
my @repositories = ( repository($silent), repository($good) );
my $config = daemon_config('local', \@repositories, ls_remote_timeout => 1);
my $recorded = $json->encode({ 'refs/heads/main' => '1' x 40 });
state_file('local', $repositories[0])->touchpath->spew_utf8($recorded);

my ( $died, $status, $warnings, $elapsed ) = once($config);
is $died, undef, 'simpicid survives a repository that does not answer';
is $status, 1, '--once reports it in its exit status';
is scalar(@$warnings), 1, 'with one message';
like $warnings->[0],
  qr/\Asimpicid: repository owner\/silent\.git \(\Q$silent\E\) not polled: .*git ls-remote timed out after 1 s: helper: still connecting /,
  'naming the repository, the reason, the limit and what git had printed by then';
is scalar(() = $warnings->[0] =~ /\n/g), 1, 'on a single line';
ok $elapsed >= 1 && $elapsed < 8, 'the cycle waited for the limit and not much longer'
  or diag 'took '.$elapsed.' s';
ok scalar(helper_pids()), 'git had started the helper that does not answer';
ok helper_gone(), 'neither the helper nor its child is left running, though they ignore TERM';
is state_file('local', $repositories[0])->slurp_utf8, $recorded,
  'the recorded tips of the silent repository stay as they were';
is runs_of('local'), ['owner/good success'], 'and the repository behind it is polled and built';

#### The limit belongs to the observation

# A helper that leaves the process group is out of reach, but the standard
# error it keeps open must not hold up the poller.
{
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'escape';
  my $escaping = poller('library', repository($silent), ls_remote_timeout => 1);
  ( undef, $died, $elapsed ) = bounded(sub { $escaping->observe });
  like $died, qr/git ls-remote timed out after 1 s/,
    'an observation without the daemon is limited as well';
  ok $elapsed < 8, 'and does not wait for a process that kept its pipes'
    or diag 'took '.$elapsed.' s';
  ok !$root->child('library', 'state')->exists, 'it leaves no state behind';
  kill 'KILL', helper_pids();
  ok helper_gone(), 'the escaped helper is cleaned up by the test';
}

#### Both pipes are read while git runs

{
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'noisy';
  my $noisy = poller('library', repository($silent), ls_remote_timeout => 10);
  ( undef, $died, $elapsed ) = bounded(sub { $noisy->observe });
  like $died, qr/git ls-remote failed: noise x.*Could not read from remote repository/s,
    'a remote that fails after a lot of standard error is reported as failed';
  ok $elapsed < 5, 'without waiting for the limit' or diag 'took '.$elapsed.' s';
}

my $many = git_fixture('many');
my $wide = poller('library', repository($many, refs => ['refs/heads/main', 'refs/tags/*']),
  ls_remote_timeout => 10);
my $tip = $wide->observe->{'refs/heads/main'};
{
  open my $update, '|-', 'git', '-C', "$many", 'update-ref', '--stdin'
    or croak 'cannot start git update-ref: '.$!;
  print {$update} 'create refs/tags/release-'.$_.' '.$tip."\n" for 1 .. 2000;
  close $update or croak 'git update-ref failed';
}
my ( $observed, $failed );
( $observed, $failed, $elapsed ) = bounded(sub { $wide->observe });
is [ $failed, scalar keys %{ $observed // {} } ], [ undef, 2001 ],
  'more output than a pipe holds is read completely';
ok $elapsed < 5, 'without waiting for the limit' or diag 'took '.$elapsed.' s';

#### The value of the limit

is poller('library', repository($good))->ls_remote_timeout, 60,
  'a poller without an explicit limit waits 60 s';
for my $invalid (0, -1, 1.5, 'soon', undef) {
  like dies { poller('library', repository($good), ls_remote_timeout => $invalid) },
    qr/ls_remote_timeout/, 'a limit of '.( $invalid // 'undef' ).' is refused';
}
( $died, $status, $warnings ) = once(daemon_config('invalid', [ repository($good) ],
  ls_remote_timeout => 0));
like $died, qr/ls_remote_timeout/, 'a limit of 0 in the configuration ends the daemon';
is $warnings, [], 'instead of polling without a limit';
ok !state_file('invalid', repository($good))->exists, 'and nothing is polled';

done_testing;
