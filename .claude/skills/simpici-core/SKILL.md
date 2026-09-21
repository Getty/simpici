---
name: simpici-core
description: Use for SimpiCI architecture and implementation work involving events, polling, deduplication, filesystem queues, exact checkouts, phased container jobs, branch policy, reports or security boundaries.
---

# SimpiCI core

SimpiCI is a small Git-aware job runner, not a general CI platform. The repo and
distribution are `simpici` and `SimpiCI`; the daemon is `simpicid`; the
optional trusted operator CLI is `simpici`.

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
  and artifact directories. There is no automatic cross-job artifact transfer.
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

## Development direction

Keep native and hosted entry points on the same executor contract without
claiming their queue/report/recovery lifecycles already match. Tests should
cover duplicate sources, interruption, concurrent claims, phase barriers,
image parsing, path traversal, timeout/signals and secret exclusion.

Use `prove -lr t/` during development and `dzil test` before release.
