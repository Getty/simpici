# SimpiCI

SimpiCI is a small Git-aware CI daemon written in Perl. The repository is named
`simpici`; the daemon remains `simpicid`, and the optional operator CLI is
`simpici`.

Keep the product deliberately smaller than a CI platform: sources normalize
events, each accepted run checks out one exact commit, and the runner discovers
top-level `.cicd/*.sh` jobs. Their filenames select a container image and one of
six ordered phases; scripts in a phase run concurrently. Build and release
policy stays in those scripts, never in a workflow DSL or service config.

The canonical project constraints and vocabulary live in the `simpici-core`
skill. Shared Getty Perl and Git conventions are linked into `.agents/skills/`
with `manage-skills`; do not replace those links with copied files. Before
editing any linked skill, load `manage-skills` and preserve its inode.

Use `prove -lr t/` for the development test suite and `dzil test` for the
release-time equivalent. Prefer narrow modules with explicit filesystem
boundaries, and test crash recovery, deduplication and path validation as
observable behavior.
