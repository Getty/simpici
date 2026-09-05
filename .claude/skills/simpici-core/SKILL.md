---
name: simpici-core
description: Use for SimpiCI architecture and implementation work involving events, polling, deduplication, filesystem queues, exact checkouts, phased container jobs, reports or security boundaries.
---

# SimpiCI core

SimpiCI is a small Git-aware job runner, not a general CI platform. The repo and
distribution are `simpici` and `SimpiCI`; the daemon is `simpicid`; the
optional trusted operator CLI is `simpici`.

## Product boundary

Sources normalize Git polling, webhook and manual input into one event shape.
Every accepted run resolves one exact commit, creates an isolated checkout,
discovers top-level `.cicd/*.sh` files and runs them in filename-selected
containers. Branch, tag, build, release and deployment policy belongs inside
the repository-owned scripts.

Do not introduce YAML build definitions, dependency DAGs, template inheritance,
arbitrary remote commands, distributed scheduling, a database or a message
broker without a demonstrated need and an explicit decision.

## Job contract

- Filenames use `<image>+<phase>[.<job>].sh`.
- Phases are `prepare`, `build`, `test`, `package`, `publish`, and `deploy`.
- Run every job in a phase concurrently, then wait before starting the next.
- Exit 0 is success, 78 is skipped, and every other exit fails the phase.
- Mount the exact checkout read-only and give each job separate writable output
  and artifact directories.
- Pass registry credentials only to `publish` and `deploy` jobs.

Plus signs encode image components. `application+dingens+13` means
`docker.io/application/dingens:13`; `ghcr.io+application+dingens+13` means
`ghcr.io/application/dingens:13`. A single component may be a curated alias:
`linux` means `docker.io/library/debian:latest`, with equivalent official
defaults for `perl`, `node`, and `python`. Script discovery itself is the plan;
do not add a second workflow language.

## Stable contracts

- Deduplicate by SHA-256 of `repository NUL ref NUL commit`; poll and webhook
  reports for the same tuple converge.
- Accept only full 40- or 64-hex commit object IDs and canonical `refs/...`
  names at the event boundary.
- Check out the exact commit detached before discovering scripts.
- Internal payloads, credentials, queue data and workspaces never enter the
  public report tree. Validate decimal run IDs before building paths.

## Filesystem model

Start with filesystem persistence. Publish complete files by writing a sibling
temporary file and atomically renaming it. Claim queue entries by rename. Lock
monotonic run-number allocation. Make crash recovery explicit and testable;
never expose partially written JSON.

The static viewer reads sanitized per-run JSON and logs. Mutation stays in the
trusted local CLI or a separately authenticated endpoint.

## Development direction

Keep the native daemon and hosted GitHub/Forgejo entry points on the same shell
executor contract. Tests should exercise duplicate sources, interruption,
concurrent claim, phase barriers, image parsing, path traversal, timeout/signal
mapping and secret exclusion early.

`TODO.md` records the broader design discussion and unresolved deployment
choices. Treat it as context, not as permission to implement every later idea.
