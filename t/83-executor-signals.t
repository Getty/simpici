use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );

# An executor that is told to end removes the containers it started before
# it does, all of them, and a second signal does not cut that short: its
# supervisor and whoever ends the supervisor may both send one.

my $executor = path('bin/simpici-executor')->absolute->stringify;

my $root = tempdir;
$root->child($_)->mkpath for qw( .cicd bin tmp );
$root->child('.cicd/linux+test.'.$_.'.sh')->spew_utf8("#!/bin/sh\nexit 0\n") for qw( one two );
# A container is written down when it is started and stays until the test
# ends it. docker kill takes its time, as a daemon under load does.
my $docker = $root->child('bin/docker');
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
command="$1"; shift
case "$command" in
  run)
    cidfile='' job=''
    while (( $# )); do
      case "$1" in
        --cidfile) shift; cidfile="$1" ;;
        CICD_JOB=*) job="${1#*=}" ;;
      esac
      shift
    done
    printf 'container-of-%s\n' "$job" > "$cidfile"
    printf '%s\n' "$job" >> "$TEST_STATE/running"
    exec sleep 60
    ;;
  kill)
    sleep 1
    printf 'kill %s\n' "$*" >> "$TEST_STATE/calls"
    ;;
  *)
    printf '%s %s\n' "$command" "$*" >> "$TEST_STATE/calls"
    ;;
esac
SCRIPT
$docker->chmod(0755);

my $state = tempdir;
local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
local $ENV{CICD_WORKSPACE} = "$root";
local $ENV{RUNNER_TEMP} = $root->child('tmp')->stringify;
local $ENV{SIMPICI_PROVIDERS} = '';
local $ENV{SIMPICI_CONCURRENCY} = 2;
local $ENV{TEST_STATE} = "$state";
delete local $ENV{SIMPICI_INSTANCE};

my $pid = fork;
die 'fork failed' unless defined $pid;
unless ($pid) {
  # A group of its own, as the supervisor gives it: the jobs end with it.
  setpgrp(0, 0);
  open STDOUT, '>', $state->child('output')->stringify or exit 97;
  open STDERR, '>&', \*STDOUT or exit 97;
  exec 'bash', $executor or exit 98;
}
END {
  local $?;
  kill 'KILL', -$pid if $pid && waitpid($pid, WNOHANG) == 0;
}

my $running = $state->child('running');
my $deadline = time + 30;
sleep 0.05 until ( $running->exists && $running->lines_utf8 == 2 ) || time > $deadline;
is [ sort $running->lines_utf8({ chomp => 1 }) ], [qw( one two )], 'two jobs run in their containers'
  or diag $state->child('output')->slurp_utf8;

kill 'TERM', $pid;
sleep 0.3;
kill 'TERM', $pid;
$deadline = time + 30;
my $ended;
sleep 0.05 until ( $ended = waitpid($pid, WNOHANG) ) != 0 || time > $deadline;
is [ $ended, $? >> 8, $? & 127 ], [ $pid, 143, 0 ],
  'the executor ends with the exit code of a TERM, and by neither signal';
is [ $state->child('calls')->lines_utf8({ chomp => 1 }) ], [
  'kill container-of-one container-of-two',
  'rm -f container-of-one container-of-two'
], 'after it killed and removed both containers, the second signal notwithstanding';
kill 'KILL', -$pid;

done_testing;
