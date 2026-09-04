# App::SimpiCI

SimpiCI is a small Git-aware CI daemon. It accepts events from Git polling,
webhooks or trusted manual requests, checks out one exact revision and invokes
one ordinary executable script owned by that repository.

It intentionally has no workflow DSL, step graph, template inheritance or
matrix expansion. Project-specific build and release policy stays in versioned
shell code next to the project it builds.

The first vertical slice supports trusted manual events, exact detached
checkouts, one repository-owned script and static JSON/log reports. See
`TODO.md` for the broader design and remaining polling/queue work.

## Development

```console
prove -lr t/
```

## Hosted CI

Projects keep their build logic in one executable `.cicd` script. The standard
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
GHCR upload access and invokes the SimpiCI action. The action automatically
selects the single `.cicd/linux+*+cicd.sh`, derives its feature name and supplies
the same `CICD_*` environment and event JSON as the standalone runner. The
repository script decides whether and how to build an image; SimpiCI itself
publishes `ghcr.io/getty/simpici:<commit>` and `latest` from `main`.

Forgejo uses the same action format; a repository can use `./action` after
checkout, or a fully qualified remote action URL. Registry credentials remain
runner-specific environment supplied by its workflow.


To run an event, provide its JSON document and a private state directory:

```console
perl -Ilib bin/simpici --root var --event event.json
```

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
