# SimpiCI

**A filename. A container. A shell script. Your CI.**

SimpiCI is a small Git-aware CI runner for people who want to understand their
builds without learning another pipeline language.

```text
.cicd/
├── linux+prepare.lint.sh      → first: lint shell scripts
├── perl+5.40+test.sh          → then: test on Perl 5.40
├── perl+5.42+test.sh          → alongside it: test on Perl 5.42
└── linux+package.archive.sh  → finally: create an archive
```

The filename selects the image, phase and job. The contents are your ordinary
shell script. No build-step YAML, matrix language or template inheritance.
GitHub and Forgejo need only a small workflow to get started; the native
**`simpicid`** can poll repositories instead.

> **Current status:** The executor, native CLI, polling daemon, SSH worker and
> GitHub/Forgejo action are available. Automatic branch-protection checks and
> `.cicd/policy.json` are **agreed designs, not implemented features**.
> Adding that file does not protect a run today.

**Get started:** [Quickstart](#quickstart) · [GitHub](#github) · [Native daemon](#native-daemon)

**Explore:** [Jobs and phases](#jobs-and-phases) · [Recipes](#recipes) ·
[Providers](#providers) · [Branch protection](#branch-protection-and-policy) ·
[Operations](deploy/README.md)

## Choose your entry point

| You want to … | Use … | What happens? |
| --- | --- | --- |
| Try `.cicd` in your current checkout | `simpici-executor` | Runs jobs from the existing working directory. |
| Build a specific Git commit | `simpici --event …` | Creates a fresh, exact checkout and a native report. |
| Run your own CI without hosted Actions | `simpicid --config …` | Polls configured refs and builds new revisions. |
| Use GitHub or Forgejo Actions | The composite action | Uses the hosted runner's checkout and infrastructure. |
| Build on a separate VM | Dispatcher + `simpici-worker` | Persists jobs; the worker retrieves them over restricted SSH. |

**Same job contract, different infrastructure:** Every entry point uses the
same shell executor. Hosted runs do not automatically have the native store,
its deduplication or its static reports.

The native service is **Perl**; the container executor is **Bash**. Your jobs
can use any language for which you have a suitable container image.

## Quickstart

### 1. Add your first job

In the existing Git repository you want to build, with at least one commit:

```sh
mkdir -p .cicd
cat > .cicd/linux+test.smoke.sh <<'JOB'
#!/bin/sh
set -eu
printf 'Building commit %s\n' "$CICD_COMMIT"
test -e "$CICD_WORKSPACE/.git"
printf 'Checkout is available.\n'
JOB
chmod +x .cicd/linux+test.smoke.sh
```

`linux` is an alias for `docker.io/library/debian:latest`. `test` is the phase;
`smoke` is your chosen job name. Replace the script body with your project's
actual tests when you are ready.

### 2. Plan and run locally

The host needs Bash 4.3 or newer, Git and standard Unix tools. Actual jobs also
need the Docker CLI and access to a Docker daemon. Clone SimpiCI once into a
separate directory, for example:

```sh
SIMPICI_TOOLS="$HOME/src/simpici"
git clone https://github.com/Getty/simpici.git "$SIMPICI_TOOLS"
```

Still from the root of the repository you want to build:

```sh
# Show the plan only; explicitly disable providers.
CICD_SOURCE=manual CICD_COMMIT="$(git rev-parse HEAD)" \
CICD_WORKSPACE="$PWD" SIMPICI_PROVIDERS='' SIMPICI_PLAN_ONLY=true \
  "$SIMPICI_TOOLS/bin/simpici-executor"

# Run the jobs in Docker.
CICD_SOURCE=manual CICD_COMMIT="$(git rev-parse HEAD)" \
CICD_WORKSPACE="$PWD" SIMPICI_PROVIDERS='' SIMPICI_CONCURRENCY=2 \
  "$SIMPICI_TOOLS/bin/simpici-executor"
```

**Important:** `SIMPICI_PLAN_ONLY=true` does not prevent configured providers
from running. A container-free plan must also set `SIMPICI_PROVIDERS=''`.

The direct executor uses your existing checkout, including local changes.
For a fresh checkout of an exact commit, use the [native CLI](#build-one-commit).
Remote builds require you to commit and push the jobs with their executable
bits set.

## GitHub

### CI without publishing credentials

Add `.github/workflows/ci.yml` to the target repository:

```yaml
name: CI
on:
  push:
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          persist-credentials: false
      - uses: Getty/simpici/action@main
        env:
          SIMPICI_CONCURRENCY: "2"
```

The action executes the checked-out repository's `.cicd` jobs. It does not
install persistent runner infrastructure for you. The `@main` references are
convenient for trying it out; pin actions to reviewed commit SHAs for controlled
updates.

**Fork PRs need disposable, isolated runners.** Jobs are executable code.
Build and publish jobs receive an available Docker socket, so a read-only
checkout is not a security boundary around the runner host. Do not run
untrusted PRs on a persistent VM with production access.

### The bundled reusable workflow

For **trusted pushes** that need registry access, there is also this entry
point:

```yaml
name: Release CI
on:
  push:
    branches: [main]

jobs:
  simpici:
    permissions:
      contents: read
      packages: write
    uses: Getty/simpici/.github/workflows/simpici.yml@main
    with:
      concurrency: "2"
```

This workflow supplies the GitHub token as a GHCR credential. It is not an
implementation of SimpiCI's planned branch policy. For tests alone, the first
example grants fewer permissions.

## Jobs and phases

### A filename defines a job

```text
<image>+<phase>[.<job>].sh
```

| File | Image | Phase | Job |
| --- | --- | --- | --- |
| `linux+prepare.lint.sh` | `docker.io/library/debian:latest` | `prepare` | `lint` |
| `perl+5.40+test.sh` | `docker.io/library/perl:5.40` | `test` | `perl+5.40` |
| `node+22+test.frontend.sh` | `docker.io/library/node:22` | `test` | `frontend` |
| `application+dingens+13+build.sh` | `docker.io/application/dingens:13` | `build` | `application+dingens+13` |
| `ghcr.io+acme+builder+3+package.tar.sh` | `ghcr.io/acme/builder:3` | `package` | `tar` |

A `+` separates image components because `/` cannot be part of a filename.
Short aliases such as `linux`, `perl`, `node` and `python` are supported.
Explicit version tags give you more control, but registry tags are still
mutable and do not guarantee reproducible images.

**Job names must be unique within a phase**, even across different images.
For a version matrix, leaving out the explicit job name is particularly handy:

```sh
cp .cicd/perl+5.40+test.sh .cicd/perl+5.42+test.sh
```

### Six phases, one fixed order

```text
prepare → build → test → package → publish → deploy
```

- By default, at most **two jobs run concurrently** within a phase.
- `SIMPICI_CONCURRENCY` changes the limit; `1` runs jobs serially.
- The next phase starts only after the current phase has finished.
- Exit **0** means success, **78** means deliberately skipped; any other exit
  code fails the phase and prevents later phases from starting.
- All jobs in the current phase still run. Failures are evaluated after the
  entire phase batch, not as an immediate fail-fast interruption.

The image must provide the interpreter named in the shebang. SimpiCI executes
the executable script directly; it does not install Bash into an Alpine image
or automatically override the image's `ENTRYPOINT`.

### Read here, write there

| Location | Contract |
| --- | --- |
| `$CICD_WORKSPACE` | Read-only checkout; also the job's working directory |
| `$CICD_ROOT` | Effective `.cicd` job plan, including provider files |
| `$CICD_OUTPUT` | This job's private, writable working directory |
| `$CICD_ARTIFACTS` | This job's private, writable artifact directory |

Many tools write into the project directory. Before running `npm ci`,
`cargo test`, `dzil test` or similar commands, copy the checkout:

```sh
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
```

**Output and artifacts are currently private to each job.** A `deploy` job
does not automatically see a previous `package` job's artifacts. Automatic
uploads and artifact transfer between worker and dispatcher are not available
either. Keep `RUNNER_TEMP` and `TMPDIR` outside the checkout so copies and
archives do not accidentally include their own temporary output.

See the [executor reference](docs/executor.md) for job variables, executor
settings and status details.

## Recipes

Each example is a complete file. Remember to run `chmod +x` afterwards.
The versions are examples, not a list of built-in toolchains.

### Node: install dependencies and run tests

File: `.cicd/node+22+test.sh`. Requires `package-lock.json` and a `test` script
in `package.json`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
npm ci
npm test
```

For a second Node version, copy the file to `.cicd/node+24+test.sh`.
That is the entire matrix.

### Perl: CPAN dependencies and tests

File: `.cicd/perl+5.40+test.sh`. Requires a dependency description supported by
`cpanm`, such as `cpanfile`, and tests under `t/`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
cpanm --installdeps --notest .
prove -lr t/
```

### Save a source archive

File: `.cicd/linux+package.source.sh`.

```sh
#!/bin/sh
set -eu
tar --exclude=./.git -czf "$CICD_ARTIFACTS/source.tar.gz" \
  -C "$CICD_WORKSPACE" .
```

The file ends up in **this job's** artifact directory. This example deliberately
does not promise an automatic download link or access from another job.

### Deliberately skip a job

```sh
#!/bin/sh
set -eu
[ "$CICD_EVENT" = push ] || exit 78
[ "$CICD_REF" = refs/heads/main ] || exit 78
printf 'This step is intended only for pushes to main.\n'
```

This is a decision made by the script, **not access control**. An untrusted
script could remove the guard. The trusted entry point must restrict
credentials independently.

**More complete examples:** [Python, Rust, Go, Ruby, shell linting,
container builds/publishing and a custom provider](docs/cookbook.md).

## Providers

An organization can generate jobs from its own OCI image instead of copying
the same scripts into many repositories:

```sh
CICD_WORKSPACE="$PWD" \
SIMPICI_PROVIDERS='ghcr.io/acme/simpici-provider:1' \
  "$SIMPICI_TOOLS/bin/simpici-executor"
```

Replace the example image with your own provider. Set the same environment
variable when using the GitHub composite action; the reusable workflow exposes
it as the `provider` input.

The provider writes ordinary jobs to `$CICD_PROVIDER_OUT`. It receives a
read-only checkout and its own writable directory, but no registry credentials
or Docker socket. Merge precedence is:

1. Repository files win.
2. Earlier providers win over later providers.
3. A provider may add to the repository's CI, not replace existing files.

Separate multiple providers with whitespace. A failed provider fails
preparation. Providers must run even in plan-only mode so their jobs can
be discovered.

**Providers are trusted executable code**, not a safe plugin sandbox.
SimpiCI enforces neither organizational ownership nor digest pinning.
Use reviewed images, preferably pinned by digest, and update them deliberately.
A moving `:main` tag is not a pin.

An external example is the
[Getty Dist::Zilla bundle's provider](https://github.com/Getty/p5-dist-zilla-pluginbundle-author-getty/tree/main/simpici-provider).
That project documents its supported Perl versions and prerequisites;
SimpiCI itself has no Dist::Zilla-specific matrix.

## Native daemon

You do not need a hosted CI service. `simpicid` polls the refs you choose,
detects new revisions and builds them using the shared executor.

From a SimpiCI checkout, with Perl and `cpanm` installed on the host:

```sh
cpanm --installdeps .
```

Create a configuration such as `simpici.json`:

```json
{
  "root": "./var",
  "interval": 60,
  "timeout": 900,
  "repositories": [
    {
      "name": "acme/example",
      "clone_url": "https://github.com/acme/example.git",
      "refs": ["refs/heads/main"],
      "build_initial": true
    }
  ]
}
```

Replace the name and clone URL with your repository. Its `.cicd` files must
already be committed. This example uses only settings supported today.

```sh
# Poll once, including a build of the existing branch tip.
perl -Ilib bin/simpicid --config simpici.json --once

# Keep polling.
perl -Ilib bin/simpicid --config simpici.json
```

- `build_initial: false` records the existing state on the first poll without
  building it.
- `refs` is the **polling filter**, not global authorization for other entry
  points such as the one-shot CLI.
- `timeout` limits the native executor's runtime.
- Polling remembers the last observed tip of each ref. In local mode, a change
  from `A → B → A` can build the same commit again; the dispatcher queue
  provides durable repository/ref/commit deduplication.
- `--once` ends a polling cycle. Its exit code does not replace the build
  status in the run report.

More templates: [local mode](etc/simpici.example.json) and
[dispatcher with secret grants](etc/simpici.dispatcher.example.json).
The local template builds SimpiCI itself. Its container jobs also require an
image target such as `CICD_IMAGE_REPOSITORY=simpici-local`; for a local test
where publishing is not wanted, also set `CICD_PUBLISH_IMAGE=false`.
This is a convention of those repository scripts, not a security boundary.

### Build one commit

`simpici` expects a normalized event, not just a local path:

```sh
perl -Ilib bin/simpici --event event.json --root var
```

Required event fields are `source`, `event`, `repository`, `clone_url`, `ref`
and `commit`. The commit must be a full lowercase 40- or 64-character hex OID;
the ref must be canonical, such as `refs/heads/main`.
The [operations guide](deploy/README.md) includes an example that generates
an event file.

The one-shot CLI is a trusted operator entry point. It does not automatically
read the daemon configuration or enforce its ref filters. It is not a
replacement for the dispatcher's queue/retry semantics either.

### Separate build VM and reports

For a separate build machine, `simpicid` uses `dispatcher` mode. The worker
retrieves jobs over a restricted outbound SSH connection.
[Keys, grants, mounts and recovery](deploy/README.md) belong in the operations
guide, not in build scripts.

Native runs write public report JSON and logs under `<root>/public/`.
**Local logs are not automatically redacted.** Review their contents before
publishing them. Only the worker/dispatcher path redacts secret values assigned
by the dispatcher.

The bundled `compose.yaml` is an **optional viewer example using a Podman
socket**, not a complete daemon stack. It requires, among other things,
`${XDG_RUNTIME_DIR}/podman/podman.sock`, suitable mounts and read access for
the web server. Once those are configured:

```sh
docker compose up -d
```

The viewer is then available at <http://127.0.0.1:8080/>. See the
[operations guide](deploy/README.md) for mounts, private file permissions and
alternatives. Hosted runs do not appear there automatically. Never publish
internal events, queue data, credentials or checkouts alongside reports.

## Forgejo and GitLab

**Forgejo Actions** can invoke the same composite action. A complete example
and runner requirements are in the [operations guide](deploy/README.md).
On a persistent self-hosted VM in particular, do not give untrusted PRs access
to Docker or production networks.

**GitLab repositories** can already be built by the native daemon using their
Git clone URL. This does not mean a dedicated GitLab hosted entry point or
automatic branch-protection queries are implemented. An accessible Git server
alone does not provide branch-protection metadata.

## Branch protection and policy

The following table describes the **agreed target semantics**, not current
runtime behavior:

| Metadata state | Intended default |
| --- | --- |
| No protected branches | Observed branches are treated equally; no mandatory policy. |
| Protected branches exist | Without an additional policy, only protected branches run. |
| Valid policy on the protected default branch | May admit additional branches. |
| Protection status unknown or query failed | No silent switch to unprotected mode. |

The repository-wide policy is to come from the default branch. When branch
protection is used, that branch must also be protected. Multiple protected
branches do not mean "the newest wins"; no `policy_branch` setting is planned.

Static branch metadata, forge adapters and a trusted JSON URL are proposed
alternative sources for the native daemon. The new settings are **not yet
available**. The [architecture decision](docs/superpowers/specs/2026-09-21-branch-policy-design.md)
distinguishes agreed decisions from proposed extensions.

## Development

```sh
prove -lr t/
```

Before a release, also run:

```sh
dzil test
```

`prove` is the normal development path; release tests require Dist::Zilla
and the distribution's dependencies. CLI help is available directly from
a checkout:

```sh
perl -Ilib bin/simpicid --help
perl -Ilib bin/simpici --help
```

The internals are deliberately small: event normalization, filesystem store,
polling and runner, with an optional queue, dispatcher and worker. POD in
`lib/SimpiCI/` documents the Perl interfaces.

## Links and license

- [GitHub](https://github.com/Getty/simpici)
- [Forgejo](https://src.ci/cindustries/simpici)
- Container images: `raudssus/simpici` and `ghcr.io/getty/simpici`
- [Deployment](deploy/README.md) · [Cookbook](docs/cookbook.md)

Copyright 2026 Torsten Raudssus. SimpiCI is available under the same terms as
Perl itself. See [LICENSE](LICENSE).
