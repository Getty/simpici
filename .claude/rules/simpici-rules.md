# SimpiCI House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution over
speed on non-trivial work; use judgment on trivial tasks. Skill content is never restated
here: the skills are the source, the agents get them force-loaded via `briefing.skills`.

## Engineering discipline

1. **Think before coding** — State assumptions, ask rather than guess, push back when a
   simpler approach exists, stop when confused and name what is unclear.
2. **Simplicity first** — Minimum code that solves the problem, nothing speculative. A new
   dependency needs a real justification.
3. **Surgical changes** — Touch only what you must; don't improve adjacent code, comments
   or formatting. Match the existing layout.
4. **Tests verify intent, not just behavior** — Reproduce a bug before fixing it, leave a
   regression test behind. A test that can't fail when the contract changes is no test.
5. **Match the codebase's conventions, even if you disagree** — Conformance > taste.
   Surface a harmful convention; don't fork silently.
6. **Fail loud** — "Done" is wrong if anything was skipped silently. Surface uncertainty,
   don't hide it.
7. **A red test is a claim before it is a failure** — Before changing code to turn a test
   green, say what it asserts and whether your fix keeps that claim or replaces it.

## Delegation

If you can spawn subagents (orchestrating main agent): do NOT touch behavior-relevant code
yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run tests, edit
non-behavioral docs. You get no briefing — the classification is too subtle for that.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `simpici-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `simpici-release-manager` |

If you ARE a `simpici-*` agent, the delegation lock does not apply — implement,
refactor, debug and test per these rules.

Behavior-relevant = anything under `lib/`, the tests under `t/`, the programs in `bin/`, the
job contract and the admission and secret boundaries. `docs/`, `README.md`, `Changes` are not.

**Only `simpici-release-manager` commits.** A worker leaves a commit-ready tree and hands
its card to `review`; you then dispatch the release-manager to cut the commit and close
the card.

## The job contract is the product — don't regress it silently

What a caller depends on is the filename grammar `<image>+<phase>[.<job>].sh`, the phases
`prepare`, `build`, `test`, `package`, `publish` and `deploy`, the exit codes of a job
(0 succeeds, 78 skips) and the mounts: the checkout read-only, each job its own writable
output and artifact directory, the artifacts of earlier phases read-only under
`$CICD_INPUTS`. Every entry point — the native runner, the polling daemon, the composite
action, the dispatcher with its worker — runs the same executor and must keep running it.
A change there is user-visible: `Changes` entry plus test. Details: skill `simpici-core`.

The sharp edge is the trust boundary: phase selection is no authorization, untrusted
candidate code can bring its own publish job. Admission and credential authorization
belong before the executor starts, never in a guard the job code controls.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't
invoke the skill first, just use it. Board state lives in `refs/karr/*`.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` — new ticket
- `karr edit ID -a "note"` · `--claim NAME` · `--block "why"` — update
- `karr move ID in-progress --claim NAME` — start · `karr handoff ID --claim NAME --note "…"` — to review
- mutating commands auto-sync; `karr sync --pull|--push` for explicit exchange

Card life cycle: you claim and hand out → the worker notes and ends at `review` → the
release-manager commits and moves it to `done`.

**Serialize board mutations when fanning out.** Collect the results, then loop the
`karr move`/`handoff`/`sync` calls sequentially — N of them landing at once is a resource
event, not a cheap command. Full command surface: skill `kanban-issues-karr-coordination`.

## Release — never without permission

`dzil build` / `dzil test` / `prove -lr t/` are fine anytime. `dzil release` and any CPAN
upload are STRICTLY forbidden without the maintainer's explicit go-ahead — even if a plan
lists "release" as the next step. Stop and ask. No push, no tag. The same holds for the
images this repository builds: the publish job and the dispatcher image go out only on the
maintainer's go-ahead. A local build is fine.

## Public issues — never act without instruction

`karr` is the internal agent board, churned freely. The GitHub and Forgejo issue trackers
carry real people's reports, written under the maintainer's account. Never act on a public
issue on your own initiative — not even to read it. A finding from the outside world
becomes an internal card; the dispatching agent files it.
