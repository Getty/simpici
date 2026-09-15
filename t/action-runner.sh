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

# A provider contributes extra jobs; the repository's own same-named job wins.
prov_root="$(mktemp -d)"
trap 'rm -rf "$test_root" "$prov_root"' EXIT
mkdir -p "$prov_root/.cicd" "$prov_root/tmp" "$prov_root/bin"
printf '#!/bin/sh\nexit 0\n' >"$prov_root/.cicd/perl+5.40+test.sh"
chmod +x "$prov_root/.cicd/perl+5.40+test.sh"
cat >"$prov_root/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
out='' ; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == -v ]] && [[ "${args[i+1]}" == *:/cicd-out ]] && out="${args[i+1]%:/cicd-out}"
done
[[ -n "$out" ]] || { echo 'fake docker: provider run has no /cicd-out mount' >&2; exit 1; }
for ver in 5.36 5.38 5.40; do
  printf '#!/bin/sh\nexit 0\n' >"$out/perl+$ver+test.sh"
  chmod +x "$out/perl+$ver+test.sh"
done
FAKE
chmod +x "$prov_root/bin/docker"
provider_plan="$(PATH="$prov_root/bin:$PATH" SIMPICI_PLAN_ONLY=true \
  SIMPICI_PROVIDERS='example.org/getty-provider@sha256:deadbeef' \
  GITHUB_WORKSPACE="$prov_root" RUNNER_TEMP="$prov_root/tmp" action/run.sh)"
provider_expected=$'30\ttest\tdocker.io/library/perl:5.36\tperl+5.36\tperl+5.36+test.sh\n30\ttest\tdocker.io/library/perl:5.38\tperl+5.38\tperl+5.38+test.sh\n30\ttest\tdocker.io/library/perl:5.40\tperl+5.40\tperl+5.40+test.sh'
[[ "$provider_plan" == "$provider_expected" ]] || { printf 'unexpected provider plan:\n%s\n' "$provider_plan" >&2; exit 1; }
