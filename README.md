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

jobs:
  simpici:
    permissions:
      contents: read
      packages: write
    uses: Getty/simpici/.github/workflows/simpici.yml@main
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

## License

Copyright 2026 Torsten Raudssus. SimpiCI is available under the same terms as
Perl itself.
