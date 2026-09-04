#!/usr/bin/env bash
set -euo pipefail

platform="${RUNNER_OS:-linux}"
platform="${platform,,}"
workspace="${GITHUB_WORKSPACE:-${FORGEJO_WORKSPACE:-$PWD}}"
action_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
event_file="$action_temp/simpici-event-${GITHUB_RUN_ID:-${FORGEJO_RUN_ID:-$$}}.json"

shopt -s nullglob
candidates=("$workspace/.cicd/$platform"+*+cicd.sh)
shopt -u nullglob

if (( ${#candidates[@]} == 0 )); then
  printf 'SimpiCI: no .cicd/%s+*+cicd.sh found\n' "$platform" >&2
  exit 127
fi
if (( ${#candidates[@]} > 1 )); then
  printf 'SimpiCI: script selection is ambiguous for platform %s:\n' "$platform" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  exit 64
fi

script="${candidates[0]}"
if [[ ! -x "$script" ]]; then
  printf 'SimpiCI: selected script is not executable: %s\n' "$script" >&2
  exit 126
fi

feature="$(basename "$script")"
feature="${feature#"$platform"+}"
feature="${feature%+cicd.sh}"
source_name=github-actions
[[ -n "${FORGEJO_ACTIONS:-}" || -n "${FORGEJO_SERVER_URL:-}" ]] && source_name=forgejo-actions

export CICD_RUN_NUMBER="${GITHUB_RUN_NUMBER:-${FORGEJO_RUN_NUMBER:-0}}"
export CICD_SOURCE="$source_name"
export CICD_EVENT="${GITHUB_EVENT_NAME:-${FORGEJO_EVENT_NAME:-push}}"
export CICD_REPOSITORY="${GITHUB_REPOSITORY:-${FORGEJO_REPOSITORY:-unknown}}"
export CICD_CLONE_URL="${GITHUB_SERVER_URL:-${FORGEJO_SERVER_URL:-}}/${CICD_REPOSITORY}.git"
export CICD_REF="${GITHUB_REF:-${FORGEJO_REF:-}}"
export CICD_COMMIT="${GITHUB_SHA:-${FORGEJO_SHA:-}}"
export CICD_PLATFORM="$platform"
export CICD_FEATURE="$feature"
export CICD_WORKSPACE="$workspace"
export CICD_EVENT_FILE="$event_file"
export CICD_ROOT="$workspace/.cicd"
export CICD_ARTIFACTS="$workspace/.cicd-artifacts"
export CICD_BRANCH=''
export CICD_TAG=''
if [[ "$CICD_REF" == refs/heads/* ]]; then
  CICD_BRANCH="${CICD_REF#refs/heads/}"
elif [[ "$CICD_REF" == refs/tags/* ]]; then
  CICD_TAG="${CICD_REF#refs/tags/}"
fi
mkdir -p "$CICD_ARTIFACTS"

json_string() {
  local value="$1"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf 'SimpiCI: event values must not contain newlines\n' >&2
    exit 65
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

umask 077
{
  printf '{\n'
  printf '  "source": %s,\n' "$(json_string "$CICD_SOURCE")"
  printf '  "event": %s,\n' "$(json_string "$CICD_EVENT")"
  printf '  "repository": %s,\n' "$(json_string "$CICD_REPOSITORY")"
  printf '  "clone_url": %s,\n' "$(json_string "$CICD_CLONE_URL")"
  printf '  "ref": %s,\n' "$(json_string "$CICD_REF")"
  printf '  "commit": %s,\n' "$(json_string "$CICD_COMMIT")"
  printf '  "platform": %s,\n' "$(json_string "$CICD_PLATFORM")"
  printf '  "feature": %s\n' "$(json_string "$CICD_FEATURE")"
  printf '}\n'
} >"$event_file"

cd "$workspace"
exec "$script" "$event_file"
