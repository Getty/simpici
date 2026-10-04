use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use File::Which qw( which );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
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

done_testing;
