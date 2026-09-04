#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/repo/.cicd" "$test_root/tmp"
cp action/run.sh "$test_root/run.sh"
cat >"$test_root/repo/.cicd/linux+fixture+cicd.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
test "$CICD_FEATURE" = fixture
test "$CICD_PLATFORM" = linux
test "$CICD_SOURCE" = github-actions
test "$1" = "$CICD_EVENT_FILE"
perl -MJSON::PP -e '
  open my $fh, "<", $ARGV[0] or die $!;
  local $/;
  my $event = decode_json(<$fh>);
  exit 1 unless $event->{commit} eq "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
' "$1"
SCRIPT
chmod +x "$test_root/repo/.cicd/linux+fixture+cicd.sh"

RUNNER_OS=Linux \
RUNNER_TEMP="$test_root/tmp" \
GITHUB_WORKSPACE="$test_root/repo" \
GITHUB_RUN_ID=42 \
GITHUB_RUN_NUMBER=7 \
GITHUB_EVENT_NAME=push \
GITHUB_REPOSITORY=Getty/simpici \
GITHUB_SERVER_URL=https://github.com \
GITHUB_REF=refs/heads/main \
GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$test_root/run.sh"

touch "$test_root/repo/.cicd/linux+other+cicd.sh"
chmod +x "$test_root/repo/.cicd/linux+other+cicd.sh"
if RUNNER_OS=Linux GITHUB_WORKSPACE="$test_root/repo" "$test_root/run.sh" 2>/dev/null; then
  printf 'ambiguous script selection unexpectedly succeeded\n' >&2
  exit 1
fi
