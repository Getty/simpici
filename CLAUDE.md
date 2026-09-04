# SimpiCI

SimpiCI is a small Git-aware CI daemon written in Perl. The repository is named
`simpici`; the daemon remains `simpicid`, and the optional operator CLI is
`simpici`.

The daemon turns polling, webhook and manual input into one normalized event,
deduplicates it, checks out its exact commit in an isolated workspace and calls
one repository-owned CI/CD script. It does not define build steps or a pipeline
language.

Project architecture and invariants live in skill `simpici-core`. Shared Getty
Perl and Git skills under `.claude/skills/` are hardlinked by `manage-skills`;
never edit them with an atomic-save editor or replace them with copies.

Behavior-relevant implementation, refactoring and tests belong with the
`simpici-worker` agent. Run `prove -lr t/` during development and `dzil test`
before release.

