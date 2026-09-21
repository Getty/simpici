# SimpiCI Cookbook

[Back to README](../README.md) · [Executor reference](executor.md) · [Operations](../deploy/README.md)

A recipe is an executable script in the top-level `.cicd/` directory.
The filename selects the image, phase and job. Replace version numbers and
project-specific commands with suitable values; SimpiCI has no built-in
list of supported language versions.

For all examples:

```sh
chmod +x .cicd/*.sh
```

- The image needs the interpreter named in the shebang. Most examples use
  `/bin/sh`; Bash is not guaranteed to be available in Alpine-based images.
- The checkout is read-only. Build tools that need to write files work on a
  copy in `$CICD_OUTPUT/src`.
- Dependencies are installed within the job. Other jobs do not inherit that
  installation. A custom build image tag can avoid repeated installation,
  but does not replace deliberate version management.
- Output and artifacts are private to each job. They are not automatically
  mounted in a later job.
- Project code and dependency hooks are executable code. Untrusted runs
  need isolated runners without production credentials.

## 1. Node: a small version matrix

Prerequisites: `package-lock.json`, a `test` script and support for the
respective Node version.

File: `.cicd/node+22+test.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
npm ci
npm test
```

A second variant needs no matrix configuration:

```sh
cp .cicd/node+22+test.sh .cicd/node+24+test.sh
```

Without an explicit `.job` suffix, the image expression becomes the job name.
The two tests are therefore named `node+22` and `node+24`, rather than both
being called something like `unit`.

## 2. Python: a package and pytest

Prerequisite: the project defines the `test` extra, including `pytest`.
For a different dependency layout, adjust the installation line accordingly.

File: `.cicd/python+3.13+test.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
python -m pip install -e '.[test]'
python -m pytest -q
```

## 3. Perl: CPAN dependencies and prove

Prerequisites: a dependency description supported by `cpanm`, such as
`cpanfile`, and tests under `t/`.

File: `.cicd/perl+5.40+test.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
cpanm --installdeps --notest .
prove -lr t/
```

A Dist::Zilla project also needs its build/release toolchain.
`prove` does not install a plugin bundle. For an organization-wide
Dist::Zilla matrix, a custom provider may be more suitable than copied jobs.

## 4. Rust: tests and lint as separate jobs

Prerequisites: `Cargo.toml`, `Cargo.lock` and a toolchain that matches the
selected Rust version.

File: `.cicd/rust+1.89+test.unit.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
cargo test --locked
```

File: `.cicd/rust+1.89+test.clippy.sh`.

```sh
#!/bin/sh
set -eu
rustup component add clippy
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
cargo clippy --locked --all-targets -- -D warnings
```

Both run in the test phase under the configured concurrency limit.
`unit` and `clippy` are deliberately different job names. A formatting check
could be added as a third job using `rustup component add rustfmt` and
`cargo fmt --check`.

## 5. Go: vet and test

Prerequisites: a Go module and its matching toolchain.

File: `.cicd/golang+1.25+test.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
go vet ./...
go test ./...
```

The copy also allows tests to create fixtures alongside the source code.
If no write access is needed, a project can choose to test directly in the workspace.

## 6. Ruby: Bundle and Rake

Prerequisites: `Gemfile`, `Gemfile.lock` and a `test` task in the Rakefile.

File: `.cicd/ruby+3.4+test.sh`.

```sh
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
bundle install
bundle exec rake test
```

## 7. Shell lint as a preliminary check

File: `.cicd/linux+prepare.lint.sh`.

```sh
#!/bin/sh
set -eu
apt-get update -qq
apt-get install -y -qq shellcheck
shellcheck "$CICD_ROOT"/*.sh
```

`prepare` comes before `build` and `test`. A failure prevents later phases.
This example uses the Debian-based `linux` alias, root inside the container
and network access for package installation. For frequent runs, consider
using a vetted custom image with ShellCheck already installed.

## 8. A source archive as an artifact

File: `.cicd/linux+package.source.sh`.

```sh
#!/bin/sh
set -eu
tar --exclude=./.git -czf "$CICD_ARTIFACTS/source.tar.gz" \
  -C "$CICD_WORKSPACE" .
```

The archive is saved in this job's private artifact directory. For generated
files, the same job must first generate them and then save them there.
A later deploy job cannot simply read this job's artifact directory.
Hosted uploads and worker transfers need an explicit transport solution
that is set up separately.

## 9. Building a container and publishing it with guards

This recipe needs a reachable Docker daemon, a `Dockerfile` and two jobs.
`docker:27` is Alpine-based, so use `/bin/sh`, not Bash.

**Only for trusted runs on designated runners.** Build and publish share the
host's Docker image store here, not their private output directories.
A Docker socket grants extensive host access.

For example, the trusted entry point sets:

```text
CICD_IMAGE_REPOSITORY=ghcr.io/acme/example
CICD_REGISTRY=ghcr.io
CICD_REGISTRY_USER=<registry user>
CICD_REGISTRY_PASSWORD=<short-lived token from the secret store>
CICD_PUBLISH_IMAGE=true
```

These values are placeholders. Tokens do not belong in the repository,
shell history or command-line arguments. In distributed operation,
credentials are provided through [dispatcher grants](../deploy/README.md).
The **non-secret build target** `CICD_IMAGE_REPOSITORY` must also be set in
the worker/executor host context: a publish grant alone does not make it
available to a build job. Native and hosted entry points supply the commit;
when calling the executor directly on your machine, you must set
`CICD_COMMIT="$(git rev-parse HEAD)"` yourself. This does not make the existing
workspace immutable.

File: `.cicd/docker+27+build.image.sh`.

```sh
#!/bin/sh
set -eu
: "${CICD_IMAGE_REPOSITORY:?Set CICD_IMAGE_REPOSITORY at the entry point}"
: "${CICD_COMMIT:?Set commit metadata at the entry point}"
image=$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')
docker build --tag "$image:$CICD_COMMIT" "$CICD_WORKSPACE"
```

File: `.cicd/docker+27+publish.image.sh`.

```sh
#!/bin/sh
set -eu
[ "$CICD_EVENT" = push ] || exit 78
case "$CICD_REF" in
  refs/heads/main|refs/tags/v*) ;;
  *) exit 78 ;;
esac
[ "${CICD_PUBLISH_IMAGE:-false}" = true ] || exit 78
[ -n "${CICD_REGISTRY_USER:-}" ] || exit 78
[ -n "${CICD_REGISTRY_PASSWORD:-}" ] || exit 78
: "${CICD_REGISTRY:?Set CICD_REGISTRY}"
: "${CICD_IMAGE_REPOSITORY:?Set CICD_IMAGE_REPOSITORY}"
: "${CICD_COMMIT:?Set commit metadata at the entry point}"
image=$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')
printf '%s' "$CICD_REGISTRY_PASSWORD" \
  | docker login "$CICD_REGISTRY" -u "$CICD_REGISTRY_USER" --password-stdin
docker push "$image:$CICD_COMMIT"
if [ "$CICD_REF" = refs/heads/main ]; then
  docker tag "$image:$CICD_COMMIT" "$image:latest"
  docker push "$image:latest"
fi
```

The final `if` matters: a legitimate tag run should not exit with code 1
merely because the `main` comparison is false. The job always publishes the
commit tag; only `main` also updates `latest`.

`build` comes before `test`, and `publish` comes after it. If tests are also
defined, a failed test phase prevents the subsequent publish. The image may
already have been built by that point.

**The guards are not a security boundary.** In the executor,
`CICD_PUBLISH_IMAGE=false` neither prevents a publish job from running nor
technically blocks a push. Scripts must follow the convention; actual
authorization comes from isolation and controlled access to credentials.
An untrusted job can change its guard.

## 10. A custom provider

A provider generates ordinary job files. It changes neither the checkout nor
the phase logic. Example of a local provider directory:

```text
provider/
├── Containerfile
└── provider.sh
```

File: `provider/provider.sh`.

```sh
#!/bin/sh
set -eu
: "${CICD_PROVIDER_OUT:?This script must run as a SimpiCI provider}"
cat > "$CICD_PROVIDER_OUT/node+22+test.sh" <<'JOB'
#!/bin/sh
set -eu
cp -a "$CICD_WORKSPACE"/. "$CICD_OUTPUT/src"
cd "$CICD_OUTPUT/src"
npm ci
npm test
JOB
chmod +x "$CICD_PROVIDER_OUT/node+22+test.sh"
```

File: `provider/Containerfile`.

```dockerfile
FROM alpine:3.21
COPY provider.sh /usr/local/bin/provider
RUN chmod +x /usr/local/bin/provider
ENTRYPOINT ["/usr/local/bin/provider"]
```

Build the image and use it in the target project:

```sh
docker build -f provider/Containerfile -t local/simpici-provider:dev provider
CICD_WORKSPACE="$PWD" SIMPICI_PROVIDERS='local/simpici-provider:dev' \
  "$SIMPICI_TOOLS/bin/simpici-executor"
```

As in the [Quickstart](../README.md#quickstart), `SIMPICI_TOOLS` refers to your
separate SimpiCI checkout. The target project needs the Node prerequisites
from recipe 1, but no `.cicd` of its own as long as the provider generates jobs.

To inspect the generated jobs:

```sh
CICD_WORKSPACE="$PWD" SIMPICI_PROVIDERS='local/simpici-provider:dev' \
SIMPICI_PLAN_ONLY=true "$SIMPICI_TOOLS/bin/simpici-executor"
```

This command starts **the provider container**, but not the generated
job containers. A file with the same name in the repository takes precedence
over the provider file; with multiple providers, the first one listed wins.

A real provider should deliberately version both its own image and its job
images. The local `:dev` tag is convenient for this example, but is neither
an immutable reference nor suitable pinning for production.
