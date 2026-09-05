# SimpiCI daemon — project brief and TODO

This document captures the decisions made during the initial design discussion.
It is intentionally broader than an implementation checklist so a fresh agent
session can reconstruct the reasoning and keep the first version small.

## Working name

- Project/repository: `simpici`
- Long meaning: **simple CI daemon**
- Daemon executable: `simpicid`
- Optional operator CLI: `simpici`
- Perl namespace candidates:
  - `SimpiCI`
  - `SimpiCI::Daemon`
  - `SimpiCI::Poller`
  - `SimpiCI::Runner`
  - `SimpiCI::Report`
- A quick web/MetaCPAN/GitHub search on 2026-09-03 found no obvious existing CI
  product using `simpicid`.

## Product principle

Build a small Git-aware job runner, not another general CI platform.

The service organizes events, checkouts, execution, status, logs, artifacts,
and notification. It does **not** understand build steps and does not invent a
workflow language. All project-specific behavior stays in an ordinary,
executable shell script committed to the repository.

The intended summary is:

> Sources create runs. Every run checks out one exact revision, discovers its
> top-level `.cicd/*.sh` files and executes them in filename-selected
> containers. Fixed phases provide barriers; jobs within a phase run in
> parallel.

Avoid YAML pipelines, template inheritance, matrices, plugins, Kubernetes, and
implicit composition in the first version.

## Primary use case

The motivating project is `LEDaquaristik/sunriser`.

Its release flow should eventually build and publish a Docker image. GitHub
Actions may also call the same repository-owned script, but the actual build
logic must live in one place and remain independent of GitHub or Forgejo.

The current SunRiser Dockerfile targets `linux/amd64` because it downloads an
x86 Linux build of the legacy ARM cross-toolchain. Do not advertise it as a
multi-platform image until that changes.

SunRiser also has DarkPAN-only Perl dependencies (`Net::Async::MCP` and
`Net::Async::MCP::Server`). Its container build needs a reachable mirror,
currently represented by `SRCCI_MIRROR` with historical default
`https://src.ci/darkpan/`.

## Event sources

Git polling is a first-class and likely primary source. Webhooks are optional
latency reduction, not the foundation. Manual runs are also required.

Initial source types:

- `git-poll`
- `webhook`
- `manual`

Possible Perl classes:

- `SimpiCI::Source::GitPoll`
- `SimpiCI::Source::Webhook`
- `SimpiCI::Source::Manual`

All sources normalize their input into the same internal event. Downstream
queue and runner code must not care where an event originated.

Example normalized event:

```json
{
  "source": "git-poll",
  "event": "push",
  "repository": "sunriser",
  "ref": "refs/heads/master",
  "commit": "abc123"
}
```

## Git polling

Repository configuration needs at least:

```json
{
  "name": "sunriser",
  "clone_url": "git@src.ci:ledaquaristik/sunriser.git",
  "refs": [
    "refs/heads/master",
    "refs/tags/*"
  ],
  "interval": 60
}
```

Polling behavior:

1. Run `git ls-remote` for configured refs.
2. Compare each SHA with the last observed SHA.
3. Create a normalized event when a configured ref changes or a new matching
   ref appears.
4. Persist the new observation safely.
5. Enqueue through the same deduplication path used by webhooks and manual
   runs.

First-start policy must be explicit:

- Existing branches should normally be recorded without building their entire
  history.
- Existing tags should not all be released retroactively.
- Configuration may optionally request one initial build of the current branch
  tip.
- A newly appearing tag should create a run.
- A moved tag is suspicious and should not silently republish; report it or
  require an explicit policy.

## Idempotency and deduplication

Polling and webhook delivery may report the same revision. They must converge
on one run.

Use a stable deduplication key derived from at least:

```text
repository NUL ref NUL commit
```

A SHA-256 digest of that tuple is sufficient. Persist the key before or
atomically with queue insertion. Decide and document whether a manual retry
reuses the original key or adds an explicit attempt/retry identifier.

## Script discovery and phases

The repository owns ordinary executable scripts named by image and phase:

```text
.cicd/
├── linux+prepare.sh
├── perl+5.40+test.unit.sh
├── application+dingens+13+build.image.sh
└── ghcr.io+application+dingens+13+publish.image.sh
```

The grammar is `<image>+<phase>[.<job>].sh`. The phases are `prepare`, `build`,
`test`, `package`, `publish`, and `deploy`, in that order. Every discovered job
in a phase starts concurrently; all must finish successfully or skip before the
next phase starts. Exit 78 means skipped. Any other nonzero exit stops later
phases.

Plus signs encode image components: `application+dingens+13` resolves to
`docker.io/application/dingens:13`, while
`ghcr.io+application+dingens+13` resolves to
`ghcr.io/application/dingens:13`. Single-name aliases cover common defaults;
for example `linux` is `docker.io/library/debian:latest`. The optional job name
creates a stable identity and separate writable output/artifact directories.
The checkout itself is mounted read-only. Only `publish` and `deploy` receive
registry credentials.

## Checkout responsibility

The daemon performs the initial checkout. The script cannot be safely invoked
before its repository exists, and branch names alone are not reproducible.

The daemon must:

1. Resolve/receive an exact commit SHA.
2. Create an isolated workspace for the run.
3. Fetch that exact revision.
4. Check it out detached.
5. Discover and validate the CI/CD plan in that checked-out revision.
6. Execute each job in its selected container with the workspace read-only.

Conceptual commands:

```bash
git init .
git remote add origin "$CICD_CLONE_URL"
git fetch --depth=1 origin "$CICD_COMMIT"
git checkout --detach "$CICD_COMMIT"
```

The repository script may perform additional checkouts needed by its build.
For example, SunRiser may explicitly clone the separate firmware repository at
a specified revision. Those project-specific checkouts do not belong in the
generic daemon.

## Invocation contract

Invoke each discovered script once, passing the normalized event file as its
first argument:

```bash
./perl+5.40+test.unit.sh "$CICD_EVENT_FILE"
```

Minimum environment under consideration:

```text
CICD_RUN_NUMBER=1842
CICD_SOURCE=git-poll
CICD_EVENT=push
CICD_REPOSITORY=LEDaquaristik/sunriser
CICD_CLONE_URL=git@src.ci:ledaquaristik/sunriser.git
CICD_REF=refs/heads/master
CICD_BRANCH=master
CICD_COMMIT=abc123
CICD_TAG=
CICD_PHASE=test
CICD_JOB=unit
CICD_IMAGE_REF=docker.io/library/perl:5.40
CICD_WORKSPACE=/var/lib/simpicid/work/1842
CICD_EVENT_FILE=/var/lib/simpicid/runs/1842/event.json
CICD_ARTIFACTS=/var/lib/simpicid/public/runs/1842/artifacts
CICD_ROOT=/var/lib/simpicid/work/1842/.cicd
```

Open questions to settle before implementation:

- Exact variable names and which are mandatory.
- Whether the event JSON is passed by argument, environment only, or both.
- Whether the daemon uses a clean `env -i` allowlist.
- Which minimal `PATH`, locale, umask, and home directory a build receives.
- Whether stdout/stderr are merged in chronological order or stored
  separately.
- Signal behavior for cancellation and timeouts.

Proposed exit status contract:

- `0`: success
- `78`: intentionally skipped/not applicable
- any other value: failed
- timeout or signal: distinct daemon-generated result metadata

## Hooks remain inside the script

The runner invokes all discovered scripts for an accepted run. Branch,
tag, event, and release policy live inside that script using normal code.

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

run_tests() {
  prove -Ilib t/
}

on_push() {
  case "$CICD_BRANCH" in
    master)
      run_tests
      ;;
    *)
      exit 78
      ;;
  esac
}

on_release() {
  run_tests
  build_container "$CICD_TAG"
  publish_container "$CICD_TAG"

  if [[ "${CICD_PRERELEASE:-0}" != 1 ]]; then
    publish_latest
  fi
}

case "$CICD_EVENT" in
  push)         on_push ;;
  release)      on_release ;;
  pull_request) on_pull_request ;;
  *)            exit 78 ;;
esac
```

## Storage model

Start with filesystem persistence rather than a database or message broker.
Possible layout:

```text
/var/lib/simpicid/
├── counter
├── counter.lock
├── state/
│   └── repositories/
├── queue/
├── running/
├── finished/
├── work/
│   └── 1842/
├── runs/
│   └── 1842/
│       └── event.json
└── public/
    ├── index.html
    └── runs/
        ├── index.json
        ├── 1842.json
        ├── 1842.log
        └── 1842/
            └── artifacts/
```

Use atomic filesystem operations:

- Write JSON to a temporary file in the same filesystem, `fsync` as needed,
  then rename it into place.
- Claim a queued job by atomically renaming it from `queue/` to `running/`.
- Allocate numeric run IDs while holding `flock` on the counter.
- Never expose queue, workspace, repository credentials, or event secrets
  beneath the public document root.

Revisit SQLite only if querying, concurrent writers, retention, or recovery
becomes painful. Do not add it preemptively.

## Run numbers

Use monotonically increasing human-friendly run numbers, e.g. `1842`.

The URL fragment identifies the run:

```text
https://ci.example/#1842
```

Run number allocation must be locked and crash-safe. The deduplication key is
separate from the presentation-oriented run number.

## Static UI

The UI is a small static HTML/JavaScript application. A normal static web
server such as nginx or Caddy serves it. The first version should require no
CGI, application server session, WebSocket, or server-side rendering.

Routing behavior:

- `/#1842` validates the fragment and fetches `/runs/1842.json`.
- No fragment fetches `/runs/index.json` and shows recent runs.
- Invalid fragments are rejected client-side and never interpolated into
  arbitrary paths.
- Use `cache: "no-store"` or appropriate response headers for active runs.

Example JavaScript:

```javascript
const run = location.hash.slice(1);

if (!/^[0-9]+$/.test(run)) {
  showRunList();
} else {
  fetch(`/runs/${run}.json`, { cache: "no-store" })
    .then(response => {
      if (!response.ok) throw new Error(`Run ${run} not found`);
      return response.json();
    })
    .then(showRun);
}
```

Suggested per-run JSON:

```json
{
  "run": 1842,
  "state": "running",
  "source": "git-poll",
  "event": "release",
  "repository": "LEDaquaristik/sunriser",
  "ref": "refs/tags/0.941",
  "branch": null,
  "tag": "0.941",
  "commit": "abc123",
  "started_at": "2026-09-03T21:14:00Z",
  "finished_at": null,
  "duration_seconds": 42,
  "exit_code": null,
  "log": "/runs/1842.log",
  "artifacts": []
}
```

Suggested run index:

```json
{
  "latest": 1842,
  "runs": [1842, 1841, 1840]
}
```

The log can be polled every few seconds as plain text. Generating a static
`report.html` per completed run is optional; the JS viewer plus JSON may be
sufficient. If HTML is generated from log data, escape all content.

Potential UI features, still intentionally small:

- recent-run list
- status color and duration
- repository/ref/commit links
- live log tail or full log
- artifacts and published image digest
- source indicator (`git-poll`, `webhook`, `manual`)
- copied command/environment summary with secrets excluded

## Feedback and notification

Email is an acceptable primary notification mechanism. Use a local MTA or
`sendmail` interface rather than embedding a large mail subsystem.

Example completion mail:

```text
Subject: [sunriser] container 0.941 succeeded

Run: 1842
Commit: abc123
Duration: 14m 22s
Image: ghcr.io/ledaquaristik/sunriser:0.941
Report: https://ci.example/#1842
```

Suggested defaults:

- Always mail failed runs.
- Always mail release results.
- Avoid mailing every successful polling build unless configured.
- A start notification is optional and probably too noisy.
- Later, optionally post commit status back to GitHub/Forgejo through a small
  source-specific adapter. This must not be required for the core runner.

## Manual operations

An optional `simpici` CLI may provide:

```text
simpici status
simpici runs
simpici show 1842
simpici run sunriser --ref master
simpici retry 1842
simpici cancel 1842
```

Do not add unauthenticated mutation controls to the static UI. Retry and cancel
need authenticated POST/API or trusted local CLI access. A read-only viewer can
remain completely static.

## Security invariants

- Verify webhook signatures using constant-time comparison.
- Enforce a small request-body limit and content type.
- Add replay protection where the forge supports delivery IDs/timestamps.
- Allowlist repositories and clone URLs server-side; apply an explicit image
  policy before running untrusted repositories.
- Check out the exact commit SHA detached; never trust a branch name as the
  executable revision.
- Treat scripts from untrusted pull requests as arbitrary code.
- Never expose publishing/deployment secrets to untrusted revisions or forks.
- Prefer an isolated build user and, eventually, containers/VMs with CPU,
  memory, disk, process-count, and wall-clock limits.
- Apply a restrictive umask.
- Validate run IDs strictly as decimal integers before constructing paths.
- Disable directory listing and symlink traversal in the public file server.
- Keep public reports separate from internal event payloads because webhook
  payloads may contain private data.
- Pass secrets via controlled environment variables or files, not command-line
  arguments.
- Do not include environment dumps in reports.
- Redaction is a last defense, not a substitute for limiting which secrets a
  job receives.
- Never offer a generic remote shell endpoint.
- Production deployment must remain a separately authorized feature, not an
  accidental consequence of a generic build.

## Process model

Keep components conceptually separate even if the first executable runs them
in one process:

1. Poller/timer produces normalized events.
2. Optional HTTP listener produces normalized webhook/manual events.
3. Queue persists and deduplicates jobs.
4. Worker claims one job and supervises its process.
5. Reporter writes public JSON/log metadata and sends notifications.

Open design choice: use one daemon with child processes, or `simpicid` plus a
separate worker executable managed by systemd. Prefer the arrangement with the
clearest crash recovery, not theoretical distribution.

The first release can support one worker and one concurrent run. Concurrency
must be configurable later, but do not build distributed scheduling now.

## Configuration philosophy

Configuration should describe repositories and service mechanics, never build
steps. JSON, TOML, or a small Perl config are all candidates; choose one after
checking the author's existing project conventions.

Configuration may contain:

- repository name and clone URL
- ref patterns
- poll interval
- initial-poll policy
- platform and feature used for script selection
- concurrency/timeout/resource limits
- notification recipients and policy
- public base URL
- credential references (not raw secrets when avoidable)

Configuration must not grow `steps`, `includes`, `extends`, `matrix`, or an
expression language. If build logic appears in configuration, move it into the
repository's script.

## Deliberate non-goals for version 1

- general-purpose workflow/pipeline DSL
- YAML templates or includes
- implicit composition of workflow fragments
- matrix builds
- distributed scheduler
- plugin marketplace
- Kubernetes orchestration
- multi-tenant user management
- arbitrary shell commands submitted through HTTP
- automatic production deployment
- artifact storage abstraction beyond local files
- complex log streaming protocol
- database/message broker unless filesystem persistence proves insufficient

## Suggested implementation order

1. Create a normal Getty-style Perl distribution after reading the new
   repository's `.claude` instructions and relevant skills.
2. Define and test the normalized event schema.
3. Define and test run-number allocation and atomic JSON writes.
4. Implement filesystem queue and atomic worker claim.
5. Implement repository configuration and `git ls-remote` polling.
6. Implement idempotency across repeated poll results.
7. Implement exact detached checkout into an isolated workspace.
8. Define script resolution and the environment/exit-code contract.
9. Implement supervised execution with combined log capture and timeout.
10. Generate per-run JSON, log, and recent-run index atomically.
11. Build the static HTML/JavaScript viewer using `#<run-number>` routing.
12. Add completion email through the local MTA.
13. Add manual CLI-triggered runs.
14. Add authenticated webhook ingestion as an optional source.
15. Add retention/cleanup policy without deleting active jobs.
16. Integrate SunRiser by moving its Docker release commands into one
    repository-owned CI/CD script.
17. Make the GitHub Action call that same script rather than duplicating build
    logic.
18. Only then evaluate commit-status callbacks and additional workers.

## Tests required early

- first poll records refs without releasing historical tags
- changed branch creates one run
- new tag creates one run
- repeated poll creates no duplicate
- webhook plus poll for the same tuple creates no duplicate
- moved/deleted refs follow explicit policy
- queue claim is atomic across two workers
- interrupted write never exposes partial JSON
- worker restart recovers or clearly marks an abandoned run
- exact requested SHA is checked out detached
- invalid/missing scripts and duplicate job identities fail clearly
- image parsing and phase ordering are deterministic
- exit `0`, exit `78`, nonzero exit, signal, and timeout map correctly
- stdout/stderr reach the log without HTML interpretation
- run ID/path traversal attempts are rejected
- secrets are absent from public JSON and mail
- static viewer handles running, success, skipped, failed, and missing runs
- pre-release publication does not update `latest`

## Questions for the new project session

- The repository and distribution are `simpici` / `SimpiCI`; core classes use
  `SimpiCI::*`, application entry points use `SimpiCI::App::*`, and the daemon
  executable remains `simpicid`.
- What is the precise first-poll policy?
- Where will repositories be cloned from initially: Forgejo/src.ci, GitHub, or
  both?
- Which machine runs the worker, and what isolation is available there?
- Which local MTA/sendmail command should be used?
- What public/internal hostname will serve the static UI?
- How long should logs, workspaces, metadata, and artifacts be retained?
- Which repositories and refs may receive deployment credentials? Registry
  credentials are restricted to the `publish` and `deploy` phases.

## Current foundation

The project now lives at `~/dev/simpici` and uses `SimpiCI` as its Perl
namespace. Distribution metadata, the normalized event boundary and its first
tests exist. Claude Code and Codex each have a SimpiCI worker; their shared
Getty Perl/Git skills are linked with `manage-skills`, while the project-owned
`simpici-core` skill records the product boundary and architectural invariants.

The next implementation slice is atomic filesystem storage and locked run-number
allocation, followed by the persistent queue and atomic worker claim.
