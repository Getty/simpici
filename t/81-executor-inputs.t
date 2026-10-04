use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( tempdir );
use SimpiCI::Store;
use SimpiCI::Queue;
use SimpiCI::Dispatcher;

my $root = tempdir;
$root->child('.cicd')->mkpath;
$root->child('bin')->mkpath;
for my $name (qw( linux+build.sh linux+build.skip.sh linux+test.sh linux+publish.sh )) {
  $root->child('.cicd', $name)->spew_utf8("#!/bin/sh\nexit 0\n");
}
# The stub records, per job, the value of CICD_INPUTS and every /inputs mount:
# its container target, each job directory below it with that directory's
# files, and the marker the earlier "linux" job wrote into its /artifacts.
my $docker = $root->child('bin/docker');
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
phase='' job='' inputs_env='' artifacts=''
declare -a inputs=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    CICD_PHASE=*)  phase="${args[i]#*=}" ;;
    CICD_JOB=*)    job="${args[i]#*=}" ;;
    CICD_INPUTS=*) inputs_env="${args[i]#*=}" ;;
    -v) case "${args[i+1]}" in
          *:/artifacts) artifacts="${args[i+1]%:/artifacts}" ;;
          *:/inputs/*)  inputs+=("${args[i+1]}") ;;
        esac ;;
  esac
done
seen=''
for mount in ${inputs[@]+"${inputs[@]}"}; do
  host="${mount%%:*}"
  listing=''
  for dir in "$host"/*/; do
    dir="${dir%/}"
    listing+="${dir##*/}[$(ls -A "$dir")]"
  done
  seen+="${mount#*:}=$listing$(cat "$host/linux/marker");"
done
printf '%s/%s|%s|%s\n' "$phase" "$job" "$inputs_env" "$seen" >>"$TEST_TRACE"
[[ "$job" == skip ]] && exit 78
printf 'made-by-%s' "$phase" >"$artifacts/marker"
SCRIPT
$docker->chmod(0755);
local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
local $ENV{CICD_WORKSPACE} = "$root";
local $ENV{RUNNER_TEMP} = "$root";
local $ENV{SIMPICI_PROVIDERS} = '';
local $ENV{SIMPICI_CONCURRENCY} = 1;
local $ENV{TEST_TRACE} = $root->child('trace')->stringify;

is system('bash', 'bin/simpici-executor'), 0, 'run with a skipped build job succeeds';
is [sort split /\n/, $root->child('trace')->slurp_utf8], [
  'build/linux|/inputs|',
  'build/skip|/inputs|',
  'publish/linux|/inputs|/inputs/build:ro=linux[marker]skip[]made-by-build;/inputs/test:ro=linux[marker]made-by-test;',
  'test/linux|/inputs|/inputs/build:ro=linux[marker]skip[]made-by-build;',
], 'later phases read earlier artifacts read-only; own phase and siblings are not mounted; a skipped job leaves an empty directory';

my $secret_file = $root->child('token');
$secret_file->spew_utf8("value\n");
my $dispatcher = SimpiCI::Dispatcher->new(
  queue => SimpiCI::Queue->new(store => SimpiCI::Store->new(root => $root->child('state'))),
  config => {repositories => [{name => 'o/r', clone_url => '/f', secrets => [{
    name => 'CICD_INPUTS', file => "$secret_file",
    refs => ['refs/heads/main'], events => ['push']
  }]}]}
);
like dies { $dispatcher->_secrets({repository => 'o/r', clone_url => '/f',
  source => 'git-poll', event => 'push', ref => 'refs/heads/main'}) },
  qr/invalid secret name/, 'a secret cannot shadow CICD_INPUTS';

done_testing;
