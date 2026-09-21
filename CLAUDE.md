# SimpiCI

SimpiCI is a small Git-aware CI daemon written in Perl. The repository is named
`simpici`; the daemon remains `simpicid`, and the optional operator CLI is
`simpici`.

The native event boundary normalizes polling, webhook and manual input; the
daemon currently implements Git polling, not a webhook HTTP server. The native
runner checks out an exact commit and executes top-level `.cicd/*.sh` jobs in
filename-selected containers. Six phases and bounded concurrency keep the job
contract small. Durable deduplication belongs to the dispatcher queue, not to
every entry point. Build and release steps stay in repository scripts;
admission and credential authorization must precede untrusted execution.

Use `docs/executor.md` for current runtime behavior and `deploy/README.md` for
operations. Before changing branch admission or metadata sources, read
`docs/superpowers/specs/2026-09-21-branch-policy-design.md`: its policy and
metadata features are not implemented yet.

Keep project instructions in `CLAUDE.md` and agent/skill definitions under
`.claude/` as the single maintained configuration.

Project architecture and invariants live in skill `simpici-core`. Shared Getty
Perl and Git skills under `.claude/skills/` are hardlinked by `manage-skills`.
Before editing a linked skill, load `manage-skills` and preserve its inode;
never use an atomic-save editor or replace hardlinks with copies.

Behavior-relevant implementation, refactoring and tests belong with the
`simpici-worker` agent. Run `prove -lr t/` during development and `dzil test`
before release.
