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
use IO::Select;
use IO::Socket::INET;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX ();
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
if ($mode eq 'control') {
  # What a remote can send to the terminal of whoever reads the journal.
  print STDERR "remote: \e[2J\e]0;owned\a tab\there\r\nnul\0del\x7f end\n";
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
if ($mode eq 'flood' && $child) {
  # A remote that never stops talking.
  my $deadline = time + 60;
  my $line = 'flood '.( 'y' x 1017 )."\n";
  1 while time < $deadline && syswrite STDERR, $line;
}
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

#### The limit in dispatcher mode

# The same cycle with a queue in place of the runner: the silent repository
# is given up, the one behind it is enqueued.
{
  $helper_log->remove;
  my @queued = ( repository($silent), repository($good) );
  my ( $died, $status, $warnings, $elapsed ) = once(daemon_config('dispatcher', \@queued,
    mode => 'dispatcher', ls_remote_timeout => 1));
  is [ $died, $status ], [ undef, 1 ],
    'simpicid in dispatcher mode survives a repository that does not answer and says so in its exit status';
  is scalar(@$warnings), 1, 'with one message';
  like $warnings->[0],
    qr/\Asimpicid: repository owner\/silent\.git \(\Q$silent\E\) not polled: .*git ls-remote timed out after 1 s: helper: still connecting /,
    'that names the limit';
  ok $elapsed >= 1 && $elapsed < 8, 'after the limit and not much later' or diag 'took '.$elapsed.' s';
  ok helper_gone(), 'nothing of the query is left running';
  ok !state_file('dispatcher', $queued[0])->exists, 'the silent repository gets no state';
  my $queue = $root->child('dispatcher', 'queue');
  my @records = map { $json->decode($_->slurp_utf8) }
    $queue->is_dir ? $queue->children(qr/\A[1-9][0-9]*\.json\z/) : ();
  is [ map { $_->{state}, $_->{event}{repository} } @records ], [ 'queued', 'owner/good' ],
    'and the repository behind it is enqueued';
}

#### What a query may print

is [ SimpiCI::Source::GitPoll->stdout_limit, SimpiCI::Source::GitPoll->stderr_limit,
  SimpiCI::Source::GitPoll->message_limit ], [ 16 * 1024 * 1024, 1024 * 1024, 1000 ],
  'a query may print 16 MiB of refs and 1 MiB on standard error, of which 1000 characters are repeated';

# The same poller with limits a test reaches.
{
  package SimpiCI::Test::SmallPoll;
  use Moo;
  extends 'SimpiCI::Source::GitPoll';
  sub stdout_limit { 65536 }
  sub stderr_limit { 8192 }
  package SimpiCI::Test::SmallDaemon;
  use parent -norequire, 'SimpiCI::App::Eventd';
  sub poller_class { 'SimpiCI::Test::SmallPoll' }
}

sub small_poller {
  my ( $state, $repository, @arguments ) = @_;
  my $store = SimpiCI::Store->new(root => $root->child($state));
  return SimpiCI::Test::SmallPoll->new(store => $store,
    runner => SimpiCI::Queue->new(store => $store), repository => $repository, @arguments);
}

{
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'noisy';
  my $noisy = small_poller('library', repository($silent), ls_remote_timeout => 10);
  ( undef, $died, $elapsed ) = bounded(sub { $noisy->observe });
  like $died, qr/git ls-remote printed more than 8192 bytes on standard error: noise x/,
    'a query that prints more on standard error than it may is given up';
  ok length($died // '') < 1500, 'and its message repeats a part of that, not all of it'
    or diag length $died;
  ok $elapsed < 5, 'without waiting for the limit of time' or diag 'took '.$elapsed.' s';
}

{
  $helper_log->remove;
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'flood';
  my $flooded = small_poller('library', repository($silent), ls_remote_timeout => 30);
  ( undef, $died, $elapsed ) = bounded(sub { $flooded->observe });
  like $died, qr/git ls-remote printed more than 8192 bytes on standard error/,
    'a remote that does not stop writing is given up at the limit';
  ok $elapsed < 8, 'long before the limit of time' or diag 'took '.$elapsed.' s';
  ok helper_gone(), 'and neither the helper nor its child is left running';
  kill 'KILL', helper_pids();
}

# 2001 refs are more than 65536 bytes. The repository has recorded tips, and
# they stay: an answer that was cut off is no observation.
{
  my @repositories = ( repository($many, refs => ['refs/heads/main', 'refs/tags/*']), repository($good) );
  my $config = daemon_config('wide', \@repositories);
  my $recorded = $json->encode({ tips => { 'refs/heads/main' => '1' x 40 }, absent => [] });
  state_file('wide', $repositories[0])->touchpath->spew_utf8($recorded);
  my $warnings;
  my ( $status, $died ) = bounded(sub {
    my $returned;
    $warnings = warnings {
      $returned = SimpiCI::Test::SmallDaemon->run('--config', "$config", '--once',
        '--runner', "$runner_script");
    };
    return $returned;
  });
  is [ $died, $status ], [ undef, 1 ], 'simpicid survives an answer that is too long and reports it';
  like $warnings->[0] // '',
    qr/\Asimpicid: repository owner\/many \(\Q$many\E\) not polled: .*git ls-remote printed more than 65536 bytes on standard output at /,
    'with a line that names the limit';
  is scalar(@{ $warnings // [] }), 1, 'and no other';
  is state_file('wide', $repositories[0])->slurp_utf8, $recorded, 'the recorded tips stay as they were';
  is runs_of('wide'), ['owner/good success'], 'nothing of the long answer is built, the repository behind it is';
}

#### The line in the journal

{
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'control';
  my ( $died, $status, $warnings ) = once(daemon_config('control', [ repository($silent) ],
    ls_remote_timeout => 10));
  is [ $died, $status, scalar @$warnings ], [ undef, 1, 1 ], 'a remote that sends control characters is not polled';
  my $line = $warnings->[0] // '';
  like $line, qr/git ls-remote failed: remote: \?\[2J\?\]0;owned\? tab here nul\?del\? end /,
    'the line shows a question mark for each of them and a space for what breaks a line';
  unlike $line, qr/[\x00-\x09\x0b-\x1f\x7f]/, 'no control character is left in it';
  is scalar(() = $line =~ /\n/g), 1, 'and it is one line';
}
{
  local $ENV{SIMPICI_TEST_HELPER_MODE} = 'noisy';
  my ( $died, $status, $warnings ) = once(daemon_config('long', [ repository($silent) ],
    ls_remote_timeout => 10));
  my $line = $warnings->[0] // '';
  like $line, qr/git ls-remote failed: noise x+ \[\.\.\.\] x+ .*Could not read from remote repository/,
    'of 300 KiB of standard error the line has the beginning and the end';
  ok length($line) < 1500, 'in less than 1500 characters' or diag length $line;
}
is(SimpiCI::App::Eventd->unread_message(repository($good), "first\tline\nsecond \e[31mline\x7f"),
  'simpicid: repository owner/good ('.$good.') not polled: first line second ?[31mline?'."\n",
  'a reason from elsewhere loses its control characters as well');

#### A daemon that is told to end while a query hangs

# The query is in a process group of its own, so the signal that ends the
# daemon does not reach it: the daemon has to end it.
sub daemon_process {
  my ( $config ) = @_;
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDOUT, '>', $root->child('daemon.out')->stringify or POSIX::_exit(97);
    open STDERR, '>&', \*STDOUT or POSIX::_exit(97);
    exec $^X, '-I'.path('lib')->absolute, path('bin/simpicid')->absolute->stringify,
      '--config', "$config", '--runner', "$runner_script" or POSIX::_exit(98);
  }
  return $pid;
}

sub wait_until {
  my ( $seconds, $condition ) = @_;
  my $deadline = time + $seconds;
  until ($condition->()) {
    return 0 if time > $deadline;
    sleep 0.05;
  }
  return 1;
}

for my $signal (qw( TERM INT HUP )) {
  $helper_log->remove;
  my $pid = daemon_process(daemon_config('stopped-'.$signal, [ repository($silent) ],
    ls_remote_timeout => 40));
  my $started = wait_until(10, sub { scalar helper_pids() });
  ok $started, 'simpicid waits for a repository that does not answer';
  my $sent = time;
  kill $signal, $pid;
  my $status;
  my $ended = wait_until(10, sub { waitpid($pid, POSIX::WNOHANG()) == $pid && defined( $status = $? ) });
  unless ($ended) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
  }
  ok $ended, $signal.' ends it without waiting for the limit' or diag 'no end after '.( time - $sent ).' s';
  is [ ( $status // 0 ) & 127, ( $status // 0 ) >> 8 ], [ POSIX->can('SIG'.$signal)->(), 0 ],
    'it ends by the signal, as it would between two queries';
  ok helper_gone(),
    'and the query it was waiting for is ended with it, the helper that ignores TERM and its child included';
  kill 'KILL', helper_pids();
  ok !state_file('stopped-'.$signal, repository($silent))->exists, 'nothing is recorded for the repository';
}

# Within a caller that has a handler of its own, the signal is passed on to
# it once the query is ended, and the observation fails.
{
  $helper_log->remove;
  my $noted = 0;
  local $SIG{TERM} = sub { $noted++ };
  my $parent = $$;
  my $sender = fork;
  croak 'fork failed' unless defined $sender;
  unless ($sender) {
    my $deadline = time + 20;
    sleep 0.05 until -s "$helper_log" || time > $deadline;
    sleep 0.3;
    kill 'TERM', $parent;
    POSIX::_exit(0);
  }
  my $stopped = poller('library', repository($silent), ls_remote_timeout => 30);
  ( undef, $died, $elapsed ) = bounded(sub { $stopped->observe });
  kill 'KILL', $sender;
  waitpid($sender, 0);
  like $died, qr/git ls-remote stopped by signal TERM/, 'an observation that is stopped fails with the signal';
  is $noted, 1, 'and the caller that has a handler for it receives the signal, once';
  ok $elapsed < 8, 'without waiting for the limit' or diag 'took '.$elapsed.' s';
  ok helper_gone(), 'the query is ended';
  kill 'KILL', helper_pids();
}

# A signal the caller ignores, as HUP under nohup, ends no query.
{
  $helper_log->remove;
  local $SIG{HUP} = 'IGNORE';
  my $parent = $$;
  my $sender = fork;
  croak 'fork failed' unless defined $sender;
  unless ($sender) {
    my $deadline = time + 20;
    sleep 0.05 until -s "$helper_log" || time > $deadline;
    kill 'HUP', $parent;
    POSIX::_exit(0);
  }
  my $ignoring = poller('library', repository($silent), ls_remote_timeout => 2);
  ( undef, $died, $elapsed ) = bounded(sub { $ignoring->observe });
  kill 'KILL', $sender;
  waitpid($sender, 0);
  like $died, qr/git ls-remote timed out after 2 s/, 'a signal the caller ignores does not end the query';
  ok helper_gone(), 'which is ended by its limit';
}

#### Real clients against a server that never answers

# No helper in place of ssh and none in place of the HTTP transport: git
# starts its own programs, and they connect to a listener that accepts the
# connection and then says nothing.
{
  my $listener = IO::Socket::INET->new(Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0,
    Proto => 'tcp', ReuseAddr => 1) or croak 'cannot listen: '.$!;
  my $port = $listener->sockport;
  # How many clients connected, if every one of them has closed its
  # connection: a process that is still there keeps it open.
  my $clients_gone = sub {
    my $select = IO::Select->new($listener);
    my $seen = 0;
    while ($select->can_read(0.5)) {
      my $client = $listener->accept or last;
      $seen++;
      my $reading = IO::Select->new($client);
      while (1) {
        return 0 unless $reading->can_read(5);
        my $read = sysread $client, my $discarded, 65536;
        last unless $read;
      }
    }
    return $seen;
  };
  delete local @ENV{qw( http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY )};
  local $ENV{no_proxy} = '127.0.0.1';
  local $ENV{GIT_TERMINAL_PROMPT} = 0;
  local $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  local $ENV{GIT_CONFIG_NOSYSTEM} = 1;
  delete local $ENV{GIT_SSH_VARIANT};

  chomp( my $exec_path = qx{git --exec-path} );
  SKIP: {
    skip 'git has no HTTP transport here', 4 unless -x $exec_path.'/git-remote-http';
    my $url = 'http://127.0.0.1:'.$port.'/owner/silent.git';
    my $over_http = poller('library', repository($url), ls_remote_timeout => 2);
    ( undef, $died, $elapsed ) = bounded(sub { $over_http->observe });
    like $died, qr/git ls-remote timed out after 2 s/,
      'git over HTTP against a server that never answers is given up';
    ok $elapsed >= 2 && $elapsed < 9, 'after the limit' or diag 'took '.$elapsed.' s';
    ok $clients_gone->(), 'and the transport helper git started has closed its connection';
    ok !$root->child('library', 'state')->exists, 'nothing is recorded';
  }
  SKIP: {
    my ( $ssh ) = grep { -x } map { $_.'/ssh' } split /:/, $ENV{PATH};
    skip 'no ssh client here', 4 unless $ssh;
    local $ENV{GIT_SSH_COMMAND} = $ssh.' -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no'
      .' -o UserKnownHostsFile=/dev/null';
    my $url = 'ssh://git@127.0.0.1:'.$port.'/owner/silent.git';
    my $over_ssh = poller('library', repository($url), ls_remote_timeout => 2);
    ( undef, $died, $elapsed ) = bounded(sub { $over_ssh->observe });
    like $died, qr/git ls-remote timed out after 2 s/,
      'git over the real ssh against a server that never answers is given up';
    ok $elapsed >= 2 && $elapsed < 9, 'after the limit' or diag 'took '.$elapsed.' s';
    ok $clients_gone->(), 'and ssh has closed its connection';
    ok !$root->child('library', 'state')->exists, 'nothing is recorded';
  }
}

done_testing;
