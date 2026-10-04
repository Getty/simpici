# Operating SimpiCI

[README](../README.md) · [Executor reference](../docs/executor.md)

This guide describes the available entry points. Automatic branch-protection
queries, `.cicd/policy.json` and `branch_metadata` are not implemented yet.
They are covered by the [separate design](../docs/superpowers/specs/2026-09-21-branch-policy-design.md).

## 1. Native CLI: build an exact commit

The host needs Perl with the dependencies from `cpanfile`, Git, Bash 4.3 or
later, plus Docker CLI and a reachable Docker daemon for real jobs.
OpenSSH is also required for the worker connection. An installed distribution
puts the programs on `PATH`; in a source checkout, use `perl -Ilib`.

A complete event can be generated from a local, trusted Git repository.
The following commands run in the SimpiCI checkout and assume the target
branch already has a commit:

```sh
umask 077
TARGET_REPO=/absolute/path/to/target-repository
TARGET_REF=$(git -C "$TARGET_REPO" symbolic-ref HEAD)
TARGET_COMMIT=$(git -C "$TARGET_REPO" rev-parse "$TARGET_REF")

perl -MJSON::MaybeXS -e '
  print JSON::MaybeXS->new->canonical->pretty->encode({
    source => "manual", event => "manual", repository => "local/example",
    clone_url => $ARGV[0], ref => $ARGV[1], commit => $ARGV[2]
  });
' "$TARGET_REPO" "$TARGET_REF" "$TARGET_COMMIT" > event.json

perl -Ilib bin/simpici --event event.json --root var \
  --runner "$PWD/bin/simpici-executor"
```

Replace `TARGET_REPO`. With a detached HEAD, the desired canonical ref must be
specified explicitly. The example source `manual` is a valid native source
value; `github-actions` would not be.

The runner fetches the exact commit and checks it out with a detached HEAD.
Local, uncommitted files in the target repository are not included in the build.
LFS, submodules and the full Git history are not prepared automatically;
the initial fetch is shallow.

### Native CLI options

| Program | Key options |
| --- | --- |
| `simpici` | `--event FILE`, optional `--root DIR`, `--timeout SECONDS`, `--runner FILE`, `--help`, `--man` |
| `simpicid` | `--config FILE`, optional `--once`, `--runner FILE`, `--help`, `--man` |
| `simpici-worker` | `--dispatcher USER@HOST`, `--root DIR`, optional `--once`, `--executor FILE` |
| `simpici-dispatch` | `--config FILE`, `--worker NAME`; internal stdin JSON protocol |

Executor overrides should be absolute paths: the native runner changes the
working directory before execution. `simpici-worker` and `simpici-dispatch`
do not currently implement a `--help`/`--man` interface. The worker uses the
execution timeout from the dispatcher claim; its existing local `--timeout`
option does not override that value.

`simpici` does not read a daemon configuration or deduplicate through the
queue. Two one-shot invocations produce two runs. The daemon and worker set
a restrictive umask themselves; for the one-shot entry point, the example
deliberately sets it beforehand.

## 2. Polling on one machine

The [README](../README.md#native-daemon) contains a minimal configuration
that is valid today. Important details:

- `root` contains private state and the separate public projection.
- `interval` is the pause after the entire polling cycle. Local builds run
  serially; multiple repositories are not built concurrently.
- `refs` filters the Git polling query, not arbitrary manual inputs.
- `build_initial: false` skips only the initial baseline. Refs that appear
  later are built; deletion alone does not start a run.
- `timeout` limits executor runtime. Git commands have their own limits;
  this is not an equivalent overall limit for the entire run.
- `simpicid --once` can exit with 0 even if a job has failed. Read the build
  status from the report, not just the daemon's exit code.
- A repository whose refs cannot be read (missing, unreachable, access
  refused) does not stop the daemon. It logs one line on standard error,
  polls the remaining repositories and tries again in the next cycle:

  ```text
  simpicid: repository acme/example (https://github.com/acme/example.git) not polled: SimpiCI::Source::GitPoll git ls-remote failed: fatal: …
  ```

  The line repeats every cycle while the repository stays unreadable.
  Credentials in an HTTP(S) clone URL are left out of it. `simpicid --once`
  still polls every repository and then exits with 1.
- An unreadable repository keeps its recorded tips, so its return alone
  builds nothing. A repository that has never been read has no baseline yet:
  its first successful poll is the initial one, and `build_initial` decides.
- `ls_remote_timeout` limits how long the refs of one repository are waited
  for, in seconds; it is optional and defaults to 60. A remote that neither
  answers nor fails within it counts as unreadable for this cycle, with the
  limit in the line:

  ```text
  simpicid: repository acme/example (ssh://forge.example/acme/example.git) not polled: SimpiCI::Source::GitPoll git ls-remote timed out after 60 s
  ```

  The query and the helpers git started for it (`ssh`, `git-remote-https`,
  credential helpers) are ended as one process group, with `TERM` and a
  second later `KILL`. The limit applies to each repository on its own: a
  cycle can take that long for every repository that hangs, before `interval`
  starts. It is not `timeout`, which limits a run. A value that is not a
  positive integer ends the daemon at its first cycle instead of polling
  without a limit.
- The query cannot ask for anything: its standard input is `/dev/null`, and a
  helper that prompts on the terminal `simpicid` was started from is stopped
  and runs into the limit. Credentials have to be available without a prompt.
- A repository that answers, but with none of the configured refs, is not
  polled either while tips are recorded for it. `git ls-remote` reports this
  as success with empty output; a mirror does it before its synchronisation.
  The line names the state it keeps instead of a git error:

  ```text
  simpicid: repository acme/example (https://github.com/acme/example.git) not polled: remote returned no refs, keeping recorded tips: 2 in state/repositories/<id>.json
  ```

  Saving the empty answer would make every tip new on its return, including
  tags that were never built and would then receive what a `refs/tags/*`
  grant gives. The line and the exit status 1 of `--once` repeat as long as
  the answer stays empty. If the refs are gone for good, remove the repository
  from the configuration, or delete the named file below `root` to accept the
  empty state as the new baseline.
- This guards recorded tips only. A repository that is empty at its **first**
  poll gets an empty baseline without a log line, and every ref that appears
  later is built, whatever `build_initial` says: add a mirror after its first
  synchronisation. A repository that loses only some of its refs forgets
  those and treats them as new if they come back.
- Only reading the refs is tolerated. A run that cannot be started, an
  unwritable state root or queue, and an unusable grant end the daemon as
  before.
- Local polling remembers ref tips. Persistent tuple deduplication is only
  available with the queue in dispatcher mode.

The template `etc/simpici.example.json` builds SimpiCI itself. Its own
container jobs also need these non-secret values, for example:

```sh
CICD_IMAGE_REPOSITORY=simpici-local CICD_PUBLISH_IMAGE=false \
  perl -Ilib bin/simpicid --config etc/simpici.example.json --once
```

The publish variable is a convention used by these scripts, not authorization.
In production services, credentials and network access must be restricted
independently of such guards.

## 3. Daemon in a container

The [Containerfile](../Containerfile) includes the Perl daemon, executor, Git
and Docker CLI. It starts **no inner Docker daemon, SSH server or web server**.
Its entrypoint is `simpicid`; it is not a ready-to-use worker VM image.

When an outer daemon container uses the host Docker socket, job-container
bind mounts are resolved by the **host Docker daemon**. Workspaces and
temporary files must therefore exist at the same absolute paths on the host
and inside the daemon container. Just `-v /var/run/docker.sock:…` is not enough.

Example for a local, rootful Docker host, assuming administrative setup
of `/srv/simpici`:

```sh
sudo install -d -m 0700 /srv/simpici /srv/simpici/tmp
docker build -f Containerfile -t simpici:local .
```

Create `simpici.container.json`; replace the repository and ref with your own
trusted repository that already has committed jobs:

```json
{
  "root": "/srv/simpici",
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

```sh
docker run --rm \
  -v /srv/simpici:/srv/simpici \
  -v "$PWD/simpici.container.json:/etc/simpici.json:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e RUNNER_TEMP=/srv/simpici/tmp \
  simpici:local --config /etc/simpici.json --once
```

The same path principle applies to other container runtimes and Actions
runners. Remote Docker, rootless Podman, user-namespace mappings and SELinux
may require additional setup; this example is not a tested universal solution
for those cases. For published images rather than a local build, the project
references `raudssus/simpici` and `ghcr.io/getty/simpici` are available.

## 4. Dispatcher and isolated build VM

```text
Dispatcher: poll Git → persist queue → deliver claims and scoped secrets
                                             ↑
                                       outbound SSH
                                             ↑
Worker VM: claim → exact checkout → container jobs → send completion back
```

There is no inbound worker API. Install the same SimpiCI distribution on both
machines; the supplied systemd units expect programs under `/usr/local/bin`.
VMware is one possible VM environment, not a SimpiCI protocol requirement.

### Set up the dispatcher

1. Create a dedicated account `simpici` and `/etc/simpici/secrets` with mode
   `0700`. Install
   [simpici.dispatcher.example.json](../etc/simpici.dispatcher.example.json)
   as `/etc/simpici/dispatcher.json`, with mode `0600`, and adjust the
   repositories, state path and grants.
2. **Set `mode: "dispatcher"`.** Otherwise, the daemon uses the local runner.
   The dispatcher itself needs neither a Docker socket nor a build toolchain.
3. Install [simpicid.service](simpicid.service) and enable it with
   `systemctl enable --now simpicid` only after checking the paths. The
   daemon reads every granted secret file when it starts and refuses to start
   while a grant is unusable, so its account needs read access to those files,
   like the account behind the SSH endpoint. Restart it after changing the
   configuration; the journal names an unusable grant. A repository whose
   refs cannot be read does not stop the daemon: the journal gets a
   `not polled` line per cycle, as described in section 2.
4. Use a separate key and a fixed worker name for each worker.
   Assign a forced command to the authorized key:

   ```text
   restrict,command="/usr/local/bin/simpici-dispatch --config /etc/simpici/dispatcher.json --worker vm1" ssh-ed25519 WORKER_PUBLIC_KEY
   ```

   Ensure `authorized_keys` and its parent directory are owned by an
   administrator so that the service account cannot replace the restrictions.
   Disable password and interactive login. Among other things, `restrict`
   disables PTY, forwarding and user-rc execution. The key gets no normal
   shell. A test with `ssh -T simpici@dispatcher id` must not execute `id`;
   it should produce only a protocol error.
5. Publish only the public report projection; never publish the queue,
   internal events, credentials or workspaces.

### Understand secret grants

A grant is not a general environment file for all jobs:

- The repository name **and clone URL** must match.
- `events` is an exact list. `refs` lists exact refs or patterns of the form
  `refs/<path>/*`, which match every ref below that path (`refs/tags/*` covers
  each release tag). `*` anywhere else is rejected as a configuration error.
  Empty or missing lists grant nothing.
- A pattern on `refs/heads/*` hands the secret to every branch that is polled.
  Prefer exact branch names and reserve patterns for tags.
- `sources` can further restrict the source.
- `phases` may contain only `publish` and `deploy`.
- Pull-request events receive no grants.
- `name` is the environment variable the job sees: `CICD_<NAME>` or
  `<NAME>_TOKEN` in capitals. A variable the executor assigns itself is
  rejected as a name, because the executor's value would win: everything in
  the [job variable table](../docs/executor.md#variables-inside-jobs),
  `CICD_PROVIDER_OUT`, `CICD_REGISTRY`, `CICD_REGISTRY_USER` and
  `CICD_PUBLISH_IMAGE`. `CICD_REGISTRY_PASSWORD` is the registry variable a
  grant can supply; registry host and user come from the worker host's
  environment.
- Each secret value is stored in a private file as a single nonempty line.
- Mirror entries need their own grants if both clone URLs may produce runs.
  Otherwise, the source actually used for the run determines the outcome.

The grants of all repositories are checked together, whether or not a run
would match them: when `simpicid` starts in dispatcher mode, and again by
`simpici-dispatch` before every claim. The check covers the name, the ref
patterns, the list shapes, the phases and the secret file, which must be
readable and hold one nonempty line. A failure names the configuration entry
and the reason, never a value:

```text
SimpiCI::Dispatcher repository acme/example (repositories[0]), secret CICD_REGISTRY_PASSWORD (secrets[0]): cannot read secret file /etc/simpici/secrets/registry-password: No such file or directory
```

`simpicid` then exits before it polls. `simpici-dispatch` fails the claim
without taking a lease: the message reaches the worker's log, queued runs stay
queued, and they are served once the configuration is usable again. One
unusable grant therefore stops the claims of every repository, not only its
own. The completion of a run that was already claimed is still accepted.

The example configuration shows the complete current grant structure.
Files containing secret values belong to the service account, with mode
`0600`; values must not appear in public reports or literal command arguments.
Native **local** execution does not evaluate `secrets[]` the way the dispatcher
does.

Non-secret build parameters such as `CICD_IMAGE_REPOSITORY` must be available
in the worker host's environment if build jobs need them. A publish grant
does not automatically make this variable available during the build phase.

### Set up the build VM

1. Provision a dedicated Linux VM with the account `simpici-worker`, Git,
   OpenSSH, Docker and SimpiCI. The
   [worker unit](simpici-worker.service) expects a group named `docker`.
2. Docker socket access effectively means control over the build VM. Do not
   place other workloads, production host mounts or general-purpose credentials
   there. Keep different trust domains separate; a persistent worker VM is not
   a secure sandbox for fork PRs.
3. Enforce network isolation **outside the guest**, for example at the VMware
   port-group or router level. Block internal, management, link-local and
   metadata networks for both IPv4 and IPv6; allow only the required DNS, Git,
   registry and dispatcher connections. The guest firewall alone is not enough
   when Docker access is available. Administer the VM through a console or
   separate, controlled access.
4. Generate a dedicated worker key. Install the dispatcher host key in
   `known_hosts` from a trusted administrative source. The transport uses
   BatchMode and StrictHostKeyChecking, not an interactive TOFU prompt.
5. Create `/etc/simpici/worker.env`, for example:

   ```text
   SIMPICI_DISPATCHER=simpici@PUBLIC_DISPATCHER_HOST
   CICD_IMAGE_REPOSITORY=ghcr.io/acme/example
   ```

   Set the second value only if the jobs need this shared build-target
   context. It is not a value automatically resolved per repository.
   Assign credentials through narrowly scoped dispatcher grants instead.
6. Install the worker unit and, after checking the configuration, enable it
   with `systemctl enable --now simpici-worker`. The **entire worker state
   remains private**, including its local `public` directory.
7. From the actual VM, verify network boundaries, allowed remotes, a test run
   and recovery after a reboot. Local stub tests do not replace these checks.

### Recovery and limits

The queue locks state changes and run numbers. Claims use atomic replacement
of JSON under a lock, not renames between `queued` and `running` directories.

Queue deduplication is based on `repository NUL ref NUL commit` and applies
across sources and mirrors. Polling observations, in contrast, are separate
for each repository and clone URL. Use different logical repository names for
independent mirror runs. A mirror that is reachable but temporarily without
refs keeps its recorded tips; section 2 describes the log line and the limits
of that rule.

Claims expire after the configured execution timeout plus 30 minutes for
checkout and transfer. On the next claim, expired work is marked
`interrupted`, **not automatically run again**: a publish or deploy operation
may already have taken effect. There is no heartbeat, automatic publish retry
or ready-to-use retry/cancel operator CLI. While a grant is unusable, no claim
is served, so expired work keeps its `running` state until the configuration
is fixed.

The worker persists `completion.json` before uploading it. If an SSH response
is lost, the completion can therefore be retried idempotently without
rebuilding. This is not an exactly-once guarantee for every possible crash
point: an interruption before the completion is persisted may already have
left external side effects.

A rejected, expired completion is retained for investigation. Stop the worker
and archive the file only after checking external effects, before accepting
new work. Likewise, inspect orphaned secret directories and remove them
selectively before putting the VM back into service.

The dispatcher reconstructs public metadata; the worker and dispatcher redact
assigned literal secret values from uploaded logs. This does not detect
arbitrary sensitive information or prevent intentional exfiltration. Final
logs are limited to the last 4 MiB. Live logs and artifacts are not
transferred. Workspaces, outputs and artifacts remain on the worker: configure
disk limits and retention before continuous operation.

## 5. Dispatcher in containers

[deploy/dispatcher/](dispatcher/) runs the dispatcher side of section 4
without installing Perl or a systemd unit on the host: one image, two
services. `poller` is `simpicid` in dispatcher mode; `ssh` is an sshd on port
2222 whose only purpose is the workers' forced command. Neither service gets a
Docker socket. The image is separate from the daemon image of section 3 and
contains no Docker CLI.

It replaces "Set up the dispatcher" only. Secret grants, the build VM and
recovery work as described in section 4. The
[example configuration](dispatcher/dispatcher.example.json) polls two
repositories on `main` and on tags and grants one package token to the
`publish` phase of tag runs; replace the repositories and grants with your own.

```sh
cd deploy/dispatcher
install -d -m 0700 state secrets
install -d -m 0755 ssh
install -m 0600 dispatcher.example.json dispatcher.json
install -m 0600 /dev/null secrets/package-token
printf '%s\n' "$PACKAGE_TOKEN" > secrets/package-token
ssh-keygen -q -t ed25519 -N '' -f ssh/ssh_host_ed25519_key
install -m 0644 authorized_keys.example ssh/authorized_keys
```

Edit `dispatcher.json` now, and put each worker's public key and worker name
into `ssh/authorized_keys`, one line per worker. Every line keeps `restrict`
and the forced command: a key without them gets a shell in the container. Then
hand the files over and start both services:

```sh
sudo chown -R 990:990 state secrets dispatcher.json
sudo chown -R root:root ssh
docker compose up -d --build
```

UID and GID 990 are the `simpici` account inside the image; on the host the
number may belong to another account or to none. The `ssh` directory stays
owned by root so the service account cannot rewrite its own key restrictions,
and sshd refuses the keys if that directory or `authorized_keys` is writable
by anyone else. These four private paths are ignored by Git and kept out of
the image build context. Set `SIMPICI_SSH_PORT` if 2222 is taken on the host.

The state directory holds the queue and the public report projection under
`state/public/runs`; section 7 applies to publishing it. After changing
`dispatcher.json`, run `docker compose restart`: the poller reads it only at
startup, and a file replaced by an editor is not visible through the mount
before that. Secret files are read at each claim, so a rotated value needs no
restart. The poller also reads them once when it starts and exits if a grant
is unusable; `docker compose logs poller` names it.

A repository the poller cannot read, such as one whose organization does not
exist on the forge yet, no longer restarts the container. The poller logs a
`not polled` line for it in every cycle, keeps polling the others and picks
the repository up once it is readable; section 2 describes the line and what
is built then. A repository that exists but returns no refs while tips are
recorded for it gets such a line as well. Look for these lines in
`docker compose logs poller`: nothing else reports a repository that is never
read.

On the worker, name the port in `~/.ssh/config` of the account that runs
`simpici-worker`, because `--dispatcher` takes no port:

```text
Host simpici-dispatcher
  HostName dispatcher.example.org
  Port 2222
  User simpici
  IdentityFile ~/.ssh/id_ed25519
```

Record the host key once. Compare the fingerprint with the output of
`ssh-keygen -lf ssh/ssh_host_ed25519_key.pub` on the dispatcher before you
trust it:

```sh
ssh-keyscan -p 2222 -t ed25519 dispatcher.example.org > dispatcher.hostkey
ssh-keygen -lf dispatcher.hostkey
cat dispatcher.hostkey >> ~/.ssh/known_hosts
```

Then start the worker with `--dispatcher simpici@simpici-dispatcher`. A worker
key that tries anything but the protocol gets a protocol error:
`ssh simpici@simpici-dispatcher id` must not print a `uid=` line.

This setup has no health check, log rotation or backup of the state directory.
The commands above assume a rootful Docker daemon and are not tested with one
yet. With rootless Docker, Podman or user-namespace remapping, UID 990 inside
the container is a different UID on the host: set the ownership inside the
user namespace instead and leave `ssh` owned by the invoking user, who is root
inside the container. Rootless Podman behind the Docker CLI is the tested
variant; `docker compose` could not build the image there, so build it first:

```sh
podman build -f Containerfile -t simpici-dispatcher:local ../..
podman unshare chown -R 990:990 state secrets dispatcher.json
docker compose up -d --no-build
```

## 6. Forgejo Actions

For a **target repository other than SimpiCI itself**, `uses: ./action` is
correct only if you actually include the action there. Otherwise, use an
external reference. Example for trusted pushes:

```yaml
name: CI
on:
  push:
    branches: [main]

jobs:
  ci:
    runs-on: docker
    steps:
      - uses: https://data.forgejo.org/actions/checkout@v6
        with:
          persist-credentials: false
      - uses: https://github.com/Getty/simpici/action@main
        env:
          SIMPICI_CONCURRENCY: "2"
          CICD_IMAGE_REPOSITORY: local/example
          CICD_PUBLISH_IMAGE: "false"
```

The label `docker` must point to a runner you have configured appropriately;
it guarantees neither Docker CLI nor a socket or correct bind paths. The
checkout step also needs a suitable Actions runtime environment.
Pin versions to reviewed SHAs for controlled updates.

`CICD_IMAGE_REPOSITORY` is needed for the relevant container jobs, but not for
language-only tests. The project's own `.forgejo/workflows/ci.yml` does not
currently set this build target and is therefore incomplete for the current
SimpiCI-specific jobs. It is not a deployment quickstart to copy without
review. The generic Forgejo integration shown here has not been verified
live against a real runner.

## 7. Reports and viewer

Only `<root>/public/runs/` is intended as the report projection. The viewer
file lives separately at `public/index.html` in the repository. Local native
logs are **unfiltered**; review their contents before publishing. The viewer
output is not yet a comprehensively hardened public dashboard either.
Review metadata escaping before exposing it publicly.

For a local view without Compose, use Python 3 under the same user that has
permission to read the reports. From the SimpiCI checkout, with existing
reports under `var/public/runs`:

```sh
VIEW_DIR=$(mktemp -d)
cp public/index.html "$VIEW_DIR/index.html"
ln -s "$PWD/var/public/runs" "$VIEW_DIR/runs"
printf 'Temporary viewer: %s\n' "$VIEW_DIR"
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$VIEW_DIR"
```

The server deliberately binds only to localhost. Clean up the specific
temporary directory afterwards; the symlink points only to the public
projection, not the private state root. For production, set up a separately
secured web server and controlled publishing.

### What `compose.yaml` actually starts

The existing Compose example starts **Traefik and nginx**, not the daemon,
worker or registry. It expects:

- a rootless Podman socket at `${XDG_RUNTIME_DIR}/podman/podman.sock`;
- report files under `./var/public/runs`;
- an accessible viewer file from `./public`;
- appropriate read permissions for the web server.

Because of `umask 077`, the daemon and worker create private paths. The public
projection needs a targeted UID/ACL setup or a separate export. Do not take a
shortcut by making the entire state publicly readable.

Run `docker compose up -d` only after completing this setup. The viewer will
then be available at <http://127.0.0.1:8080/>. The Compose example does not
configure a public TLS/authentication boundary or automatic permission fixes.
Using a regular Docker socket requires deliberate configuration changes.

The local native index currently contains only the most recently published
run; the queue index lists the queue runs. The viewer loads data once rather
than acting as a complete live dashboard. Hosted runs are not transferred to
this store.
