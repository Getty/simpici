# SimpiCI House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Small Git-aware continuous integration daemon. Internals: skill `simpici-core`.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `simpici-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `simpici-release-manager` |
| Read-only research, audit, gap analysis | `simpici-worker` ("read-only, change nothing") |

Behavior-relevant = anything under `lib/`, the tests under `t/`, the programs in `bin/`, the
job contract and the admission and secret boundaries. `docs/`, `README.md`, `Changes` are not.

## Release

The images this repository builds are under the publish gate too: the publish job and the
dispatcher image go out only on the maintainer's go-ahead. A local build is fine.

## Deviations from the house rules

- **A finding from the outside world becomes an internal card**; the dispatching agent files
  it.

## Hazards

- **The job contract is the product — don't regress it silently.** What a caller depends on
  is the filename grammar `<image>+<phase>[.<job>].sh`, the phases `prepare`, `build`,
  `test`, `package`, `publish` and `deploy`, the exit codes of a job (0 succeeds, 78 skips)
  and the mounts: the checkout read-only, each job its own writable output and artifact
  directory, the artifacts of earlier phases read-only under `$CICD_INPUTS`. Every entry
  point — the native runner, the polling daemon, the composite action, the dispatcher with
  its worker — runs the same executor and must keep running it. A change there is
  user-visible: `Changes` entry plus test. Details: skill `simpici-core`.
- **The sharp edge is the trust boundary.** Phase selection is no authorization; untrusted
  candidate code can bring its own publish job. Admission and credential authorization belong
  before the executor starts, never in a guard the job code controls.
- **A new dependency needs a real justification.**
