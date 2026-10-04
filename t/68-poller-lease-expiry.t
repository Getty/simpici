#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::App::Run;
use SimpiCI::Dispatcher;
use SimpiCI::Queue;
use SimpiCI::Store;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );

# simpicid in dispatcher mode ends the leases that ran out in every cycle,
# before it reads a repository. No worker has to ask for anything, and a
# repository that cannot be read does not keep it from that.

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'poller-secret-value';
my $token = $root->child('token');
$token->spew_utf8($value."\n");
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
  my ( $clone_url ) = @_;
  return { name => 'owner/'.path($clone_url)->basename, clone_url => "$clone_url",
    refs => ['refs/heads/main'], build_initial => JSON->true, secrets => [{
      name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
    }] };
}

# A dispatcher configuration with a state root of its name.
sub configure {
  my ( $state, $repositories, %top ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, mode => 'dispatcher', interval => 1, %top,
    repositories => $repositories
  }));
  return $file;
}

# One polling cycle in this process: what it died of, what it returned and
# what it wrote to standard error.
sub once {
  my ( $config ) = @_;
  my ( $status, $warnings );
  my $died = dies {
    $warnings = warnings { $status = SimpiCI::App::Eventd->run('--config', "$config", '--once') };
  };
  return [ $died, $status, $warnings // [] ];
}

my $quiet = [ undef, 0, [] ];

sub record { $json->decode($root->child($_[0], 'queue', $_[1].'.json')->slurp_utf8) }

sub report { $json->decode($root->child($_[0], 'public', 'runs', $_[1].'.json')->slurp_utf8) }

sub snapshot { $root->child($_[0], 'claims', $_[1].'.json') }

sub expire {
  my ( $state, $run ) = @_;
  my $record = record($state, $run);
  $record->{expires} = time - 1;
  SimpiCI::Store->new(root => $root->child($state))->write_json('queue/'.$run.'.json', $record);
}

# What simpici-dispatch does with a request, on the state root of that name.
sub dispatcher {
  my ( $state, $config ) = @_;
  return SimpiCI::Dispatcher->new(
    queue  => SimpiCI::Queue->new(store => SimpiCI::Store->new(root => $root->child($state))),
    config => $json->decode($config->slurp_utf8));
}

sub everything_below {
  my ( $directory ) = @_;
  my $content = '';
  $directory->visit(sub { $content .= $_->slurp_raw if $_->is_file }, { recurse => 1 });
  return $content;
}

sub interrupted_line {
  my ( $run ) = @_;
  return 'simpicid: run '.$run." interrupted: its lease expired without a completion\n";
}

#### One cycle

my $good = git_fixture('good');
my $config = configure('once', [ repository($good) ]);
is once($config), $quiet, 'a first cycle is quiet';
is report('once', 1)->{state}, 'queued', 'and queues the tip of the repository';
my $claim = dispatcher('once', $config)->request('vm', { operation => 'claim' });
is $claim->{secrets}, { publish => { PUBLISH_TOKEN => $value }, deploy => { PUBLISH_TOKEN => $value } },
  'a worker claims it with its secret';
ok snapshot('once', 1)->is_file, 'the dispatcher keeps the snapshot of the claim';

is once($config), $quiet, 'a cycle while the lease stands is quiet';
is record('once', 1)->{state}, 'running', 'and leaves the run running';
ok snapshot('once', 1)->is_file, 'with its snapshot';

expire('once', 1);
is once($config), [ undef, 0, [ interrupted_line(1) ] ],
  'the cycle after the lease ran out says so in one line and returns zero';
is record('once', 1)->{state}, 'interrupted', 'the run is interrupted, with no worker asking';
is report('once', 1)->{state}, 'interrupted', 'and published as that';
ok !snapshot('once', 1)->exists, 'its snapshot is removed';
unlike everything_below($root->child('once')), qr/\Q$value\E/,
  'no file of the dispatcher state holds the value any more';
is once($config), $quiet, 'the next cycle has nothing to say about it';
is dispatcher('once', $config)->request('vm', { operation => 'finish', run => 1,
  token => $claim->{token}, result => { state => 'success', exit_code => 0 }, log => $value }),
  { rejected => 'expired claim' }, 'the late completion is refused';
ok !$root->child('once/public/runs/1.log')->exists, 'and publishes no log';

#### A repository that is not polled

my $absent = $root->child('absent');
$config = configure('unread', [ repository($good) ]);
is once($config), $quiet, 'a second state root queues the tip';
dispatcher('unread', $config)->request('vm', { operation => 'claim' });
expire('unread', 1);
# The same root, and nothing in the configuration can be read any more.
$config = configure('unread', [ repository($absent) ]);
my ( $died, $status, $warnings ) = once($config)->@*;
is [ $died, $status ], [ undef, 1 ], 'a cycle that reads no repository returns 1';
is $warnings->[0], interrupted_line(1), 'it has ended the expired lease first';
like $warnings->[1], qr/\Asimpicid: repository owner\/absent \(\Q$absent\E\) not polled: /,
  'and then says what it could not read';
is scalar(@$warnings), 2, 'in two lines';
is record('unread', 1)->{state}, 'interrupted', 'the run is interrupted';
ok !snapshot('unread', 1)->exists, 'and its snapshot is removed';

$config = configure('none', [ repository($good) ]);
once($config);
dispatcher('none', $config)->request('vm', { operation => 'claim' });
expire('none', 1);
is once(configure('none', [])), [ undef, 0, [ interrupted_line(1) ] ],
  'a configuration without a repository ends the expired lease all the same';
ok !snapshot('none', 1)->exists, 'and removes the snapshot';

#### A snapshot that cannot be removed

SKIP: {
  skip 'the superuser can remove it', 5 unless $>;
  $config = configure('kept', [ repository($good) ]);
  once($config);
  dispatcher('kept', $config)->request('vm', { operation => 'claim' });
  expire('kept', 1);
  $root->child('kept/claims')->chmod(0500);
  my $kept = once($config);
  $root->child('kept/claims')->chmod(0700);
  like $kept->[0], qr/SimpiCI::Dispatcher cannot remove secret snapshot \S+claims\/1\.json: /,
    'a snapshot that cannot be removed ends the daemon, with the file in the message';
  unlike $kept->[0], qr/\Q$value\E/, 'not the value';
  is record('kept', 1)->{state}, 'interrupted', 'the run is interrupted all the same';
  is once($config), $quiet, 'the next start removes it and has nothing more to say';
  ok !snapshot('kept', 1)->exists, 'the snapshot is gone';
}

#### Local mode

$config = configure('local', [ repository($good) ]);
once($config);
dispatcher('local', $config)->request('vm', { operation => 'claim' });
expire('local', 1);
my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);
my $local = configure('local', [ repository($good) ], mode => 'local', runner => "$runner_script");
is once($local)->[2], [], 'a daemon in local mode says nothing of a queue';
is record('local', 1)->{state}, 'running', 'and does not touch one';
ok snapshot('local', 1)->is_file, 'nor its snapshots';

#### A dispatcher that dies between the lease and its answer

for my $case (
  [ 'before-snapshot', 'before the snapshot is written',
    sub { $_[0]->queue->claim('vm') }, 0 ],
  [ 'before-answer', 'after the snapshot is written',
    sub { $_[0]->request('vm', { operation => 'claim' }) }, 1 ]
) {
  my ( $state, $name, $lease, $has_snapshot ) = @$case;
  $config = configure($state, [ repository($good) ]);
  once($config);
  my $dispatcher = dispatcher($state, $config);
  # The lease is saved, and nothing of it reaches the worker.
  $lease->($dispatcher);
  is record($state, 1)->{state}, 'running', $name.': the run is leased';
  is snapshot($state, 1)->is_file ? 1 : 0, $has_snapshot,
    $name.': '.( $has_snapshot ? 'with' : 'without' ).' a snapshot';
  is $dispatcher->request('vm', { operation => 'claim' }), {},
    $name.': the worker asks again and gets nothing, the run is not handed out twice';
  is once($config), $quiet, $name.': the daemon leaves it while the lease stands';
  is record($state, 1)->{state}, 'running', $name.': it stays running';
  expire($state, 1);
  is once($config), [ undef, 0, [ interrupted_line(1) ] ],
    $name.': the first cycle after the lease ran out ends it';
  is report($state, 1)->{state}, 'interrupted', $name.': the run is published as interrupted';
  ok !snapshot($state, 1)->exists, $name.': and no snapshot is left';
  is $dispatcher->request('vm', { operation => 'claim' }), {},
    $name.': it is not handed out afterwards either';
  is once($config), $quiet, $name.': and the unchanged tip is not queued again';
  is [ map { $_->basename } $root->child($state, 'queue')->children ], ['1.json'],
    $name.': the queue has the one run';
}

#### Making up for a run that never ran

# As deploy/README.md describes it: a new commit is a new run, and the same
# commit is queued again once its queue entry is removed and its ref forgotten.
$config = configure('before-answer', [ repository($good) ]);
my $tip = record('before-answer', 1)->{event}{commit};
$root->child('before-answer/queue/1.json')->remove;
my $printed = '';
my $forgot = do {
  local *STDOUT;
  open STDOUT, '>', \$printed or croak 'cannot capture standard output';
  SimpiCI::App::Run->run('--config', "$config", '--repository', 'owner/good',
    '--forget', 'refs/heads/main');
};
is $forgot, 0, 'the ref of the interrupted run is forgotten';
like $printed, qr/: forgot refs\/heads\/main, recorded at \Q$tip\E\n\z/, 'at the commit that was not built';
is once($config), $quiet, 'the next cycle is quiet';
is [ record('before-answer', 2)->@{qw( state )}, record('before-answer', 2)->{event}{commit} ],
  [ 'queued', $tip ], 'and queues the same commit as a new run';
is dispatcher('before-answer', $config)->request('vm', { operation => 'claim' })->{run}, 2,
  'which a worker claims';
is report('before-answer', 1)->{state}, 'interrupted', 'the report of the interrupted run stays';
is $json->decode($root->child('before-answer/public/runs/index.json')->slurp_utf8)->{runs}, [2],
  'and the index lists the run that replaced it';

$config = configure('before-snapshot', [ repository($good) ]);
commit($good, 'second');
is once($config), $quiet, 'a new commit on the ref needs nothing of that';
is record('before-snapshot', 2)->{state}, 'queued', 'it is queued as a new run';

#### The running daemon

my $daemon_config = configure('daemon', [ repository($absent), repository($good) ]);
my $daemon_log = $root->child('daemon.log');

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

ok wait_for(sub { $root->child('daemon/queue/1.json')->is_file }),
  'the running daemon queues the readable repository';
$claim = dispatcher('daemon', $daemon_config)->request('vm', { operation => 'claim' });
is $claim->{run}, 1, 'a worker claims the run and is never heard of again';
ok snapshot('daemon', 1)->is_file, 'its snapshot is kept while the lease stands';
expire('daemon', 1);
ok wait_for(sub { record('daemon', 1)->{state} eq 'interrupted' }),
  'a later cycle interrupts the run without a request of any worker';
ok wait_for(sub { !snapshot('daemon', 1)->exists }), 'and removes the snapshot';
ok wait_for(sub { $daemon_log->slurp_utf8 =~ /interrupted/ }), 'the daemon logs it';
is scalar(() = $daemon_log->slurp_utf8 =~ /^\Q@{[ interrupted_line(1) ]}\E/mg), 1, 'in one line, once';
like $daemon_log->slurp_utf8, qr/^simpicid: repository owner\/absent \(\Q$absent\E\) not polled: /m,
  'beside the repository it cannot read';
unlike everything_below($root->child('daemon')), qr/\Q$value\E/,
  'no file of the dispatcher state holds the value';
ok $daemon && waitpid($daemon, WNOHANG) == 0, 'and the daemon is still running';
if ($daemon) {
  kill 'TERM', $daemon;
  waitpid($daemon, 0);
  undef $daemon;
}

done_testing;
