use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use File::Which qw( which );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# A signal that ends the worker does not only arrive while a command of the
# run is being waited for. Whenever it arrives between the claim and the end
# of the run, no further command of the run is started; and a signal the
# caller ignores ends nothing.

{
  package ScriptedWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has answer => (is => 'rw', required => 1);
  has requests => (is => 'ro', default => sub { [] });
  has before_run => (is => 'rw');
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->answer->($request);
  }
  around _run_claim => sub {
    my ( $orig, $self, @arguments ) = @_;
    $self->before_run->() if $self->before_run;
    return $self->$orig(@arguments);
  };
}

umask 0077;
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'stop-point-secret-value';

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

# git as the runner finds it: the real one, with every step written down.
# The step named in TEST_STOP_AFTER_STEP tells the worker to end as it is
# over. docker knows no container, or cannot be asked.
my $tools = tempdir;
$tools->child('bin')->mkpath;
my $git = $tools->child('bin/git');
$git->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
step="$1"
[[ "$step" == -C ]] && step="$3"
printf '%s\n' "$step" >> "$TEST_STEPS"
if [[ "$step" == "${TEST_STOP_AFTER_STEP:-}" ]]; then
  "$TEST_REAL_GIT" "$@"
  status=$?
  kill -TERM "$TEST_SUPERVISOR"
  exit "$status"
fi
exec "$TEST_REAL_GIT" "$@"
SCRIPT
$git->chmod(0755);
my $docker = $tools->child('bin/docker');
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
[[ -z "${TEST_DOCKER_DOWN:-}" ]] || exit 1
exit 0
SCRIPT
$docker->chmod(0755);
my $executor = $tools->child('executor');
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
cat "$SIMPICI_SECRETS_DIR/publish.env"
printf 'ran\n' >> "$TEST_STEPS"
[[ -z "${TEST_SIGNAL_SUPERVISOR:-}" ]] || { kill -s "$TEST_SIGNAL_SUPERVISOR" "$TEST_SUPERVISOR"; sleep 0.5; }
printf 'the executor is over\n'
SCRIPT
$executor->chmod(0755);

local $ENV{TEST_REAL_GIT} = which('git');
local $ENV{PATH} = $tools->child('bin').':'.$ENV{PATH};
local $ENV{TEST_SUPERVISOR} = $$;

sub claim {
  return {
    run => 7, token => 'token-of-run-7', timeout => 30,
    secrets => { publish => { PUBLISH_TOKEN => $value }, deploy => {} },
    event => { source => 'git-poll', event => 'push', repository => 'fixture',
      clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit }
  };
}

# One cycle of a worker whose caller handles TERM, as a test has to: the
# signal would end it otherwise.
sub cycle {
  my ( %arg ) = @_;
  my $root = tempdir;
  my $steps = $root->child('steps');
  $steps->touch;
  local $ENV{TEST_STEPS} = "$steps";
  local @ENV{ keys $arg{environment}->%* } = values $arg{environment}->%* if $arg{environment};
  my $store = SimpiCI::Store->new(root => $root->child('worker'));
  my $worker = ScriptedWorker->new(host => 'unused', store => $store,
    answer => sub { $_[0]->{operation} eq 'claim' ? claim() : { state => 'recorded' } },
    runner => SimpiCI::Runner->new(store => $store, runner_script => $executor),
    $arg{before_run} ? ( before_run => $arg{before_run} ) : ());
  $arg{prepare}->($store->root) if $arg{prepare};
  my ( @passed_on, $response, $error );
  my $warnings = warnings {
    local $SIG{TERM} = sub { push @passed_on, $_[0] };
    local $SIG{HUP} = $arg{hup} if $arg{hup};
    $response = eval { $worker->once };
    $error = $@;
  };
  my $completion = $store->root->child('completion.json');
  return {
    root => $store->root, worker => $worker, response => $response, error => $error,
    warned => join('', @$warnings), passed_on => \@passed_on,
    steps => [ $steps->lines_utf8({ chomp => 1 }) ],
    completion => $completion->is_file ? $json->decode($completion->slurp_utf8) : undef,
    keep => $root
  };
}

sub ended_by_term {
  my ( $cycle, $steps ) = @_;
  is $cycle->{error}, '', 'the cycle does not fail';
  is $cycle->{steps}, $steps, 'no further command of the run is started: '.join(' ', @$steps);
  is $cycle->{completion}->{result}, { state => 'signalled', exit_code => 143 },
    'the run is saved as signalled';
  like $cycle->{completion}->{log}, qr/^SimpiCI::Runner run 7 stopped by signal TERM\n\z/m,
    'its log ends with the reason';
  ok scalar $cycle->{passed_on}->@*, 'the signal is passed on to the caller';
  is $cycle->{response}, undef, 'and nothing is delivered on the way out';
  is [ map { $_->{operation} } $cycle->{worker}->requests->@* ], ['claim'],
    'the dispatcher was asked for the claim and nothing else';
  ok !$cycle->{root}->child($_)->exists, $_.' is removed'
    for qw( secrets/7 public/runs/7.log work/7 tmp/7 containers/7 );
  return;
}

subtest 'a worker that is told to end before the run begins' => sub {
  ended_by_term(cycle(before_run => sub { kill 'TERM', $$ }), []);
};

subtest 'a worker that is told to end as a step of the checkout is over' => sub {
  # The signal arrives while no command runs, or as one ends by itself.
  ended_by_term(cycle(environment => { TEST_STOP_AFTER_STEP => $_ }),
    $_ eq 'init' ? ['init'] : [qw( init remote fetch )]) for qw( init fetch fetch fetch );
};

subtest 'a worker that is told to end as the checkout is complete' => sub {
  ended_by_term(cycle(environment => { TEST_STOP_AFTER_STEP => 'checkout' }),
    [qw( init remote fetch checkout )]);
};

subtest 'a signal the caller of the worker ignores' => sub {
  my $cycle = cycle(hup => 'IGNORE', environment => { TEST_SIGNAL_SUPERVISOR => 'HUP' });
  is $cycle->{error}, '', 'does not fail the cycle';
  is $cycle->{steps}, [qw( init remote fetch checkout ran )], 'and ends no run';
  is $cycle->{response}, { state => 'recorded' }, 'the run is delivered';
  my $finish = $cycle->{worker}->requests->[-1];
  is $finish->{result}, { state => 'success', exit_code => 0 }, 'as the success it was';
  like $finish->{log}, qr/^the executor is over$/m, 'with all of its log';
};

subtest 'containers of a run that was cut off, and a docker that cannot be asked' => sub {
  my $cycle = cycle(environment => { TEST_DOCKER_DOWN => 1 }, prepare => sub {
    my ( $root ) = @_;
    my %left = ( 'containers/4' => 'simpici.run=unused.4', 'secrets/4/publish.env' =>
      'PUBLISH_TOKEN='.$value, 'public/runs/4.log' => 'PUBLISH_TOKEN='.$value,
      'tmp/4/simpici.aB3dE6gH/log.publish.job' => 'PUBLISH_TOKEN='.$value );
    for my $name (keys %left) {
      $root->child($name)->parent->mkpath;
      $root->child($name)->spew_utf8($left{$name}."\n");
    }
  });
  like $cycle->{error}, qr/\ASimpiCI::Worker cannot remove orphaned containers: SimpiCI::Runner cannot list containers: docker ps ended with 1 at /,
    'stop the worker';
  is $cycle->{worker}->requests, [], 'before it asks the dispatcher for anything';
  ok $cycle->{root}->child('containers/4')->is_file, 'containers/4 stays for the next attempt';
  ok !$cycle->{root}->child($_)->exists, 'but '.$_.' does not wait for docker'
    for qw( secrets/4 public/runs/4.log tmp/4 );
  like $cycle->{warned}, qr/^SimpiCI::Worker removed orphaned secret files: secrets\/4$/m,
    'and the worker says what it removed';
};

done_testing;
