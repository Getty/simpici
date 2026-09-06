use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( path tempdir );

my $root = tempdir;
$root->child('.cicd')->mkpath;
$root->child('bin')->mkpath;
$root->child('secrets')->mkpath;
$root->child('secrets/publish.env')->spew_utf8("PUBLISH_TOKEN=opaque-token\n");
for my $phase (qw( prepare test publish deploy )) {
  $root->child('.cicd/linux+'.$phase.'.sh')->spew_utf8("#!/bin/sh\nexit 0\n");
}
my $docker = $root->child('bin/docker');
$docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == run ]] || exit 0
phase='' secret_file=''
while (( $# )); do
  case "$1" in
    CICD_PHASE=*) phase="${1#*=}" ;;
    --env-file) shift; secret_file="$1" ;;
    *opaque-token*|*ambient-password*) exit 90 ;;
  esac
  shift
done
if [[ "$phase" == publish ]]; then
  [[ -n "$secret_file" ]] && grep -q 'PUBLISH_TOKEN=opaque-token' "$secret_file"
else
  [[ -z "$secret_file" ]]
fi
printf '%s\n' "$phase" >> "$TEST_TRACE"
[[ "$phase" != "${FAIL_PHASE:-none}" ]]
SCRIPT
$docker->chmod(0755);
local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
local $ENV{CICD_WORKSPACE} = "$root";
local $ENV{RUNNER_TEMP} = "$root";
local $ENV{SIMPICI_SECRETS_DIR} = $root->child('secrets')->stringify;
local $ENV{CICD_REGISTRY_PASSWORD} = 'ambient-password';
local $ENV{TEST_TRACE} = $root->child('trace')->stringify;
is system('bash', 'action/run.sh'), 0, 'Action executes shared phase runner';
is $root->child('trace')->slurp_utf8, "prepare\ntest\npublish\ndeploy\n",
  'phase order and phase-scoped secret file verified by container boundary';
$root->child('trace')->remove;
{
  local $ENV{FAIL_PHASE} = 'test';
  isnt system('bash', 'bin/simpici-executor'), 0, 'failed test fails executor';
}
is $root->child('trace')->slurp_utf8, "prepare\ntest\n", 'failure prevents publish/deploy';
$root->child('.cicd/linux+test...escape.sh')->touch;
isnt system('bash', 'action/run.sh'), 0, 'reject traversal-like job name before execution';

done_testing;
