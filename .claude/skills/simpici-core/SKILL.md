---
name: simpici-core
description: Use for SimpiCI architecture and implementation work involving events, polling, deduplication, filesystem queues, exact checkouts, script execution, reports or security boundaries.
---

# SimpiCI core

SimpiCI is a small Git-aware job runner, not a general CI platform. The repo and
distribution are `simpici` and `App::SimpiCI`; the daemon is `simpicid`; the
optional trusted operator CLI is `simpici`.

## Product boundary

Sources normalize Git polling, webhook and manual input into one event shape.
Every accepted run resolves one exact commit, creates an isolated checkout and
invokes exactly one executable script from that revision. Branch, tag, build,
release and deployment policy belongs inside the repository-owned script.

Do not introduce steps, matrices, template inheritance, implicit script
composition, arbitrary remote commands, distributed scheduling, a database or
a message broker without a demonstrated need and an explicit decision.

## Stable contracts

- Deduplicate by SHA-256 of `repository NUL ref NUL commit NUL platform NUL
  feature`; poll and webhook reports for the same tuple converge.
- Accept only full 40- or 64-hex commit object IDs and canonical `refs/...`
  names at the event boundary.
- The daemon checks out the exact commit detached before selecting a script.
- Script fallback, if present, is deterministic and stops at the first match.
- Exit 0 is success, 78 is skipped, other exits are failures; timeout and signal
  termination remain distinguishable daemon results.
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

Implement narrow boundaries in this order: normalized events, atomic storage
and run IDs, queue/claim recovery, Git polling and deduplication, exact checkout,
script resolution and supervised execution, then public reporting. Tests should
exercise duplicate sources, interruption, concurrent claim, path traversal,
timeout/signal mapping and secret exclusion early.

`TODO.md` records the broader design discussion and unresolved deployment
choices. Treat it as context, not as permission to implement every later idea.

