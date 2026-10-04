use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;

# A worker that ends during a run takes the run with it: the executor, its
# process group and the containers that carry the secrets of the claim. The
# programs are the real ones; only ssh and docker are stood in for.

umask 0077;

# Whatever a subtest gives up on is not left running: the workers this test
# started, and the processes that stand for their containers.
my ( @launched, @container_files, @roots );
END {
  local $?;
  kill 'KILL', grep { waitpid($_, WNOHANG) == 0 } @launched;
  for my $file (grep { $_->is_file } @container_files) {
    kill 'KILL', grep { /\A[1-9][0-9]*\z/ } map { ( split / / )[1] } $file->lines_utf8;
  }
}
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'stopped-secret-value';

my $fixture = tempdir;
for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
    ['config', 'user.email', 'test@example.invalid']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
}
$fixture->child('.cicd')->mkpath;
$fixture->child('.cicd/linux+publish.sh')->spew_utf8("#!/bin/sh\nexit 0\n");
$fixture->child('.cicd/linux+publish.sh')->chmod(0755);
for my $command (['add', '.'], ['commit', '-qm', 'fixture']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
}
my $commit = `git -C $fixture rev-parse HEAD`;
chomp $commit;

my $tools = tempdir;
$tools->child('bin')->mkpath;
my $ssh = $tools->child('bin/ssh');
$ssh->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
printf 'asked\n' >> "$TEST_STATE/ssh.log"
exec "$TEST_PERL" -I"$TEST_LIB" "$TEST_DISPATCH" --config "$TEST_CONFIG" --worker test-vm
SCRIPT
$ssh->chmod(0755);
# docker with containers of its own. A container is a process outside the
# process group of whoever started it, as one of a daemon is: it prints the
# secret it was given and stays until docker rm ends it. TEST_STATE/containers
# has one line per container, "ID PID LABEL...".
my $docker = $tools->child('bin/docker');
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_STATE/docker.log"
containers="$TEST_STATE/containers"
command="$1"; shift
case "$command" in
  run)
    cidfile='' labels='' secret_file=''
    while (( $# )); do
      case "$1" in
        --cidfile)  shift; cidfile="$1" ;;
        --label)    shift; labels+=" $1" ;;
        --env-file) shift; secret_file="$1" ;;
      esac
      shift
    done
    [[ -z "$secret_file" ]] || cat "$secret_file"
    setsid sleep 60 >/dev/null 2>&1 &
    id="$(printf '%064d' "$!")"
    printf '%s\n' "$id" > "$cidfile"
    printf '%s %s%s\n' "$id" "$!" "$labels" >> "$containers"
    : > "$TEST_STATE/running"
    wait "$!" || true
    ;;
  ps)
    [[ -z "${TEST_DOCKER_DOWN:-}" ]] || { echo 'Cannot connect to the Docker daemon' >&2; exit 1; }
    filter=''
    while (( $# )); do
      if [[ "$1" == --filter ]]; then shift; filter="${1#label=}"; fi
      shift
    done
    [[ -n "$filter" ]] || exit 2
    while read -r id pid labels; do
      [[ " $labels " != *" $filter "* ]] || printf '%s\n' "$id"
    done < "$containers"
    ;;
  kill)
    for id in "$@"; do
      pid="$(awk -v id="$id" '$1 == id { print $2 }' "$containers")"
      [[ -z "$pid" || "$pid" == - ]] || kill -KILL "$pid" 2>/dev/null || true
    done
    ;;
  rm)
    [[ "$1" != -f ]] || shift
    for id in "$@"; do
      pid="$(awk -v id="$id" '$1 == id { print $2 }' "$containers")"
      [[ -z "$pid" || "$pid" == - ]] || kill -KILL "$pid" 2>/dev/null || true
      sed -i "/^$id /d" "$containers"
    done
    ;;
esac
SCRIPT
$docker->chmod(0755);

local $ENV{PATH} = $tools->child('bin').':'.$ENV{PATH};
local $ENV{TEST_PERL} = $^X;
local $ENV{TEST_LIB} = path('lib')->absolute->stringify;
local $ENV{TEST_DISPATCH} = path('bin/simpici-dispatch')->absolute->stringify;
local $ENV{SIMPICI_PROVIDERS} = '';
delete local $ENV{DOCKER_HOST};
my $executor = path('bin/simpici-executor')->absolute;
my $program = path('bin/simpici-worker')->absolute;

my @foreign = (
  ('f' x 64).' - simpici.instance='.('9' x 32).' simpici.run='.('9' x 32).'.1',
  ('e' x 64).' - unrelated=label',
  ('d' x 64).' -'
);

# A dispatcher with one run to claim, a worker root, and what ssh and docker
# keep. The environment of the scene has to be in place for every program.
sub scene {
  my $root = tempdir;
  my $state = $root->child('state');
  $state->mkpath;
  $state->child('containers')->spew_utf8(map { $_."\n" } @foreign);
  push @container_files, $state->child('containers');
  push @roots, $root;
  $state->child($_)->touch for qw( docker.log ssh.log );
  my $store = SimpiCI::Store->new(root => $root->child('dispatcher'));
  SimpiCI::Queue->new(store => $store)->run(SimpiCI::Event->new(source => 'git-poll',
    event => 'push', repository => 'fixture', clone_url => "$fixture",
    ref => 'refs/heads/main', commit => $commit));
  my $token = $root->child('token');
  $token->spew_utf8($value."\n");
  my $config = $root->child('config.json');
  $config->spew_utf8($json->encode({
    root => $store->root->stringify, timeout => 60, repositories => [{
      name => 'fixture', clone_url => "$fixture", secrets => [{
        name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
      }]
    }]
  }));
  return {
    root => $root, state => $state, store => $store, worker => $root->child('worker'),
    environment => { TEST_STATE => "$state", TEST_CONFIG => "$config" }
  };
}

sub command {
  my ( $scene, @options ) = @_;
  return ( $^X, '-I'.$ENV{TEST_LIB}, "$program", '--dispatcher', 'test-host',
    '--root', $scene->{worker}->stringify, '--executor', "$executor", @options );
}

# Starts simpici-worker with its output in a file and returns its process.
sub launch {
  my ( $scene, $output, @options ) = @_;
  local @ENV{ keys $scene->{environment}->%* } = values $scene->{environment}->%*;
  my @command = command($scene, @options);
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDOUT, '>', $output->stringify or exit 97;
    open STDERR, '>&', \*STDOUT or exit 97;
    exec { $command[0] } @command or exit 98;
  }
  push @launched, $pid;
  return $pid;
}

# Starts the worker and returns once a container of its run is running.
sub start {
  my ( $scene ) = @_;
  my $output = $scene->{state}->child('output');
  my $pid = launch($scene, $output);
  my $deadline = time + 30;
  sleep 0.05 until $scene->{state}->child('running')->exists || time > $deadline
    || waitpid($pid, 1) != 0;
  ok $scene->{state}->child('running')->exists, 'the job runs in its container'
    or diag $output->slurp_utf8;
  return $pid;
}

# One cycle of a worker that is started again. The store stays locked for as
# long as the run of a killed worker is being ended: such a start is repeated.
sub once {
  my ( $scene ) = @_;
  my $output = $scene->{state}->child('once');
  my $deadline = time + 20;
  my $status;
  do {
    waitpid(launch($scene, $output, '--once'), 0);
    $status = $? >> 8;
  } while $output->slurp_utf8 =~ /already running/ && time < $deadline && sleep 0.2;
  return ( $status, $output->slurp_utf8 );
}

sub containers { [ $_[0]->{state}->child('containers')->lines_utf8({ chomp => 1 }) ] }

sub own_container {
  my ( $scene ) = @_;
  my ( $line ) = grep { /simpici\.run=/ && !/9{32}/ } containers($scene)->@*;
  return split / /, $line // '';
}

sub gone_within {
  my ( $pid, $seconds ) = @_;
  my $deadline = time + $seconds;
  sleep 0.05 while kill(0, $pid) && time < $deadline;
  return !kill(0, $pid);
}

sub files_with_value {
  my ( $root ) = @_;
  my @found;
  $root->visit(sub {
    my ( $path ) = @_;
    return if -l $path->stringify || !-f $path->stringify;
    push @found, $path->relative($root)->stringify if $path->slurp_raw =~ /\Q$value\E/;
  }, { recurse => 1, follow_symlinks => 0 });
  return [ sort @found ];
}

sub queued { $json->decode($_[0]->{store}->root->child('queue/1.json')->slurp_utf8) }

my @of_the_run = qw( secrets/1 public/runs/1.log work/1 tmp/1 runs/1 containers/1 );

subtest 'a worker that is told to end during a run' => sub {
  my $scene = scene();
  my $pid = start($scene);
  my $worker = $scene->{worker};
  my $instance = $worker->child('instance')->slurp_utf8;
  chomp $instance;
  my ( $id, $container, @labels ) = own_container($scene);
  is [ sort @labels ], [ 'simpici.instance='.$instance, 'simpici.run='.$instance.'.1' ],
    'the container carries the labels of the worker and of the run';
  is $worker->child('secrets/1/publish.env')->slurp_utf8, 'PUBLISH_TOKEN='.$value."\n",
    'and was given the secret of the claim';
  is $worker->child('containers/1')->slurp_utf8, 'simpici.run='.$instance.".1\n",
    'containers/1 names the label while the run lasts';

  kill 'TERM', $pid;
  my $deadline = time + 30;
  my $ended;
  sleep 0.05 until ( $ended = waitpid($pid, 1) ) != 0 || time > $deadline;
  my $ended_with = $?;
  kill 'KILL', $pid unless $ended;
  is [ $ended, $ended_with & 127 ], [ $pid, 15 ], 'ends by the signal it was sent';
  ok gone_within($container, 5), 'after the container of its run';
  is containers($scene), \@foreign, 'which docker no longer knows; those of others it still does';
  is [ grep { /\A(?:rm|kill) / && /f{64}|e{64}|d{64}/ }
    $scene->{state}->child('docker.log')->lines_utf8 ],
    [], 'no container of another was named to docker kill or docker rm';
  ok !$worker->child($_)->exists, $_.' is removed' for @of_the_run;
  my $completion = $json->decode($worker->child('completion.json')->slurp_utf8);
  is $completion->{result}, { state => 'signalled', exit_code => 143 },
    'the run is saved as signalled, to be reported';
  like $completion->{log},
    qr/PUBLISH_TOKEN=\[REDACTED\](?s:.*)^SimpiCI::Runner run 1 stopped by signal TERM\n\z/m,
    'with its redacted log, which ends with the reason';
  is files_with_value($worker), [], 'no file of the worker holds the secret value';
  like $scene->{state}->child('output')->slurp_utf8,
    qr/^SimpiCI::Runner run 1 stopped by signal TERM$/m, 'the worker says why the run ended';
  is queued($scene)->{state}, 'running', 'the dispatcher has not heard of it yet';

  my ( $status, $output ) = once($scene);
  is [ $status, $output ], [ 0, '' ], 'the worker starts again';
  is [ queued($scene)->{result}->@{qw( state exit_code )} ], [ 'signalled', 143 ],
    'and delivers the result';
  ok !$worker->child('completion.json')->exists, 'the completion is not kept';
  unlike $scene->{store}->root->child('public/runs/1.log')->slurp_utf8, qr/\Q$value\E/,
    'the published log has no secret value';
};

subtest 'a worker that is killed during a run' => sub {
  my $scene = scene();
  my $pid = start($scene);
  my $worker = $scene->{worker};
  my ( $id, $container ) = own_container($scene);
  kill 'KILL', $pid;
  waitpid($pid, 0);
  ok gone_within($container, 15), 'the container of its run ends without it';
  my $deadline = time + 15;
  sleep 0.05 until @{ containers($scene) } == @foreign || time > $deadline;
  is containers($scene), \@foreign, 'docker no longer knows it; those of others it still does';
  ok $worker->child('secrets/1/publish.env')->is_file,
    'nobody was left to remove the secret files';

  my ( $status, $output ) = once($scene);
  is $status, 0, 'the worker starts again';
  like $output, qr/^SimpiCI::Worker removed orphaned secret files: secrets\/1$/m,
    'and removes the secret files';
  like $output, qr/^SimpiCI::Worker removed orphaned run files: \Q$_\E$/m,
    'and '.$_ for qw( public/runs/1.log work/1 tmp/1 );
  unlike $output, qr/\Q$value\E/, 'without the value';
  ok !$worker->child($_)->exists, $_.' is removed' for @of_the_run;
  is files_with_value($worker), [], 'no file of the worker holds the secret value';
  is queued($scene)->{state}, 'running', 'the run keeps its lease until that expires';
};

subtest 'containers a killed worker left' => sub {
  my $scene = scene();
  SimpiCI::Store->new(root => $scene->{worker})->prepare;
  my $worker = $scene->{worker};
  my $instance = SimpiCI::Store->new(root => $worker)->instance;
  my @own = map { $_.' - simpici.instance='.$instance.' simpici.run='.$instance.'.5' }
    'a' x 64, 'b' x 64;
  $scene->{state}->child('containers')->append_utf8(map { $_."\n" } @own);
  # The queue of this scene is not to be claimed from: only the start counts.
  local $scene->{environment}->{TEST_CONFIG} = $scene->{root}->child('missing.json')->stringify;

  my ( $status, $output ) = once($scene);
  is $scene->{state}->child('docker.log')->slurp_utf8, '',
    'a worker that finds no containers/ entry does not ask docker';
  is containers($scene), [ @foreign, @own ], 'and removes nothing';

  $worker->child('containers')->mkpath;
  $worker->child('containers/5')->spew_utf8('simpici.run='.$instance.".5\n");
  {
    local $scene->{environment}->{TEST_DOCKER_DOWN} = 1;
    $scene->{state}->child('ssh.log')->spew_utf8('');
    ( $status, $output ) = once($scene);
    like $output, qr/^simpici-worker: SimpiCI::Worker cannot remove orphaned containers: SimpiCI::Runner cannot list containers: docker ps ended with 1 at /m,
      'a worker that cannot ask docker says so';
    is $scene->{state}->child('ssh.log')->slurp_utf8, '', 'and does not ask the dispatcher for work';
    ok $worker->child('containers/5')->is_file, 'containers/5 stays';
  }

  ( $status, $output ) = once($scene);
  like $output, qr/^SimpiCI::Worker removed orphaned containers: 2$/m,
    'a worker that finds one removes the containers of its instance and says how many';
  is containers($scene), \@foreign, 'those of others are still there';
  is [ grep { !/\A(?:ps -aq --no-trunc --filter label=simpici\.instance=\Q$instance\E|(?:kill|rm -f) a{64} b{64})\n\z/ }
    $scene->{state}->child('docker.log')->lines_utf8 ], [],
    'docker was asked for the containers of the instance and to remove them, nothing else';
  ok !$worker->child('containers/5')->exists, 'containers/5 is gone';
  isnt $scene->{state}->child('ssh.log')->slurp_utf8, '', 'and the dispatcher is asked for work';
};

done_testing;
