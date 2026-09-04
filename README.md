# App::SimpiCI

SimpiCI is a small Git-aware CI daemon. It accepts events from Git polling,
webhooks or trusted manual requests, checks out one exact revision and executes
the repository's top-level `.cicd/*.sh` jobs in selected containers.

It intentionally has no workflow DSL, step graph, template inheritance or
matrix expansion. Project-specific build and release policy stays in versioned
shell code next to the project it builds.

The first vertical slice supports trusted manual events, exact detached
checkouts, phased repository-owned jobs and static JSON/log reports. See
`TODO.md` for the broader design and remaining polling/queue work.

## Development

```console
prove -lr t/
```

## Hosted CI

Projects keep their build logic in executable `.cicd` scripts. The standard
GitHub integration delegates its only job to the reusable workflow:

```yaml
jobs:
  simpici:
    permissions:
      contents: read
      packages: write
    uses: Getty/simpici/.github/workflows/simpici.yml@main
```

The workflow checks out the triggering repository, grants its short-lived token
GHCR upload access and invokes the SimpiCI action. Top-level scripts use
`<image>+<phase>[.<job>].sh`; for example `application+dingens+13+build.api.sh`
runs in `docker.io/application/dingens:13` during the build phase. Scripts in
one phase run concurrently, and the next phase starts after all of them finish.
The fixed order is prepare, build, test, package, publish and deploy.

Aliases provide convenient defaults: `linux` is `debian:latest`, while `perl`,
`node` and `python` select their official latest images. Explicit forms such as
`perl+5.40+test.sh` and `ghcr.io+application+dingens+13+publish.sh` select exact
repositories and tags. SimpiCI supplies the same `CICD_*` event context to every
container, with job-specific output and artifact directories.

Forgejo uses the same action format; a repository can use `./action` after
checkout, or a fully qualified remote action URL. Registry credentials remain
runner-specific environment supplied by its workflow.


To run an event, provide its JSON document and a private state directory:

```console
perl -Ilib bin/simpici --root var --event event.json
```

Both executables provide concise `--help` and complete `--man` output. Use
`--runner` to override the shared executor path when SimpiCI is installed
outside the repository checkout.

Run the Git poller once or continuously from a JSON configuration:

```console
perl -Ilib bin/simpicid --config etc/simpici.json --once
perl -Ilib bin/simpicid --config etc/simpici.json
```

The static report can be served locally through Traefik and nginx with
`docker compose up -d`, then opened at <http://127.0.0.1:8080/>.

## License

This software is copyright (c) 2026 by Torsten Raudssus and is available under
the same terms as Perl itself.
