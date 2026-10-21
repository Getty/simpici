---
name: simpici-core
description: Use for SimpiCI architecture and implementation work involving events, polling, deduplication, filesystem queues, exact checkouts, phased container jobs, branch policy, reports or security boundaries.
---

# SimpiCI core

SimpiCI is a small Git-aware job runner, not a general CI platform. The repo and
distribution are `simpici` and `SimpiCI`; the daemon is `simpicid`; the
optional trusted operator CLI is `simpici`.

## Module map

| Module | Owns |
|---|---|
| `SimpiCI` | the distribution facade; no logic of its own |
| `SimpiCI::Event` | the validated, normalized repository event |
| `SimpiCI::Store` | the private filesystem persistence |
| `SimpiCI::Queue` | the durable, deduplicated dispatch queue with fenced leases |
| `SimpiCI::Runner` | the run supervisor around an exact detached checkout |
| `SimpiCI::Worker` | the outbound-only worker with its durable completion retry |
| `SimpiCI::Dispatcher` | the restricted worker protocol and the dispatcher-owned secret policy |
| `SimpiCI::Config` | reading a configuration file and the rules of its settings |
| `SimpiCI::Source::GitPoll` | polling the configured Git refs |
| `SimpiCI::Role::Secrets` | what a secret may be and how its value is redacted |
| `SimpiCI::App::Run` | the implementation of the `simpici` operator command |
| `SimpiCI::App::Eventd` | the implementation of the `simpicid` polling daemon |

## Entry points

| Program | Role |
|---|---|
| `bin/simpicid` | the polling daemon: polls the configured refs and starts the runs |
| `bin/simpici` | the operator CLI: one event, the recorded tips, `--forget` a ref |
| `bin/simpici-dispatch` | serves one restricted worker request over SSH standard input |
| `bin/simpici-worker` | pulls exact-revision jobs over an outbound SSH connection |
| `bin/simpici-executor` | the Bash executor every entry point ends in |

## Product boundary

Native events normalize Git polling, webhook and manual input into one shape;
the daemon currently implements polling, not an HTTP webhook listener. The
native runner creates an exact detached checkout. Hosted callers supply their
checkout, and the direct shell executor uses an existing workspace as-is.
All discover top-level `.cicd/*.sh` jobs in filename-selected containers.
Build and release steps remain repository-owned shell code. Admission and
credential authorization must precede execution, not depend on script guards.

Keep the existing dispatcher/worker transport small. Do not introduce YAML
build definitions, dependency DAGs, template inheritance, arbitrary remote
commands, a general distributed scheduler, a database or a message broker
without demonstrated need and an explicit decision.

## Job contract

- Filenames use `<image>+<phase>[.<job>].sh`; job names are unique per phase.
- Phases are `prepare`, `build`, `test`, `package`, `publish`, and `deploy`.
- Bound in-phase concurrency with `SIMPICI_CONCURRENCY`, default 2. Complete
  every job in the current phase before deciding whether to start the next.
- Job exit 0 is success, 78 is skipped, and every other exit fails the phase.
  The current executor returns 0 even when all jobs skip.
- Mount the workspace read-only and give each job separate writable output
  and artifact directories. Artifacts of earlier phases are mounted read-only
  under `$CICD_INPUTS/<phase>/<job>/`; jobs of the same phase never see each
  other's, and nothing is transferred between workers or to the dispatcher.
- Job scripts need executable bits and an interpreter available in their image;
  the executor does not install Bash or clear the image ENTRYPOINT.
- Registry credentials go only to `publish` and `deploy` jobs. Phase selection
  is not authorization: untrusted code can itself add a publish job.
- Build/publish socket access grants broad runner-host control; use appropriate
  VM/network isolation. `CICD_PUBLISH_IMAGE=false` is only a script convention.

Plus signs encode image components. `application+dingens+13` means
`docker.io/application/dingens:13`; `ghcr.io+application+dingens+13` means
`ghcr.io/application/dingens:13`. Single-component aliases are `linux` (Debian),
`perl`, `node`, and `python`, with official `:latest` defaults. Job filenames do
not support image digests. Script discovery is the plan, not a second language.

For executor variables, providers, mounts and current status semantics, read
`docs/executor.md`; for complete job examples, read `docs/cookbook.md`.

## Native event and lifecycle boundaries

- Accept full lowercase 40- or 64-hex commit OIDs and canonical `refs/...`
  names at the native event boundary.
- Queue deduplication uses SHA-256 of `repository NUL ref NUL commit` across
  sources. Local polling only compares observed tips; one-shot runs do not
  use the queue. Do not describe all entry points as durably deduplicated.
- Native execution checks out the exact commit detached before discovery.
  Mutable images, providers and dependencies are not reproducibility guarantees.
- Keep internal payloads, credentials, queue data and workspaces outside the
  public tree. Validate decimal run IDs before building paths.
- A clone URL is a URL of the scheme `https`, `http`, `ssh` or `file`, an SSH
  address `[user@]host:path` or an absolute path. A relative path is refused:
  git would read it from the directory it happens to run in, another one for
  the poller than for the checkout. A URL whose user part may hold
  credentials is shown to the jobs without it.

## Filesystem and reporting

Publish complete JSON files with a sibling temporary file and atomic rename.
Lock monotonic run-number allocation. Current queue claims use locked state
updates and atomic JSON replacement, not renames between queue directories.
Make crash recovery explicit and testable; expired claims become interrupted,
not automatically replayed work.

Local native logs are unredacted. Worker/dispatcher redact assigned literal
secret values, not arbitrary sensitive output. Public JSON projection is not
a substitute for log review or HTML escaping. Mutation stays in the trusted
local CLI or a separately authenticated endpoint.

## Planned branch policy

Before changing branch admission, default-branch selection or protection
metadata, read `docs/superpowers/specs/2026-09-21-branch-policy-design.md`.
It distinguishes agreed defaults from proposed native metadata sources.
Automatic protection checks, `.cicd/policy.json` and `branch_metadata` are not
implemented. Do not document them as available or add a `policy_branch` switch.

## The repository's own jobs

`.cicd/` holds the jobs SimpiCI runs on itself: `docker+27+build.image.sh` and
`docker+27+publish.image.sh` build the image and publish it, `perl+5.40+test.unit.sh`
installs the dependencies and runs the suite. The image in the filename is the image
the job runs in; the image it builds is the one the entry point names in
`CICD_IMAGE_REPOSITORY`.

## Test layout

`t/` is numbered by the part under test: `00` load, `10` event, `20` and `21` store,
`30` to `39` runner, `40` to `49` polling, `50` and `51` CLI and configuration, `60`
to `69` dispatcher, `70` to `79` worker, `80` to `85` executor, `90` to `92`
transport. The image grammar and the provider jobs are covered by
`t/action-runner.sh`, a shell helper that only the CI job runs, not by `prove -lr t/`.

## Development direction

Keep native and hosted entry points on the same executor contract without
claiming their queue/report/recovery lifecycles already match. Tests should
cover duplicate sources, interruption, concurrent claims, phase barriers,
image parsing, path traversal, timeout/signals and secret exclusion.

Use `prove -lr t/` during development and `dzil test` before release.
