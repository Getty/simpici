use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;

# The executor runs in a process group of its own and starts its containers
# through a daemon: neither ends because the supervisor does. Whatever ends
# a run before the executor is over ends the group and removes the
# containers of that run, found by a label no other store has.

{
  package TestRunner;
  use Moo;
  extends 'SimpiCI::Runner';
  sub termination_grace { 3 }
  sub docker_timeout { 2 }
}

umask 0077;

# A supervisor this test started is not left running by a subtest that gave up.
my @supervisors;
END {
  local $?;
  kill 'KILL', grep { waitpid($_, WNOHANG) == 0 } @supervisors;
}
my $json = JSON::MaybeXS->new;

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

# docker as the runner finds it. It knows the containers of TEST_CONTAINERS,
# one per line as "ID PID LABEL...", lists those with the label it is asked
# for and removes the ones it is given. Every call is written down.
my $tools = tempdir;
my $docker = $tools->child('bin/docker');
$docker->parent->mkpath;
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
command="$1"; shift
case "$command" in
  ps)
    [[ -z "${TEST_DOCKER_HANGS:-}" ]] || exec sleep 60
    [[ -z "${TEST_DOCKER_DOWN:-}" ]] || exit 1
    [[ -z "${TEST_DOCKER_ANSWER+set}" ]] || { printf '%s\n' "$TEST_DOCKER_ANSWER"; exit 0; }
    filter=''
    while (( $# )); do
      if [[ "$1" == --filter ]]; then shift; filter="${1#label=}"; fi
      shift
    done
    # A listing without a label would name the containers of everybody.
    [[ -n "$filter" ]] || exit 2
    [[ -f "$TEST_CONTAINERS" ]] || exit 0
    # A daemon that removes on its own lists a container a moment longer.
    if [[ -s "$TEST_STATE/lingering" ]]; then
      left="$(cat "$TEST_STATE/lingering")"
      if (( left > 0 )); then
        printf '%s\n' "$(( left - 1 ))" > "$TEST_STATE/lingering"
      else
        while read -r id; do sed -i "/^$id /d" "$TEST_CONTAINERS"; done < "$TEST_STATE/going"
        rm "$TEST_STATE/lingering"
      fi
    fi
    while read -r id pid labels; do
      [[ " $labels " != *" $filter "* ]] || printf '%s\n' "$id"
    done < "$TEST_CONTAINERS"
    ;;
  kill)
    # A container that was started with --rm is gone once it is killed.
    [[ -z "${TEST_DOCKER_STUCK:-}" ]] || exit 1
    [[ -z "${TEST_DOCKER_KILLS:-}" ]] || for id in "$@"; do sed -i "/^$id /d" "$TEST_CONTAINERS"; done
    ;;
  rm)
    [[ "$1" != -f ]] || shift
    [[ -z "${TEST_DOCKER_STUCK:-}" ]] || exit 1
    if [[ -n "${TEST_DOCKER_LINGERS:-}" ]]; then
      printf '%s\n' "$@" > "$TEST_STATE/going"
      printf '%s\n' "$TEST_DOCKER_LINGERS" > "$TEST_STATE/lingering"
      echo 'removal already in progress' >&2
      exit 1
    fi
    # What is no longer there is an error to docker rm, and none to the runner.
    status=0
    for id in "$@"; do
      grep -q "^$id " "$TEST_CONTAINERS" || status=1
      sed -i "/^$id /d" "$TEST_CONTAINERS"
    done
    exit "$status"
    ;;
esac
SCRIPT
$docker->chmod(0755);

# In place of the executor. It starts the containers named in TEST_START the
# way docker run would, with the labels of its run, and then does what
# TEST_BEHAVIOUR says.
my $executor = $tools->child('executor');
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
printf '%s\n' "${SIMPICI_INSTANCE:-}" > "$TEST_STATE/instance"
marker="$TEST_ROOT/containers/$CICD_RUN_NUMBER"
[[ ! -f "$marker" ]] || cp "$marker" "$TEST_STATE/marker"
for id in ${TEST_START:-}; do
  printf '%s - simpici.instance=%s simpici.run=%s.%s\n' "$id" "$SIMPICI_INSTANCE" \
    "$SIMPICI_INSTANCE" "$CICD_RUN_NUMBER" >> "$TEST_CONTAINERS"
done
echo 'the executor runs'
printf '%s\n' "$$" > "$TEST_STATE/pid.tmp"
mv "$TEST_STATE/pid.tmp" "$TEST_STATE/pid"
case "${TEST_BEHAVIOUR:-end}" in
  end)     exit "${TEST_EXIT:-0}" ;;
  hang)    sleep 60 & wait ;;
  cleanup) trap 'sleep 1.5; : > "$TEST_STATE/cleaned"; exit 143' TERM; sleep 60 & wait ;;
  ignore)  trap '' TERM; sleep 60 ;;
  kill)    kill -KILL $$ ;;
  leave)   sleep 60 & exit "${TEST_EXIT:-0}" ;;
  hup)     kill -HUP "$TEST_SUPERVISOR"; sleep 0.5; exit 0 ;;
  unreportable)
    # The report of the run becomes a directory: it cannot be replaced.
    report="$TEST_ROOT/public/runs/$CICD_RUN_NUMBER.json"
    rm "$report"; mkdir "$report"
    : > "$TEST_STATE/unreportable"
    sleep 60 & wait ;;
esac
SCRIPT
$executor->chmod(0755);

local $ENV{PATH} = $docker->parent.':'.$ENV{PATH};

my @foreign = (
  ('f' x 64).' - simpici.instance='.('9' x 32).' simpici.run='.('9' x 32).'.1',
  ('e' x 64).' - unrelated=label',
  ('d' x 64).' -'
);
my @own = ( 'a' x 64, 'b' x 64 );

# A store with a run to make, and what the fake programs keep about it.
sub scene {
  my ( %environment ) = @_;
  my $root = tempdir;
  my $state = tempdir;
  my $store = SimpiCI::Store->new(root => $root);
  $state->child('containers')->spew_utf8(map { $_."\n" } @foreign);
  $state->child('docker.log')->touch;
  my %scene = (
    root => $root, state => $state, store => $store,
    runner => TestRunner->new(store => $store, timeout => $environment{TEST_TIMEOUT} // 30,
      runner_script => $executor),
    environment => {
      TEST_ROOT => "$root", TEST_STATE => "$state",
      TEST_CONTAINERS => $state->child('containers')->stringify,
      TEST_DOCKER_LOG => $state->child('docker.log')->stringify,
      %environment
    }
  );
  return \%scene;
}

sub containers { [ $_[0]->{state}->child('containers')->lines_utf8({ chomp => 1 }) ] }

sub docker_calls { [ $_[0]->{state}->child('docker.log')->lines_utf8({ chomp => 1 }) ] }

sub published { $json->decode($_[0]->{root}->child('public/runs/1.json')->slurp_utf8) }

sub execute {
  my ( $scene ) = @_;
  local @ENV{ keys $scene->{environment}->%* } = values $scene->{environment}->%*;
  my ( $report, $error );
  my $started = time;
  my $warnings = warnings { $report = eval { $scene->{runner}->run($event) }; $error = $@ };
  return ( $report, join('', @$warnings), time - $started, $error );
}

# Nothing of the process group of the executor is left, the executor included.
sub group_is_gone {
  my ( $scene, $within ) = @_;
  my $pid = $scene->{state}->child('pid')->slurp_utf8;
  chomp $pid;
  my $deadline = time + $within;
  sleep 0.05 while kill(0, -$pid) && time < $deadline;
  return !kill(0, -$pid);
}

sub wait_for {
  my ( $file, $within ) = @_;
  my $deadline = time + $within;
  sleep 0.05 until $file->exists || time > $deadline;
  return $file->exists;
}

subtest 'an executor that ends by itself' => sub {
  my $scene = scene();
  my ( $report, $warned ) = execute($scene);
  is $report->{state}, 'success', 'is a success';
  my $instance = $scene->{store}->instance;
  is $scene->{state}->child('instance')->slurp_utf8, $instance."\n",
    'it was told the instance of the store as SIMPICI_INSTANCE';
  is $scene->{state}->child('marker')->slurp_utf8, 'simpici.run='.$instance.".1\n",
    'while it ran, containers/1 named the label of its containers';
  ok !$scene->{root}->child('containers/1')->exists, 'the file is gone once it is over';
  is docker_calls($scene), [], 'docker is not asked for anything: every job of it is over';
  is $warned, '', 'and nothing is said';
  ok group_is_gone($scene, 5), 'nothing of its process group is left';
};

subtest 'an executor that fails' => sub {
  # It may have given up with jobs still running: only an exit of 0 says
  # that every container it started is over.
  my $scene = scene(TEST_EXIT => 3, TEST_START => "@own");
  my ( $report, $warned ) = execute($scene);
  is [ $report->@{qw( state exit_code )} ], [ 'failed', 3 ], 'is a failed run';
  is containers($scene), \@foreign, 'the containers it left are removed, and only those';
  is $warned, "SimpiCI::Runner removed containers of run 1: 2\n", 'and the runner says so';
  ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
  $scene = scene(TEST_EXIT => 3);
  ( $report, $warned ) = execute($scene);
  is docker_calls($scene), [ 'ps -aq --no-trunc --filter label=simpici.run='
    .$scene->{store}->instance.'.1' ], 'one that left none costs one question';
  is $warned, '', 'and nothing is said';
};

subtest 'a process the executor leaves behind' => sub {
  for my $exit (0, 3) {
    my $scene = scene(TEST_BEHAVIOUR => 'leave', TEST_EXIT => $exit);
    my ( $report ) = execute($scene);
    is $report->{exit_code}, $exit, 'the run has the result of the executor: exit '.$exit;
    ok group_is_gone($scene, 5), 'and what the executor left in its process group is ended';
  }
};

subtest 'containers that are listed a moment longer' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'kill', TEST_START => "@own", TEST_DOCKER_LINGERS => 2);
  my ( $report, $warned, $took, $error ) = execute($scene);
  is $error, '', 'do not fail the run';
  is $warned, "SimpiCI::Runner removed containers of run 1: 2\n",
    'the runner waits for a daemon that is still removing them';
  is containers($scene), \@foreign, 'they are gone';
  ok !$scene->{root}->child('containers/1')->exists, 'and so is containers/1';
};

subtest 'an executor that is not over in time' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'hang', TEST_START => "@own", TEST_TIMEOUT => 1);
  my ( $report, $warned, $took ) = execute($scene);
  is [ $report->@{qw( state exit_code )} ], [ 'timed_out', 124 ], 'is timed out';
  ok $took < 4, 'the run ends when the executor does, not when the grace is over';
  my $label = 'simpici.run='.$scene->{store}->instance.'.1';
  is docker_calls($scene), [
    'ps -aq --no-trunc --filter label='.$label, 'kill '.join(' ', @own),
    'rm -f '.join(' ', @own), 'ps -aq --no-trunc --filter label='.$label
  ], 'the containers with the label of the run are listed, killed, removed and looked for again';
  is containers($scene), \@foreign, 'the containers of others are still there';
  is $warned, "SimpiCI::Runner removed containers of run 1: 2\n", 'the runner says what it removed';
  ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
  ok group_is_gone($scene, 5), 'nothing of the process group is left';
};

subtest 'an executor that needs time to end' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'cleanup', TEST_TIMEOUT => 1);
  my ( $report, $warned, $took ) = execute($scene);
  is $report->{state}, 'timed_out', 'is timed out';
  ok $scene->{state}->child('cleaned')->exists,
    'it gets more than a second to end what it started';
  ok $took < 1 + 3, 'and the run ends when it did';
  ok group_is_gone($scene, 5), 'nothing of the process group is left';
};

subtest 'an executor that does not end when told to' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'ignore', TEST_START => $own[0], TEST_TIMEOUT => 1);
  my ( $report, $warned, $took ) = execute($scene);
  is $report->{state}, 'timed_out', 'is timed out';
  ok $took >= 1 + 3 && $took < 1 + 3 + 3, 'it is killed once the grace is over';
  ok group_is_gone($scene, 5), 'with its process group';
  is containers($scene), \@foreign, 'and its container is removed';
};

subtest 'an executor a signal ended' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'kill', TEST_START => "@own");
  my ( $report, $warned ) = execute($scene);
  is [ $report->@{qw( state signal exit_code )} ], [ 'signalled', 9, 137 ], 'is signalled';
  is containers($scene), \@foreign, 'the containers it could not remove are removed for it';
  is $warned, "SimpiCI::Runner removed containers of run 1: 2\n", 'and the runner says so';
  ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
};

subtest 'containers that are gone once they are killed' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'kill', TEST_START => "@own", TEST_DOCKER_KILLS => 1);
  my ( $report, $warned ) = execute($scene);
  is containers($scene), \@foreign, 'are removed';
  is $warned, "SimpiCI::Runner removed containers of run 1: 2\n",
    'and counted, although docker rm found none of them';
  ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
};

subtest 'containers that are not removed' => sub {
  my %cause = (
    'a docker that removes nothing' => [ { TEST_DOCKER_STUCK => 1 },
      qr/\ASimpiCI::Runner cannot remove the containers of run 1: SimpiCI::Runner containers left with the label simpici\.run=[0-9a-f]{32}\.1: 2\n\z/ ],
    'a docker that cannot be asked' => [ { TEST_DOCKER_DOWN => 1 },
      qr/\ASimpiCI::Runner cannot remove the containers of run 1: SimpiCI::Runner cannot list containers: docker ps ended with 1\n\z/ ],
    'a docker that does not answer' => [ { TEST_DOCKER_HANGS => 1 },
      qr/\ASimpiCI::Runner cannot remove the containers of run 1: SimpiCI::Runner cannot list containers: docker ps not over within 2 s\n\z/ ],
    'an answer that is no list of containers' => [ { TEST_DOCKER_ANSWER => 'CONTAINER ID   IMAGE' },
      qr/\ASimpiCI::Runner cannot remove the containers of run 1: SimpiCI::Runner cannot list containers: unexpected answer of docker ps\n\z/ ],
  );
  for my $name (sort keys %cause) {
    my ( $environment, $expected ) = $cause{$name}->@*;
    my $scene = scene(TEST_BEHAVIOUR => 'kill', TEST_START => "@own", %$environment);
    my ( $report, $warned, $took, $error ) = execute($scene);
    is $error, '', $name.' does not fail the run';
    is $report->{state}, 'signalled', $name.': the run has its result';
    like $warned, $expected, $name.' is reported';
    ok $scene->{root}->child('containers/1')->is_file,
      $name.': containers/1 stays, for whoever looks for them next';
    is [ grep { /\A(?:rm|kill) / && /f{64}|e{64}|d{64}/ } docker_calls($scene)->@* ], [],
      $name.': no container of another is named to docker kill or docker rm';
  }
};

subtest 'a supervisor that ignores a signal' => sub {
  # As under nohup: what the caller chose to ignore ends no run of its.
  my $scene = scene(TEST_BEHAVIOUR => 'hup');
  $scene->{before} = sub { $SIG{HUP} = 'IGNORE' };
  my $pid = supervise($scene);
  waitpid($pid, 0);
  is [ $? >> 8, $? & 127 ], [ 0, 0 ], 'goes on';
  is published($scene)->{state}, 'success', 'and its run is made to the end';
};

subtest 'a supervisor that is the first process of a container' => sub {
  # What it starts and does not wait for stays with it as a zombie: nothing
  # else is there to take it over.
  my @unshare = qw( unshare -U -r -p -f -m --mount-proc );
  my $usable = qx{@unshare true 2>&1; printf %s \$?};
  skip_all 'no PID namespace to be the first process of' unless $usable eq '0';
  my $root = tempdir;
  # Every process that has ended and that nobody waited for, by its name.
  # git may leave one of its own, a maintenance it detached: that is not a
  # process of the runner.
  my $code = 'use Path::Tiny qw( path ); use Time::HiRes qw( sleep );'
    .'use SimpiCI::Event; use SimpiCI::Store; use SimpiCI::Runner;'
    .'my ( $root, $executor, $fixture, $commit ) = @ARGV;'
    .'SimpiCI::Runner->new(store => SimpiCI::Store->new(root => path($root)), timeout => 30,'
    .' runner_script => path($executor))->run(SimpiCI::Event->new(source => "manual",'
    .' event => "push", repository => "fixture", clone_url => $fixture,'
    .' ref => "refs/heads/main", commit => $commit));'
    .'sleep 0.5; print "supervisor $$\n";'
    .'for my $stat (glob "/proc/[0-9]*/stat") {'
    .' my ( $name, $state ) = path($stat)->slurp =~ /\A\d+ \((.*)\) (\S)/ or next;'
    .' print "unreaped $name\n" if $state eq "Z" }';
  local $ENV{TEST_STATE} = "$root";
  local $ENV{TEST_ROOT} = $root->child('state')->stringify;
  local $ENV{TEST_CONTAINERS} = $root->child('containers')->stringify;
  my @command = ( @unshare, $^X, '-I'.path('lib')->absolute, '-e', $code,
    $root->child('state')->stringify, "$executor", "$fixture", $commit );
  open(my $output, '-|', @command) or croak 'cannot run unshare';
  my @said = <$output>;
  close $output;
  is $said[0], "supervisor 1\n", 'makes its run';
  is [ grep { !/\Aunreaped git\n\z/ } @said[1 .. $#said] ], [],
    'and leaves no process of its own behind unreaped';
};

subtest 'removing by hand' => sub {
  my $scene = scene();
  my $instance = $scene->{store}->instance;
  my @mine = (
    ('a' x 64).' - simpici.instance='.$instance.' simpici.run='.$instance.'.4',
    ('b' x 64).' - simpici.instance='.$instance.' simpici.run='.$instance.'.5',
    ('c' x 64).' - simpici.instance='.$instance.' simpici.run='.$instance.'.5'
  );
  $scene->{state}->child('containers')->append_utf8(map { $_."\n" } @mine);
  local @ENV{ keys $scene->{environment}->%* } = values $scene->{environment}->%*;
  my $runner = $scene->{runner};
  is $runner->container_label(5), 'simpici.run='.$instance.'.5', 'a run has a label';
  is $runner->container_label, 'simpici.instance='.$instance, 'and so has the instance';
  like dies { $runner->container_label('5 --all') }, qr/SimpiCI::Runner invalid run/,
    'what is not a run number is no part of one';
  is $runner->remove_containers(5), 2, 'remove_containers returns how many of the run it removed';
  is containers($scene), [ @foreign, $mine[0] ], 'the containers of other runs stay';
  is $runner->remove_containers(5), 0, 'none when there is none';
  is $runner->remove_containers, 1, 'without a run, every container of the instance is removed';
  is containers($scene), \@foreign, 'and none of another instance or without a label';
  is [ grep { !/\A(?:ps -aq --no-trunc --filter label=simpici\.(?:run|instance)=\Q$instance\E(?:\.5)?|(?:kill|rm -f)(?: [abc]{64}){1,2})\z/ }
    docker_calls($scene)->@* ], [], 'docker was asked for nothing else';
  {
    local $ENV{PATH} = $tools->child('empty')->stringify;
    is $runner->remove_containers, 0, 'without docker there is nothing to remove';
  }
};

# The run is made by a process of its own: what ends it is the signal.
sub supervise {
  my ( $scene ) = @_;
  local @ENV{ keys $scene->{environment}->%* } = values $scene->{environment}->%*;
  my $output = $scene->{state}->child('output');
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDOUT, '>', $output->stringify or POSIX::_exit(97);
    open STDERR, '>&', \*STDOUT or POSIX::_exit(97);
    $ENV{TEST_SUPERVISOR} = $$;
    $scene->{before}->() if $scene->{before};
    eval { $scene->{runner}->run($event) };
    POSIX::_exit(0);
  }
  push @supervisors, $pid;
  ok wait_for($scene->{state}->child('pid'), 30), 'the executor runs';
  return $pid;
}

my %number = ( TERM => 15, INT => 2, HUP => 1 );
for my $signal (sort keys %number) {
  subtest 'a supervisor that is told to end by '.$signal => sub {
    my $scene = scene(TEST_BEHAVIOUR => 'hang', TEST_START => "@own");
    my $pid = supervise($scene);
    kill $signal, $pid;
    waitpid($pid, 0);
    is $? & 127, $number{$signal}, 'ends by that signal';
    ok group_is_gone($scene, 5), 'after the process group of the executor';
    is containers($scene), \@foreign, 'and after the containers of the run, and only those';
    ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
    is [ published($scene)->@{qw( state signal exit_code )} ],
      [ 'signalled', $number{$signal}, 128 + $number{$signal} ],
      'the run is published as signalled, with the signal of the supervisor';
    like $scene->{root}->child('public/runs/1.log')->slurp_utf8,
      qr/^the executor runs\n(?s:.*)^SimpiCI::Runner run 1 stopped by signal \Q$signal\E\n\z/m,
      'and its log ends with the reason';
    like $scene->{state}->child('output')->slurp_utf8,
      qr/^SimpiCI::Runner run 1 stopped by signal \Q$signal\E$/m, 'which the supervisor also warns';
  };
}

subtest 'a supervisor that is told to end and cannot report the run' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'unreportable', TEST_START => "@own");
  my $pid = supervise($scene);
  # Not before the executor has put the directory in the place of the
  # report: its pid is written first.
  ok wait_for($scene->{state}->child('unreportable'), 30), 'the report cannot be written any more';
  kill 'TERM', $pid;
  waitpid($pid, 0);
  is $? & 127, 15, 'ends by the signal all the same';
  ok group_is_gone($scene, 5), 'after the process group of the executor';
  is containers($scene), \@foreign, 'and after the containers of the run';
  like $scene->{state}->child('output')->slurp_utf8,
    qr/^SimpiCI::Runner cannot report run 1: SimpiCI::Store->write_json cannot publish \S+\/public\/runs\/1\.json: [^\n]+$/m,
    'and says what it could not write';
};

subtest 'passing a signal on' => sub {
  my $runner = scene()->{runner};
  my @handled;
  {
    local $SIG{TERM} = sub { push @handled, $_[0] };
    $runner->end_by('TERM');
  }
  is \@handled, ['TERM'], 'end_by sends the signal to a caller that handles it, and returns';
  like dies { $runner->end_by('KILL') }, qr/SimpiCI::Runner invalid signal/,
    'a signal that ends no run in an orderly way is refused';
  like dies { $runner->end_by(undef) }, qr/SimpiCI::Runner invalid signal/, 'and so is none';

  # The first process of a PID namespace is spared a signal it does not
  # handle, as simpicid is when it is the first process of a container.
  SKIP: {
    my $unshare = qx{unshare -U -r -p -f true 2>&1; printf %s \$?};
    skip 'no PID namespace to be the first process of', 2 unless $unshare eq '0';
    my $root = tempdir;
    my $code = 'use Path::Tiny qw( path ); use SimpiCI::Store; use SimpiCI::Runner;'
      .'my $runner = SimpiCI::Runner->new(store => SimpiCI::Store->new(root => path($ARGV[0])),'
      .' runner_script => path("/bin/true"));'
      .'print "pid $$\n"; $runner->end_by("TERM"); print "still here\n";';
    my @command = ( 'unshare', '-U', '-r', '-p', '-f', $^X, '-I'.path('lib')->absolute,
      '-e', $code, "$root" );
    open(my $output, '-|', @command) or croak 'cannot run unshare';
    my $said = do { local $/; <$output> };
    close $output;
    is $said, "pid 1\n", 'a process that the signal has no effect on does not go on';
    is [ $? >> 8, $? & 127 ], [ 143, 0 ], 'it ends with the exit code of the signal';
  }
};

subtest 'a supervisor that is killed' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'hang', TEST_START => "@own");
  my $pid = supervise($scene);
  kill 'KILL', $pid;
  waitpid($pid, 0);
  is $? & 127, 9, 'ends at once';
  ok group_is_gone($scene, 10), 'the process group of the executor ends without it';
  # The containers go after the processes that could start another one.
  my $deadline = time + 10;
  sleep 0.05 while $scene->{root}->child('containers/1')->exists && time < $deadline;
  ok !$scene->{root}->child('containers/1')->exists, 'containers/1 is gone';
  is containers($scene), \@foreign, 'and the containers of the run are removed, and only those';
  is published($scene)->{state}, 'running', 'the run has no result: nobody was left to publish one';
};

subtest 'a supervisor that is killed while docker cannot be asked' => sub {
  my $scene = scene(TEST_BEHAVIOUR => 'hang', TEST_START => "@own", TEST_DOCKER_DOWN => 1);
  my $pid = supervise($scene);
  kill 'KILL', $pid;
  waitpid($pid, 0);
  ok group_is_gone($scene, 10), 'the process group of the executor ends';
  my $said = qr/^SimpiCI::Runner cannot remove the containers of run 1: SimpiCI::Runner cannot list containers: docker ps ended with 1$/m;
  my $output = $scene->{state}->child('output');
  my $deadline = time + 10;
  sleep 0.05 until $output->slurp_utf8 =~ $said || time > $deadline;
  like $output->slurp_utf8, $said, 'what could not be done is said where the supervisor wrote';
  ok $scene->{root}->child('containers/1')->is_file,
    'containers/1 stays: the containers of the run may still be there';
};

done_testing;
