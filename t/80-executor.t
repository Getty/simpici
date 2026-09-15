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

# --- provider hook: providers add jobs; the repo's own same-named job wins ---
{
  my $proot = tempdir;
  $proot->child('.cicd')->mkpath;
  $proot->child('bin')->mkpath;
  # the repository ships its own perl+5.40 test job; it must beat the provider's
  $proot->child('.cicd/perl+5.40+test.sh')->spew_utf8("#!/bin/sh\n# USER-5.40\nexit 0\n");
  $proot->child('.cicd/perl+5.40+test.sh')->chmod(0755);
  my $pdocker = $proot->child('bin/docker');
  $pdocker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
out='' cicd='' cmd='' ws_ro=no ws_rw=no
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -v) case "${args[i+1]}" in
          *:/cicd-out)     out="${args[i+1]%:/cicd-out}" ;;
          *:/cicd:ro)      cicd="${args[i+1]%:/cicd:ro}" ;;
          *:/workspace:ro) ws_ro=yes ;;
          *:/workspace)    ws_rw=yes ;;
        esac ;;
    /cicd/*) cmd="${args[i]}" ;;
  esac
done
if [[ -n "$out" ]]; then
  for ver in 5.36 5.38 5.40; do
    printf '#!/bin/sh\n# PROVIDER-%s\nexit 0\n' "$ver" >"$out/perl+$ver+test.sh"
    chmod +x "$out/perl+$ver+test.sh"
  done
  exit 0
fi
[[ "$ws_ro" == yes && "$ws_rw" == no ]] || { echo 'workspace not mounted read-only' >&2; exit 91; }
base="${cmd##*/}"
printf '%s=%s\n' "$base" "$(grep -oE 'USER|PROVIDER' "$cicd/$base" | head -n1)" >>"$TEST_TRACE"
exit 0
SCRIPT
  $pdocker->chmod(0755);
  local $ENV{PATH} = $proot->child('bin').':'.$ENV{PATH};
  local $ENV{CICD_WORKSPACE} = "$proot";
  local $ENV{RUNNER_TEMP} = "$proot";
  local $ENV{SIMPICI_PROVIDERS} = 'example.org/getty-provider@sha256:deadbeef';
  local $ENV{TEST_TRACE} = $proot->child('trace')->stringify;
  is system('bash', 'action/run.sh'), 0, 'provider-generated jobs execute';
  my @trace = sort split /\n/, $proot->child('trace')->slurp_utf8;
  is \@trace,
    [ 'perl+5.36+test.sh=PROVIDER', 'perl+5.38+test.sh=PROVIDER', 'perl+5.40+test.sh=USER' ],
    'provider adds 5.36/5.38, repo wins the 5.40 collision, workspace stays read-only';

  # a provider that emits an unsafe job name is rejected before any job runs
  my $bad = tempdir;
  $bad->child('bin')->mkpath;
  my $bdocker = $bad->child('bin/docker');
  $bdocker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
out=''; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == -v ]] && [[ "${args[i+1]}" == *:/cicd-out ]] && out="${args[i+1]%:/cicd-out}"
done
[[ -n "$out" ]] || exit 0
printf '#!/bin/sh\nexit 0\n' >"$out/perl+5.40+test..escape.sh"
chmod +x "$out/perl+5.40+test..escape.sh"
SCRIPT
  $bdocker->chmod(0755);
  local $ENV{PATH} = $bad->child('bin').':'.$ENV{PATH};
  local $ENV{CICD_WORKSPACE} = "$bad";
  local $ENV{RUNNER_TEMP} = "$bad";
  isnt system('bash', 'action/run.sh'), 0, 'reject unsafe provider-generated job name';
}

done_testing;
