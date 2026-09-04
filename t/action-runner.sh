#!/usr/bin/env bash
set -euo pipefail
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/.cicd" "$test_root/tmp"
touch "$test_root/.cicd/linux+prepare.sh"
touch "$test_root/.cicd/application+dingens+13+build.api.sh"
touch "$test_root/.cicd/ghcr.io+application+dingens+13+publish.sh"
plan="$(SIMPICI_PLAN_ONLY=true GITHUB_WORKSPACE="$test_root" RUNNER_TEMP="$test_root/tmp" action/run.sh)"
expected=$'10\tprepare\tdocker.io/library/debian:latest\tlinux\tlinux+prepare.sh\n20\tbuild\tdocker.io/application/dingens:13\tapi\tapplication+dingens+13+build.api.sh\n50\tpublish\tghcr.io/application/dingens:13\tghcr.io+application+dingens+13\tghcr.io+application+dingens+13+publish.sh'
[[ "$plan" == "$expected" ]] || { printf 'unexpected plan:\n%s\n' "$plan" >&2; exit 1; }
