use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use File::Which qw( which );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;

# A command that is ended by a signal has no exit code. It did not succeed:
# the step after it does not start, and the run is not a success.

my $fixture = tempdir;
for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
    ['config', 'user.email', 'test@example.invalid']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
}
$fixture->child('tracked')->spew_utf8('exact revision');
for my $command (['add', '.'], ['commit', '-qm', 'fixture']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
}
my $commit = `git -C $fixture rev-parse HEAD`;
chomp $commit;
my $event = SimpiCI::Event->new(source => 'manual', event => 'push', repository => 'fixture',
  clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit);

# git as the runner finds it: the real one, except that the step named in
# TEST_SIGNAL_STEP ends itself with TEST_SIGNAL. Every step is written down.
my $tools = tempdir;
my $git = $tools->child('bin/git');
$git->parent->mkpath;
$git->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
step="$1"
[[ "$step" == -C ]] && step="$3"
printf '%s\n' "$step" >> "$TEST_STEPS"
[[ "$step" == "${TEST_SIGNAL_STEP:-}" ]] && kill -s "$TEST_SIGNAL" $$
if [[ "$step" == "${TEST_HANGING_STEP:-}" ]]; then
  printf '%s\n' "$$" > "$TEST_HANGING"
  exec sleep 60
fi
if [[ "$step" == "${TEST_STOP_AFTER_STEP:-}" ]]; then
  # The step is made, and the supervisor is told to end as it is over.
  "$TEST_REAL_GIT" "$@"
  status=$?
  kill -TERM "$TEST_SUPERVISOR"
  exit "$status"
fi
exec "$TEST_REAL_GIT" "$@"
SCRIPT
$git->chmod(0755);
my $executor = $tools->child('executor');
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
printf 'ran\n' >> "$TEST_STEPS"
[[ -n "${TEST_SIGNAL_EXECUTOR:-}" ]] && kill -s "$TEST_SIGNAL_EXECUTOR" $$
exit 0
SCRIPT
$executor->chmod(0755);
# A run whose executor is ended asks docker for its containers. There are none.
my $docker = $tools->child('bin/docker');
$docker->spew_utf8("#!/bin/sh\nexit 0\n");
$docker->chmod(0755);

local $ENV{TEST_REAL_GIT} = which('git');
local $ENV{PATH} = $git->parent.':'.$ENV{PATH};
my $json = JSON::MaybeXS->new;

sub run_with {
  my ( %environment ) = @_;
  my $root = tempdir;
  my $steps = $root->child('steps');
  local @ENV{ keys %environment } = values %environment;
  local $ENV{TEST_STEPS} = "$steps";
  my $report = SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $root),
    timeout => 30, runner_script => $executor)->run($event);
  my $published = $json->decode($root->child('public/runs/1.json')->slurp_utf8);
  return ( $report, [ $steps->lines_utf8({ chomp => 1 }) ], $published );
}

subtest 'a run no signal ends' => sub {
  my ( $report, $steps ) = run_with();
  is $steps, [qw( init remote fetch checkout ran )], 'takes every step, then the executor';
  is [ $report->@{qw( state exit_code )} ], [ 'success', 0 ], 'and is a success';
  ok !exists $report->{signal}, 'without a signal in its report';
};

my @steps = qw( init remote fetch checkout );
for my $index (0 .. $#steps) {
  subtest 'a signal that ends git '.$steps[$index] => sub {
    my ( $report, $steps, $published ) =
      run_with(TEST_SIGNAL_STEP => $steps[$index], TEST_SIGNAL => 'KILL');
    is $steps, [ @steps[0 .. $index] ], 'ends the checkout: no later step and no executor';
    is $report->{state}, 'signalled', 'the run is signalled';
    is $report->{signal}, 9, 'by signal 9';
    is $report->{exit_code}, 137, 'with the exit code a shell gives it, 128 + 9';
    is [ $published->@{qw( state signal exit_code )} ], [ 'signalled', 9, 137 ],
      'the published report says the same';
  };
}

subtest 'a signal other than KILL' => sub {
  my ( $report, $steps ) = run_with(TEST_SIGNAL_STEP => 'fetch', TEST_SIGNAL => 'TERM');
  is $steps, [qw( init remote fetch )], 'ends the checkout as well';
  is [ $report->@{qw( state signal exit_code )} ], [ 'signalled', 15, 143 ],
    'and is reported with 128 + 15';
};

subtest 'a signal that ends the executor' => sub {
  my ( $report, $steps, $published ) = run_with(TEST_SIGNAL_EXECUTOR => 'KILL');
  is $steps, [qw( init remote fetch checkout ran )], 'after a complete checkout';
  is [ $report->@{qw( state signal exit_code )} ], [ 'signalled', 9, 137 ],
    'is no exit code 0 either';
  is [ $published->@{qw( state signal exit_code )} ], [ 'signalled', 9, 137 ],
    'in the published report as in the returned one';
};

subtest 'a command whose end cannot be read' => sub {
  # With SIGCHLD ignored the kernel keeps no status: waitpid finds no child.
  local $SIG{CHLD} = 'IGNORE';
  my $root = tempdir;
  my $steps = $root->child('steps');
  local $ENV{TEST_STEPS} = "$steps";
  my $runner = SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $root),
    timeout => 30, runner_script => $executor);
  like dies { $runner->run($event) }, qr/SimpiCI::Runner->_execute lost git: /,
    'is an error of the runner, not a result';
  is [ $steps->lines_utf8({ chomp => 1 }) ], ['init'], 'and nothing is started after it';
};

subtest 'a supervisor that is told to end during the checkout' => sub {
  my $root = tempdir;
  my $steps = $root->child('steps');
  my $hanging = $root->child('hanging');
  local $ENV{TEST_STEPS} = "$steps";
  local $ENV{TEST_HANGING} = "$hanging";
  local $ENV{TEST_HANGING_STEP} = 'fetch';
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDERR, '>', $root->child('output')->stringify or POSIX::_exit(97);
    eval { SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $root->child('state')),
      timeout => 30, runner_script => $executor)->run($event) };
    POSIX::_exit(0);
  }
  my $deadline = time + 30;
  sleep 0.05 until -s $hanging || time > $deadline;
  ok -s $hanging, 'git fetch runs';
  kill 'TERM', $pid;
  my $ended;
  sleep 0.05 until ( $ended = waitpid($pid, WNOHANG) ) != 0 || time > $deadline;
  my $status = $?;
  kill 'KILL', $pid unless $ended;
  is [ $ended, $status & 127 ], [ $pid, 15 ], 'ends by the signal it was sent';
  my $fetch = $hanging->slurp_utf8;
  chomp $fetch;
  ok !kill(0, $fetch), 'after it ended git fetch';
  is [ $steps->lines_utf8({ chomp => 1 }) ], [qw( init remote fetch )],
    'no later step and no executor was started';
  my $published = $json->decode($root->child('state/public/runs/1.json')->slurp_utf8);
  is [ $published->@{qw( state signal exit_code )} ], [ 'signalled', 15, 143 ],
    'the run is published as signalled, with the signal of the supervisor';
  ok !$root->child('state/containers')->exists, 'and no container was looked for';
  like $root->child('output')->slurp_utf8, qr/\ASimpiCI::Runner run 1 stopped by signal TERM\n\z/,
    'the supervisor says why the run ended';
};

subtest 'a supervisor that is told to end as a step of the checkout is over' => sub {
  # The signal arrives while no command runs, or as one ends by itself.
  for my $attempt (1 .. 5) {
    my $root = tempdir;
    my $steps = $root->child('steps');
    local $ENV{TEST_STEPS} = "$steps";
    local $ENV{TEST_STOP_AFTER_STEP} = 'fetch';
    my $pid = fork;
    croak 'fork failed' unless defined $pid;
    unless ($pid) {
      open STDERR, '>', $root->child('output')->stringify or POSIX::_exit(97);
      $ENV{TEST_SUPERVISOR} = $$;
      eval { SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $root->child('state')),
        timeout => 30, runner_script => $executor)->run($event) };
      POSIX::_exit(0);
    }
    my $deadline = time + 30;
    my $ended;
    sleep 0.05 until ( $ended = waitpid($pid, WNOHANG) ) != 0 || time > $deadline;
    my $status = $?;
    kill 'KILL', $pid unless $ended;
    is [ $ended, $status & 127 ], [ $pid, 15 ], 'ends by the signal it was sent';
    is [ $steps->lines_utf8({ chomp => 1 }) ], [qw( init remote fetch )],
      'no later step and no executor was started';
    my $published = $json->decode($root->child('state/public/runs/1.json')->slurp_utf8);
    is [ $published->@{qw( state signal exit_code )} ], [ 'signalled', 15, 143 ],
      'the run is published as signalled';
  }
};

done_testing;
