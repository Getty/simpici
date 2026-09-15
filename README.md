# SimpiCI

SimpiCI is a small Git-aware CI runner. A repository describes its jobs with
ordinary executable files in `.cicd/`; their filenames select the container
image, phase, and job name. There is no workflow DSL, build-step YAML, matrix
language, or central build configuration.

## Use it on GitHub

Add `.github/workflows/ci.yml` to the repository you want to build:

```yaml
name: CI

on:
  push:
  pull_request:

# Cancel a branch's older, still-running CI when you push again — SimpiCI runs a
# whole matrix inside one job, so superseded runs are worth cancelling. Left off
# for main so every landed commit keeps its own result.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

jobs:
  simpici:
    permissions:
      contents: read
      packages: write
    uses: Getty/simpici/.github/workflows/simpici.yml@main
    # with:
    #   provider: ghcr.io/your-org/your-provider:main  # generate jobs (see Providers)
    #   concurrency: "2"                                 # jobs at once per phase (default 2)
```

Then add executable jobs to `.cicd/`:

```text
.cicd/
├── perl+5.40+test.unit.sh
├── docker+27+build.image.sh
└── docker+27+publish.image.sh
```

That is the complete GitHub setup. The reusable workflow checks out the exact
revision, calls the SimpiCI action, and may publish to
`ghcr.io/<owner>/<repository>` using GitHub's short-lived token.

## Job filenames

The grammar is:

```text
<image>+<phase>[.<job>].sh
```

The fixed phase order is `prepare`, `build`, `test`, `package`, `publish`, and
`deploy`. All jobs in one phase run concurrently. The next phase starts only
after the whole current phase succeeded or skipped. Exit status 0 succeeds, 78
skips, and every other status fails the phase and prevents later phases.

Image components are separated with `+` because `/` and `:` are unsuitable in
filenames:

| Filename prefix | Container image |
|---|---|
| `linux` | `docker.io/library/debian:latest` |
| `perl` | `docker.io/library/perl:latest` |
| `perl+5.40` | `docker.io/library/perl:5.40` |
| `application+dingens+13` | `docker.io/application/dingens:13` |
| `ghcr.io+application+dingens+13` | `ghcr.io/application/dingens:13` |

The optional suffix after the phase is the job identity. For example,
`perl+5.40+test.unit.sh` is job `unit` in the test phase. Without that suffix,
the image expression becomes the identity.

Each job receives the checkout read-only at `CICD_WORKSPACE`, plus private
writable `CICD_OUTPUT` and `CICD_ARTIFACTS` directories. Registry credentials
are exposed only during `publish` and `deploy`. Build and publish jobs also
receive the host's Docker socket when one is available.

## Environment passed to jobs

Every job receives:

| Variable | Meaning |
|---|---|
| `CICD_RUN_NUMBER` | Numeric/native or hosted run identifier |
| `CICD_SOURCE` | Event source such as `git-poll` or `github-actions` |
| `CICD_EVENT` | Event type such as `push` or `pull_request` |
| `CICD_REPOSITORY` | Repository identity |
| `CICD_CLONE_URL` | Source clone URL |
| `CICD_REF` | Canonical `refs/...` name |
| `CICD_BRANCH` / `CICD_TAG` | Derived branch or tag, otherwise empty |
| `CICD_COMMIT` | Exact commit object ID |
| `CICD_PHASE` / `CICD_JOB` | Parsed job coordinates |
| `CICD_IMAGE_REF` | Resolved container image |
| `CICD_EVENT_FILE` | Normalized event JSON |
| `CICD_ROOT` | Repository `.cicd` directory |
| `CICD_OUTPUT` | Writable job output directory |
| `CICD_ARTIFACTS` | Writable job artifact directory |

Publish and deploy jobs additionally receive `CICD_REGISTRY`,
`CICD_REGISTRY_USER`, `CICD_REGISTRY_PASSWORD`, and `CICD_PUBLISH_IMAGE`.

## The read-only workspace

Every job runs with the checkout mounted **read-only** at `CICD_WORKSPACE`
(which is also the working directory). Anything a job needs to write goes into
the private, writable `CICD_OUTPUT`, or into `CICD_ARTIFACTS` for files worth
keeping. Tools that build in-tree — `npm ci`, `cargo build`, `pip install -e .`,
`dzil test` — copy the checkout out first:

```sh
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
# ...build and test here, in a writable tree...
```

Read-only-friendly commands — `prove -lr t/` with dependencies already
installed, a linter that only reads, `go test ./...` (its cache lives in
`$HOME`) — can run in place against `$CICD_WORKSPACE`.

## Cookbook

Each block is a complete `.cicd/<name>` file. The filename selects the image
and phase; the body is ordinary shell. Copy a file once per image to get a
matrix — the image expression keeps the job names distinct, so no `.job` suffix
is needed.

**Perl — unit tests** — `.cicd/perl+5.40+test.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
cpanm --installdeps --notest "$CICD_WORKSPACE"
prove -lr "$CICD_WORKSPACE/t"
```

For an `[@Author::GETTY]` distribution, don't hand-write this — use the
[provider](#providers) below, which runs a full `dzil test` on every supported
Perl with no `.cicd` at all.

**Node — a version matrix** — `.cicd/node+20+test.sh` and `.cicd/node+22+test.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
npm ci
npm test
```

**Python — pytest** — `.cicd/python+3.12+test.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
pip install --quiet -e '.[test]'
pytest -q
```

**Rust — test, clippy and fmt as three jobs on one image** —
`.cicd/rust+1.81+test.sh`, `.cicd/rust+1.81+test.clippy.sh`,
`.cicd/rust+1.81+test.fmt.sh`

```sh
# rust+1.81+test.sh
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"; cd "$CICD_OUTPUT/src"
cargo test --locked
```

```sh
# rust+1.81+test.clippy.sh
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"; cd "$CICD_OUTPUT/src"
cargo clippy --all-targets -- -D warnings
```

```sh
# rust+1.81+test.fmt.sh — reads only, so it runs in place
#!/usr/bin/env bash
set -euo pipefail
cd "$CICD_WORKSPACE"
cargo fmt --check
```

Here the explicit `.clippy` / `.fmt` suffixes matter: all three share the image
`rust+1.81`, so without distinct job names they would collide.

**Go — vet and test** — `.cicd/golang+1.23+test.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$CICD_WORKSPACE"
go vet ./...
go test ./...
```

**Shell lint in an earlier phase** — `.cicd/linux+prepare.lint.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
apt-get update -qq && apt-get install -y -qq shellcheck
shellcheck "$CICD_WORKSPACE"/.cicd/*.sh
```

Because it is in the `prepare` phase, it runs (and must pass) before any `test`
job starts.

**Build and publish a container** — `.cicd/docker+27+build.image.sh` and
`.cicd/docker+27+publish.image.sh`

```sh
# docker+27+build.image.sh
#!/usr/bin/env bash
set -euo pipefail
image="$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
docker build --tag "$image:$CICD_COMMIT" "$CICD_WORKSPACE"
```

```sh
# docker+27+publish.image.sh
#!/usr/bin/env bash
set -euo pipefail
# Skip (exit 78) unless this run is allowed to publish and has credentials.
[ "${CICD_PUBLISH_IMAGE:-false}" = true ] || exit 78
[ -n "${CICD_REGISTRY_USER:-}" ] && [ -n "${CICD_REGISTRY_PASSWORD:-}" ] || exit 78
image="$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
printf '%s' "$CICD_REGISTRY_PASSWORD" \
  | docker login "$CICD_REGISTRY" -u "$CICD_REGISTRY_USER" --password-stdin
docker push "$image:$CICD_COMMIT"
[ "$CICD_REF" = refs/heads/main ] && docker tag "$image:$CICD_COMMIT" "$image:latest" && docker push "$image:latest"
```

`build` runs before `publish`, and only `publish`/`deploy` jobs ever receive
registry credentials — so a pull request builds the image and cleanly skips the
push.

## Providers

A **provider** lets a job list come from a program instead of only from files in
the checkout — without turning `.cicd` into a matrix language. A provider is a
**pinned, org-owned OCI image** that SimpiCI runs once, read-only over the
checkout, with its own private writable directory. It writes ordinary
`<image>+<phase>[.<job>].sh` files there, and SimpiCI merges them into the
effective `.cicd` **without overwriting a name the repository already ships** —
so your own files always win.

Select providers from the workflow:

```yaml
jobs:
  simpici:
    permissions:
      contents: read
      packages: write
    uses: Getty/simpici/.github/workflows/simpici.yml@main
    with:
      provider: ghcr.io/acme/simpici-provider:main
```

`provider` is a whitespace-separated list; earlier entries win a collision
(after the repository's own files).

**The contract.** SimpiCI runs each provider as:

```console
docker run --rm --workdir /workspace \
  -v <checkout>:/workspace:ro \
  -v <event>:/run/simpici/event.json:ro \
  -v <private>:/cicd-out \
  -e CICD_PROVIDER_OUT=/cicd-out \
  -e CICD_WORKSPACE=/workspace -e CICD_EVENT_FILE=/run/simpici/event.json \
  -e CICD_SOURCE -e CICD_EVENT -e CICD_REPOSITORY \
  -e CICD_REF -e CICD_BRANCH -e CICD_TAG -e CICD_COMMIT \
  <image> /run/simpici/event.json
```

The provider writes executable `.sh` job files (and optional `lib/` helpers)
into `$CICD_PROVIDER_OUT`. It gets **no registry credentials and no Docker
socket**, and `/workspace` is read-only: a provider plans work, it does not do
it. A non-zero exit fails the run.

**Trust.** Providers are pinned and org-owned — you run your own code, so there
is no third-party supply chain and no plugin marketplace. Writing your own
company provider, encoding "what to test and where" once for a whole fleet of
repositories, is the intended use.

**A minimal provider** — an image whose entrypoint emits one job:

```sh
#!/bin/sh
set -eu
: "${CICD_PROVIDER_OUT:?run me from SimpiCI}"
cat > "$CICD_PROVIDER_OUT/node+22+test.sh" <<'JOB'
#!/usr/bin/env bash
set -euo pipefail
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"; cd "$CICD_OUTPUT/src"
npm ci && npm test
JOB
chmod +x "$CICD_PROVIDER_OUT/node+22+test.sh"
```

**A real one** ships with the `[@Author::GETTY]` Dist::Zilla plugin bundle:
[`ghcr.io/getty/simpici-dzil-provider`](https://github.com/Getty/p5-dist-zilla-pluginbundle-author-getty/tree/main/simpici-provider).
A Perl distribution adds the workflow with `provider:
ghcr.io/getty/simpici-dzil-provider:main`, commits **no `.cicd`**, and gets a
full `dzil test` on every Perl version the bundle supports.

## What would it look like as SimpiCI?

A quick translation of shapes you already recognize — the point is how little
there is to write.

- **A Node library with a 18/20/22 Jest matrix.** Three files:
  `node+18+test.sh`, `node+20+test.sh`, `node+22+test.sh`, each `npm ci &&
  npm test`. No `strategy.matrix`, no `setup-node`.
- **A Python package tested on 3.10–3.12 with a lint gate.** One
  `linux+prepare.lint.sh` (ruff), then `python+3.10+test.sh` …
  `python+3.12+test.sh`. Lint runs first because `prepare` precedes `test`.
- **A Rust crate.** `rust+1.81+test.sh`, `+test.clippy.sh`, `+test.fmt.sh` —
  three checks, one toolchain image, run in parallel.
- **A Go microservice that ships an image.** `golang+1.23+test.sh`, then
  `docker+27+build.image.sh` and `docker+27+publish.image.sh`. The push skips
  itself on pull requests.
- **A Perl CPAN distribution.** Nothing in `.cicd` at all — just the workflow
  and `provider: ghcr.io/getty/simpici-dzil-provider:main`.
- **A static site.** `linux+build.site.sh` writes the built site to
  `$CICD_ARTIFACTS`; a `deploy` job rsyncs it.

Every one of these runs **identically** from `bin/simpici` on your laptop, from
the polling daemon, and from GitHub or Forgejo Actions — same files, same
containers, same result.

## Forgejo

Forgejo Actions uses the same composite action and `.cicd` contract. Check out
the repository and invoke either a locally vendored `./action` or the fully
qualified SimpiCI action URL. Registry credentials remain workflow inputs; the
repository scripts retain all publish policy.

## Run the polling daemon

Pull the ready-to-run image from Docker Hub (primary) or GHCR (mirror):

```console
docker pull raudssus/simpici
docker pull ghcr.io/getty/simpici
```

Create a configuration based on `etc/simpici.example.json`, then mount it with
a persistent private state directory and the Docker socket:

```console
docker run --rm \
  -v "$PWD/simpici.json:/etc/simpici.json:ro" \
  -v "$PWD/var:/var/lib/simpici" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  raudssus/simpici \
  --config /etc/simpici.json
```

Set `root` to `/var/lib/simpici` in that configuration. Use `--once` for one
polling cycle. `simpicid --help` and `simpicid --man` document all command
options.

For a source checkout, the equivalent commands are:

```console
perl -Ilib bin/simpicid --config etc/simpici.example.json --once
perl -Ilib bin/simpicid --config etc/simpici.example.json
```

## Run one event

The trusted one-shot command accepts a normalized event JSON document:

```console
perl -Ilib bin/simpici --event event.json --root var
```

Required event fields are `source`, `event`, `repository`, `clone_url`, `ref`,
and a full 40- or 64-character hexadecimal `commit`. `simpici --help` and
`simpici --man` describe timeout and executor overrides. A source checkout uses
`bin/simpici-executor`; an installed distribution finds `simpici-executor` on
`PATH`.

## Perl API

The public modules and methods are:

- `SimpiCI::Event->new(...)` validates a normalized event.
- `$event->deduplication_key` returns the stable SHA-256 key for repository,
  ref, and commit.
- `$event->as_hash` and `$event->as_json` return deterministic copies.
- `SimpiCI::Store->new(root => $path)` creates a private filesystem store.
- `$store->prepare` creates its required directory layout.
- `$store->allocate_run` atomically allocates a monotonically increasing run.
- `$store->write_json($relative, $value)` atomically publishes JSON beneath the
  store root and rejects escaping paths.
- `SimpiCI::Runner->new(store => $store, timeout => $seconds,
  runner_script => $path)` creates the exact-checkout runner.
- `$runner->run($event)` executes the event and returns its sanitized report.
- `SimpiCI::Source::GitPoll->new(store => ..., runner => ..., repository =>
  ...)->poll` checks configured refs once and returns generated run reports.
- `SimpiCI::App::Run->run(@arguments)` implements the `simpici` command.
- `SimpiCI::App::Eventd->run(@arguments)` implements the `simpicid` daemon.

Only those methods are public. Methods beginning with `_` are implementation
details.

## Static reports

SimpiCI writes sanitized reports and logs below the store's `public/` tree.
Serve the bundled viewer locally through Traefik and nginx:

```console
docker compose up -d
```

It is then available at <http://127.0.0.1:8080/>. Queue state, checkouts,
credentials, and raw internal payloads remain outside the public tree.

## Development

```console
prove -lr t/
```

Release validation uses `dzil test`; ordinary development does not require a
CPAN release toolchain.

Installing the distribution also installs `simpici-executor`. The hosted
action delegates to that same executable, so native and hosted runs cannot
silently acquire different planning behavior.

## Images and links

- Docker Hub: `raudssus/simpici`
- GitHub Container Registry: `ghcr.io/getty/simpici`
- GitHub: <https://github.com/Getty/simpici>
- Forgejo: <https://src.ci/cindustries/simpici>

The repository's own Docker Hub mirror uses the `DOCKERHUB_TOKEN` GitHub
Actions secret. The public account name is fixed to `raudssus` in its CI
workflow.

## Where SimpiCI fits

SimpiCI is aimed at people and organizations who maintain **many repositories,
across many languages,** and are tired of copying YAML between them. Its bet is
that a CI job is nothing more than *a container plus a shell script*, so:

- **The same run everywhere.** `bin/simpici` on your laptop, the polling daemon
  on a box you own, and GitHub or Forgejo Actions all execute the identical
  `.cicd` files in the identical containers. There is no "works locally, breaks
  in CI."
- **No language lock-in.** Because a job just names an image, every ecosystem
  with a public image already works — the cookbook above spans Perl, Node,
  Python, Rust, Go, Ruby and Docker and SimpiCI knows none of them specifically.
- **House conventions live in one place.** A [provider](#providers) encodes
  "how we test our Perl dists" (or Go services, or Node libraries) once, as an
  org-owned image. Change how the whole fleet is tested by republishing the
  provider — not by editing a workflow in every repository.

The ideal end state is a repository whose entire CI is one small workflow that
says *"run my `.cicd`, plus my organization's provider,"* and nothing more —
while a repository that needs something unusual just drops another `.sh` file
next to the rest and it runs.

What SimpiCI deliberately is **not**: a matrix or templating DSL, a plugin
marketplace, or a Kubernetes-native pipeline engine. Simple things stay simple
(a filename and a shell script); complex things stay possible (phases, skips,
and providers) — without a configuration language in between.

## License

Copyright 2026 Torsten Raudssus. SimpiCI is available under the same terms as
Perl itself.

## Distributed dispatcher and runner

For an isolated build host, set `mode: dispatcher` in the daemon configuration.
The daemon persists deduplicated jobs; `simpici-worker` pulls them through a
restricted outbound SSH connection and executes the shared container phases.
See [deployment instructions](deploy/README.md) and
[example configuration](etc/simpici.dispatcher.example.json) for worker keys,
VM network isolation, scoped secret files, mirrors and recovery semantics.
Windows/native jobs are not part of this execution model.
