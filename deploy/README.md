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
| `simpici` | `--event FILE`, optional `--root DIR`, `--timeout SECONDS`, `--runner FILE`, `--help`, `--man`; for the recorded tips of the poller `--config FILE` with `--state`, optional `--repository NAME`, or with `--repository NAME --forget REF` |
| `simpicid` | `--config FILE`, optional `--once`, `--runner FILE`, `--help`, `--man` |
| `simpici-worker` | `--dispatcher USER@HOST`, `--root DIR`, optional `--once`, `--executor FILE` |
| `simpici-dispatch` | `--config FILE`, `--worker NAME`; internal stdin JSON protocol |

Executor overrides should be absolute paths: the native runner changes the
working directory before execution. `simpici-worker` and `simpici-dispatch`
do not currently implement a `--help`/`--man` interface. The worker uses the
execution timeout from the dispatcher claim; its existing local `--timeout`
option does not override that value.

A run of `simpici` does not read a daemon configuration or deduplicate
through the queue. Two one-shot invocations produce two runs. The daemon and
worker set a restrictive umask themselves; for the one-shot entry point, the
example deliberately sets it beforehand. With `--config`, `simpici` starts no
run: it shows or corrects [the recorded tips](#the-recorded-tips-of-a-repository)
of the poller and sets the umask of the daemon for what it writes.

## 2. Polling on one machine

The [README](../README.md#native-daemon) contains a minimal configuration
that is valid today. Important details:

- `root` contains private state and the separate public projection.
- `interval` is the pause after the entire polling cycle. Local builds run
  serially; multiple repositories are not built concurrently.
- `refs` filters the Git polling query, not arbitrary manual inputs.
- `build_initial: false` skips only the initial baseline. Refs that first
  appear later are built; deletion alone does not start a run, and neither
  does a deleted ref that returns on the commit recorded for it.
- `repositories` is a list of objects, each with a `name` and a `clone_url`
  that are nonempty strings. `simpicid` checks this when it starts, in local
  and in dispatcher mode, and exits before it polls anything:

  ```text
  SimpiCI::App::Eventd repositories must be a list
  SimpiCI::App::Eventd repositories[1] must be an object
  SimpiCI::App::Eventd repository acme/example (repositories[0]): repository needs name and clone_url
  ```

  An entry is named by its position and, if it has one, its name. What
  stands in it is not repeated: a bare URL in the place of an object may
  carry a token.
- `clone_url` must not contain credentials. `simpicid` checks every
  repository in the same step:

  ```text
  SimpiCI::App::Eventd repository acme/example (repositories[0]): clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git
  SimpiCI::App::Eventd repository acme/example (repositories[0]): clone URL must not contain a password; a user name alone is accepted, and SSH authenticates with a key of the account that runs git
  ```

  The message names the repository and its position in the configuration,
  never the URL. The first is given for an `http://` or `https://` URL with a
  user part before the host, such as `https://user:token@…` or
  `https://token@…`. The second is given for a password in the user part of
  any other URL, such as `ssh://user:password@…` or `ftp://user:password@…`,
  an empty password and a `%3A` included, and for `user:password@host:path`
  without a scheme. Whitespace and control characters are refused the same
  way, with their own reason. `git@host:path`, `ssh://git@host/path` and
  `ssh://git@host:2222/path` stay valid; a password that contains a `/` is
  not recognised. A clone URL travels with every event into the queue and
  the job environment, so credentials belong to git instead: set
  `credential.helper` in the Git configuration of the account `simpicid` runs
  as, for example the `store` helper with its `~/.git-credentials`, a file
  only that account may read (`gitcredentials(7)`, `git-credential-store(1)`).
  SSH takes no password from a URL at all; give that account a key. In
  dispatcher mode the worker account fetches the commit and needs its own.
  `simpici-dispatch` does not repeat the clone URL check.

  The recorded tips of a repository are kept under its name and clone URL.
  With a corrected URL it therefore counts as never read: `build_initial`
  decides whether its current tips are built, and a grant applies only to
  events that carry the URL the configuration has now.
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
  `simpicid --once` still polls every repository and then exits with 1.
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
  starts. The second query of a repository without a baseline, described
  below, gets what the first left of the limit, not a limit of its own. It is
  not `timeout`, which limits a run. A value that is not a
  positive integer ends the daemon at its first cycle instead of polling
  without a limit.
- The query cannot ask for anything: its standard input is `/dev/null`, and a
  helper that prompts on the terminal `simpicid` was started from is stopped
  and runs into the limit. Credentials have to be available without a prompt.
- A repository that answers, but with none of the configured refs, is not
  polled either while refs are missed that its last poll still saw.
  `git ls-remote` reports this as success with empty output; a mirror that
  was set up again does it before its synchronisation. The line says how many
  refs are missed instead of a git error:

  ```text
  simpicid: repository acme/example (https://github.com/acme/example.git) not polled: remote returned no refs, configured refs seen at the last poll: 2
  ```

  The line is a signal for the operator and protects nothing. The recorded
  tips stay with or without it, as those of every ref that disappears do, so
  refs that return where they were build nothing, including tags that were
  never built and would otherwise receive what a `refs/tags/*` grant gives.
  The number counts the refs that are missed: those the last poll saw and
  `refs` still selects. A ref that was gone before, or that the filter no
  longer asks for, is not counted, and an empty answer that misses no ref,
  such as the one of a filter that was changed to refs the repository does
  not have yet, is polled without a line. The line and the exit status 1 of
  `--once` repeat as long as the answer stays empty. If the refs are gone for
  good, [forget them](#the-recorded-tips-of-a-repository) or remove the
  repository from the configuration.
- A repository that has no refs at all is not polled either while nothing is
  recorded for it. This is a mirror between its creation and its first
  synchronisation, or a project nobody has pushed to:

  ```text
  simpicid: repository acme/example (https://forge.example/acme/example.git) not polled: SimpiCI::Source::GitPoll repository has no refs yet at …
  ```

  It gets no baseline, so the poll that first sees refs is its initial one:
  `build_initial: false` records them without a run, `true` builds them. With
  an empty baseline every one of them would be built as new, whatever
  `build_initial` says, and an old tag would receive what a `refs/tags/*`
  grant gives. A new project whose first push is to be built needs
  `build_initial: true`.

  The filtered answer cannot tell this from a repository that only lacks the
  configured refs, such as `refs/tags/*` before the first tag. For an empty
  answer without a baseline, and only then, `simpicid` asks a second time
  without the `refs` filter. A name below `refs/` in that answer, also outside
  branches and tags, makes it a repository with refs: it gets its empty
  baseline without a line, and the first matching ref is built. `HEAD` alone
  does not count. A second query that fails or runs into the limit leaves the
  repository unread for this cycle, like the first.

  The line and the exit status 1 of `--once` repeat until the repository has
  a ref, and there is no state file to delete: push to it, let the mirror
  synchronise, or take the repository out of the configuration until then.
- Only a repository without any ref is recognised, not one that is half
  filled. A mirror that is polled during its first synchronisation, with the
  branch there and the tags not yet, gets a baseline without the tags; they
  are built as new when they arrive and receive what their grants give, since
  a tag that arrives late looks like a tag that was just pushed. **Let a
  mirror finish its first synchronisation before you add it to the
  configuration or start the daemon.**
- A ref that was recorded once is not forgotten. If only some refs disappear,
  such as every tag of a mirror that still shows its branch, or a branch that
  was deleted, each keeps its last tip in the state and no run starts. When
  such a ref is back on the recorded commit, nothing is built; on another
  commit it is built once, like a ref that moved. Only a ref that was never
  recorded is new, which is why the tags of the half-filled mirror above are
  built and these are not.

  The state of a repository therefore holds every ref name that was ever
  observed for it, and by polling it only grows: a ref that was deleted stays
  in it, and so does one that `refs` no longer matches. A tag that is deleted
  and set again on the same commit is not built a second time. Nothing
  expires by itself, because a ref that returns has to find its tip;
  [the recorded tips of a repository](#the-recorded-tips-of-a-repository)
  describes how to see the state and how to take a ref out of it.
- A ref that `refs` no longer selects keeps its tip like one that was
  deleted. If the filter is narrowed and later widened again, a ref that
  comes back into it is compared with the tip it had when it left: on the
  same commit it builds nothing, and if it moved in between it is built once,
  at the commit it is on then. What happened to it while it was outside the
  filter is not built.
- The state of a repository is written only when a poll changes it, and it
  is locked from the moment it is read until it is written, the runs of that
  poll included. A second `simpicid` on the same `root`, such as a
  `simpicid --once` started by hand beside the service, therefore does not
  take a tip away that the first has recorded and builds nothing the first
  has built: it waits while the first polls that repository, in local mode
  until its build has ended, and then compares with what the first recorded.
  This makes a second poller harmless, not useful; run one per `root`.
- Only reading the refs is tolerated. A run that cannot be started, an
  unwritable state root or queue, an unusable entry of `repositories`, a
  refused clone URL and an unusable grant end the daemon.
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

### The recorded tips of a repository

What the poller knows about a repository is one file below `root`:

```text
<root>/state/repositories/<id>.json
<root>/state/repositories/<id>.lock
```

`<id>` is the SHA-256 of name, a NUL byte and clone URL of the repository, so
nobody has to compute it: `simpici` finds the file from the configuration the
daemon polls with. The `.lock` file beside it is empty. It is what a poll and
`simpici --forget` lock; it appears with the first poll, is never removed and
means nothing by itself.

```json
{
   "absent" : [
      "refs/heads/topic"
   ],
   "tips" : {
      "refs/heads/main" : "6d0c…",
      "refs/heads/topic" : "0b1e…"
   }
}
```

`tips` is the last tip of every ref the poller has recorded. `absent` lists
those of them the last poll did not see: refs that are gone from the
repository, and refs that `refs` no longer selects. A file written before
this form existed is a flat object of ref names and commits; it is read as
tips that were all seen and replaced when the state next changes. The file is
written only when a poll changes something, so its modification time is the
last change, not the last poll.

#### Watching its size

```sh
simpici --config /etc/simpici/dispatcher.json --state
```

```text
repository acme/example (https://github.com/acme/example.git): recorded refs: 214, absent at the last poll: 187, state/repositories/<id>.json, 19873 bytes
repository acme/other (https://github.com/acme/other.git): nothing recorded
```

One line per configured repository, on standard output, with the exit status
0: how many refs are recorded, how many of them the last poll did not see,
the file relative to `root` and its size. Nothing is polled for it and no
remote is read. `nothing recorded` is a repository that was never polled.

A state only grows by polling. With one branch and a tag for each release
that is a line per release. With a filter such as `refs/heads/*` over a
repository of short-lived branches it is a line for every branch name there
ever was, and `absent` grows with it: that number is the part of the state
that is only kept in case the ref returns. **Nothing removes these entries
automatically.** An entry is what keeps a ref that returns on its recorded
commit from being built again, a deleted and restored release tag for
instance, and the poller cannot tell a branch that is gone for good from one
that is missing for a while. The cost of a large state is its file being read
at every poll and written at every change, nothing else; forget refs when the
numbers bother you, not on a schedule.

Only configured repositories are shown. The state of a repository that left
the configuration, or that is in it under another name or clone URL now,
stays below `state/repositories/` as a file nothing reads any more; no
command lists it. Compare the directory with the files `--state` names and
delete what belongs to none, together with its `.lock`.

`--repository` shows one repository with its refs, the absent ones marked:

```sh
simpici --config /etc/simpici/dispatcher.json --state --repository acme/example
```

```text
repository acme/example (https://github.com/acme/example.git): recorded refs: 3, absent at the last poll: 1, state/repositories/<id>.json, 277 bytes
  refs/heads/main 6d0c…
  refs/heads/topic 0b1e… absent
  refs/tags/v1 6d0c…
```

#### Forgetting one ref

```sh
simpici --config /etc/simpici/dispatcher.json --repository acme/example \
  --forget refs/heads/topic
```

```text
repository acme/example (https://github.com/acme/example.git): forgot refs/heads/topic, recorded at 0b1e…
```

The repository is named as the configuration names it and the ref by its full
name, as `--state` prints it; a pattern is not expanded. To the next poll the
ref was never recorded. What that means depends on the ref:

- A ref that is `absent`, because the repository no longer has it or `refs`
  no longer selects it, leaves the state and nothing is built. This is the
  way to make a state smaller. Should the ref ever return, it is new and is
  built.
- A ref the repository still has and `refs` still selects is new at the next
  poll and **is built**, on the commit it is on then, and receives what its
  grants give: forgetting `refs/tags/v1` under a `refs/tags/*` grant builds
  and publishes that tag again. `build_initial: false` does not prevent it.
  That setting decides about a repository that was never read, and a
  repository whose state has lost a ref, even its last one, is not that. In
  local mode the commit is built even if it was built before; in dispatcher
  mode the queue has every repository, ref and commit it accepted once and
  starts no second run for one of them.

| Exit status | Meaning | Output |
| --- | --- | --- |
| 0 | The ref was forgotten | The `forgot` line on standard output |
| 1 | Nothing was forgotten: the ref is not recorded, or nothing is recorded for the repository | `simpici: repository acme/example (…): refs/heads/topic is not recorded` or `…: nothing is recorded` on standard error |
| 2 | The configuration has no repository of that name | `simpici: repository acme/exmaple is not configured in /etc/simpici/dispatcher.json` on standard error |
| 3 | The configuration cannot be read or is one `simpicid` refuses, or the state cannot be read, locked or written | `simpici:` and the reason on standard error |
| 64 | The options are not a request | The usage on standard error |

`--state` uses 0, 2, 3 and 64 in the same way. A name that the configuration
has more than once, with different clone URLs, is several repositories with a
state each: `--state` shows each, `--forget` forgets the ref in each that has
it and exits with 0 if one had.

Things to know before you use it:

- **Run it as the account the daemon runs as**, for example
  `sudo -u simpici simpici --config /etc/simpici/dispatcher.json …`. A state
  file that belongs to another account is refused with the exit status 3 and
  left alone: written by root, it and its lock would be files the daemon can
  no longer open, and the daemon would end at its next poll.
- A relative `root` in the configuration is resolved against the directory
  the command is started in, as for the daemon. Start it where the daemon is
  started, or use an absolute `root`.
- The daemon does not have to be stopped. `--forget` takes the lock of the
  repository and waits while the daemon polls it, in local mode until the
  build of that repository has ended, without printing anything meanwhile.
  `--state` never waits.
- The configuration is checked as the daemon checks it at its start; one it
  would refuse is refused here with the same words. Grants are not looked
  at, and no secret file is read.
- In the containers of section 5 the command runs in the poller service,
  which has the state and the account:

  ```sh
  docker compose exec poller simpici \
    --config /etc/simpici/dispatcher.json --state
  docker compose exec poller simpici \
    --config /etc/simpici/dispatcher.json \
    --repository acme/example --forget refs/heads/topic
  ```

  `compose.yaml` starts that service as `990:990`, the account the state
  directory was handed to, and `docker compose exec` runs a command as the
  user of its service, so no `--user` is needed. The `ssh` service runs as
  root: `--forget` there is refused with the exit status 3, unless it is
  started with `docker compose exec --user 990:990 ssh simpici …`.

To forget every ref of a repository at once, stop the daemon, delete the
`.json` file that `--state` names and start the daemon again. The repository
then counts as never read: its next poll is a first one and `build_initial`
decides whether its tips are built. That is the one difference to forgetting
its refs one by one, which leaves an empty state and builds whatever appears.
The daemon is stopped for it because a poll that is running may write the
file back.

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

`docker stop` sends the daemon `TERM`. During a run it first ends the run
and removes its job containers from the host daemon, then exits with `143`;
that takes well under the ten seconds `docker stop` waits. A daemon
container that is killed, by `docker kill` or because the stop ran out of
time, takes every process in it along, and the job containers of its run
stay on the host. `<root>/containers/<run>` then holds their label, see
[stopping a worker](#stopping-a-worker-and-a-worker-that-is-killed).

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
5. Publish only the public report projection; never publish the queue, the
   secret snapshots in `claims/`, internal events, credentials or workspaces.

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
  A value that contains `[REDACTED]` is rejected: it is the marker a
  redacted value is replaced by, and what stands in a secret file with it is
  usually a line copied from a published log instead of the value.
- Mirror entries need their own grants if both clone URLs may produce runs.
  Otherwise, the source actually used for the run determines the outcome.

The grants of all repositories are checked together, whether or not a run
would match them: when `simpicid` starts in dispatcher mode, and again by
`simpici-dispatch` before every claim. The check covers the name, the ref
patterns, the list shapes, the phases and the secret file, which must be
readable and hold one nonempty line without the marker `[REDACTED]`. A
failure names the configuration entry and the reason, never a value:

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
   remains private**, including its local `public` directory, and belongs to
   the worker alone: it removes the log and the checkout of every run. A
   `--root` that is the state of a dispatcher or of a `simpicid`, which has a
   `queue/`, `claims/` or `state/`, is refused and nothing is removed from
   it; a directory that only `simpici` made runs in is not recognised, so do
   not use one. Keep `KillMode` and `TimeoutStopSec` of the unit as they are,
   see [stopping a worker](#stopping-a-worker-and-a-worker-that-is-killed).
7. From the actual VM, verify network boundaries, allowed remotes, a test run
   and recovery after a reboot. Local stub tests do not replace these checks.

### Recovery and limits

The queue locks state changes and run numbers. Claims use atomic replacement
of JSON under a lock, not renames between `queued` and `running` directories.

Queue deduplication is based on `repository NUL ref NUL commit` and applies
across sources and mirrors. Polling observations, in contrast, are separate
for each repository and clone URL. Use different logical repository names for
independent mirror runs. A mirror that is reachable but temporarily without
refs keeps its recorded tips, and one that has none at its first poll gets no
baseline; section 2 describes the log lines and the limits of both rules. A
mirror has to finish its first synchronisation before it is polled.

Claims expire after the configured execution timeout plus 30 minutes for
checkout and transfer. Expired work is marked `interrupted`, **not
automatically run again**: a publish or deploy operation may already have
taken effect. There is no heartbeat, automatic publish retry or ready-to-use
retry/cancel operator CLI.

Nobody has to ask for that. `simpicid` in dispatcher mode ends the leases
that ran out at the beginning of every polling cycle, before it reads a
repository, and says so in its journal, one line per run:

```text
simpicid: run 7 interrupted: its lease expired without a completion
```

A run whose worker is gone is therefore `interrupted` within one `interval`
after its lease ran out, and its secret snapshot is removed in the same
step, see [where secret values are kept](#where-secret-values-are-kept-and-for-how-long).
The step needs no repository to be readable and no usable grant, and
`simpicid --once` takes it too, without a change to its exit status. Every
request of a worker takes the same step first, a claim as well as a
completion, so a dispatcher whose `simpicid` is stopped still notices an
expired lease when a worker connects; the journal line is written by the
daemon only. A completion that arrives while the daemon ends the lease of
its run is either recorded, with its redacted log, or refused as an `expired
claim`: the queue decides both under one lock, and whichever comes first
stands.

`simpici-dispatch` gives a worker 30 seconds to send its request and ends
with `simpici-dispatch request not read within 30 s` if it is not complete by
then, so that a sender that hangs does not keep a session. The limit covers
the reading alone. A request that was read is served to its end, however
long it waits for the queue or redacts a log of megabytes; ending it in the
middle would only make the worker send it again. On a slow link, where 8 MiB
of completion take longer than that, raise the limit with the top-level
setting `request_read_timeout`, a positive integer of seconds. It is read
for every request, so it needs no restart, and any other value fails every
request with `simpici-dispatch request_read_timeout must be a positive
integer`.

#### A claim that never reached its worker

A claim is saved before it is answered: the lease is written to the queue,
then the secret snapshot, then the answer goes out over SSH. If the
dispatcher dies between the first and the last of these, because the host
goes down, the container is stopped or the connection breaks while the
answer is on its way, **the run is leased to a worker that never heard of
it**. The dispatcher cannot tell that from a worker that received the claim
and was lost in the middle of a publish, and an answer over SSH cannot be
confirmed, so the run is not handed out again. It ends as every lost run
does:

- The run stays `running` for `timeout` plus 30 minutes. A worker that asks
  in that time gets the next queued run, or nothing.
- Then `simpicid` marks it `interrupted` in its next cycle and logs the line
  above. No log is published, because nothing ran.
- The worker has nothing of the run: no line that names it in its journal,
  no `secrets/<run>/`, no `completion.json` and no `rejected/<run>.json`. At
  the time of the claim its journal has `dispatcher connection failed` or
  `invalid dispatcher response` instead. That is what tells this case from
  a run that was lost on the worker, which leaves `removed orphaned` lines
  or a `rejected by the dispatcher` line there once the worker runs again.

An `interrupted` run is never run again by itself, and its commit is
deduplicated: polling the same ref on the same commit builds nothing. To
have it built after all:

- **Push a new commit** to the ref. It is a new run; nothing else is needed.
- **For the same commit**, a release tag for instance, there is no command.
  By hand, as the account of the daemon: make sure the run really did not
  take effect; stop `simpicid`; remove `<root>/queue/<run>.json`; forget
  the ref with `simpici --config FILE --repository NAME --forget REF`, see
  [forgetting one ref](#forgetting-one-ref); start `simpicid`. Its next
  cycle finds the ref new and queues the commit under a new run number, with
  the grants of the configuration as it is then. The report of the
  interrupted run stays under `public/runs/` and leaves `index.json` with
  the next run that is written. A worker that asks while the file is being
  removed may get an error and asks again.

The worker persists `completion.json` before uploading it. If an SSH response
is lost, the completion can therefore be retried idempotently without
rebuilding; [a completion that cannot be delivered](#a-completion-that-cannot-be-delivered)
describes what ends the retry. This is not an exactly-once guarantee for every possible crash
point: an interruption before the completion is persisted may already have
left external side effects.

A claim the worker cannot execute is reported instead of being left to its
lease. That is an event the worker refuses, for example a queue entry written
by hand or by a dispatcher of another version, a secret file or temporary
directory it cannot create, and a failure of the run supervisor itself. The
run becomes `failed` with exit code `125`, and its log ends with the reason:

```text
SimpiCI::Worker run 7 aborted: invalid event in claim
```

The log is published, so the reason is one of a fixed list and never the
text of the error. No path below the worker's `--root`, no file or line of
the worker installation and no value of the claim is in the log for it:

| Reason | What happened |
| --- | --- |
| `invalid event in claim` | The event is not one the worker accepts: its commit, ref, clone URL, repository or source is refused by the same rules the dispatcher enqueues by, or a field is missing or of the wrong type. A queue entry written by hand or by another version |
| `invalid secrets in claim` | The secrets of the claim are not phases with names and values |
| `invalid secret name in claim`, `invalid secret value in claim` | A secret is not one `NAME=VALUE` line, see [where secret values are kept](#where-secret-values-are-kept-and-for-how-long) |
| `invalid timeout in claim` | The `timeout` of the dispatcher configuration is not an integer |
| `cannot write secret files` | `<root>/secrets/<run>/` or a file in it could not be written |
| `cannot create temporary directory` | `<root>/tmp/<run>/` could not be created |
| `run supervisor failed` | The supervisor of the run gave up: it could not write a report, the checkout directory or another file below `<root>`, could not start a process, or could not report a run that was stopped. The log has what the run printed up to then |
| `internal error` | Anything else |

Nothing is executed for the first five, and no secret file is written. What
the error said is in the journal of the worker, in the same line after the
reason, with the file it is about and where it was raised:

```text
SimpiCI::Worker run 7 aborted: invalid event in claim: SimpiCI::Event clone URL must not contain a password; a user name alone is accepted, and SSH authenticates with a key of the account that runs git at /usr/local/share/perl/5.40.1/SimpiCI/Worker.pm line N.
SimpiCI::Worker run 7 aborted: run supervisor failed: SimpiCI::Store->write_json cannot publish /var/lib/simpici-worker/public/runs/7.json: Read-only file system at /usr/local/share/perl/5.40.1/SimpiCI/Runner.pm line N.
```

Assigned secret values are redacted from that line as from the log. The
journal is the operator's and is not published: its lines name files below
`--root` and the installation, one line for one event. `secrets/<run>/` is
removed after every outcome the worker process lives to see, also when the
completion could not be saved. Only a claim whose run is not a run number is
refused without a report: there is nothing to report it under.

A command of a run that cannot be started, because the worker has no `git`
or its `--executor` is no executable file, is not an aborted claim but a
`failed` run with exit code `126`. Its log ends with
`SimpiCI::Runner cannot start git: <reason>` or
`SimpiCI::Runner cannot start the executor: <reason>`, and the journal has
the same line with the path of the command. A local `simpicid` and `simpici`
do the same.

A run whose checkout or executor is ended by a signal, for example by the
kernel's out-of-memory killer, is reported as `signalled`, with the signal
and the exit code 128 plus its number: `137` for `SIGKILL`. The checkout
stops at the command that was ended, and the executor is not started on a
checkout that was cut off. The containers such an executor could not remove
are removed for it. A run that was ended because the worker itself was told
to end is `signalled` too, with `143` for `SIGTERM`, see
[stopping a worker](#stopping-a-worker-and-a-worker-that-is-killed).

#### A completion that cannot be delivered

While a `completion.json` waits under the worker's `--root`, the worker
sends it in every cycle and claims nothing. Two things can keep it from
being accepted, and they end differently.

**The dispatcher could not be asked, or failed.** There is no SSH
connection, it timed out, `simpici-dispatch` ended with an error such as an
unreadable configuration or a state directory it cannot lock or write, or
its answer did not arrive whole. The journal of the worker gets one of these
lines per cycle, below whatever `ssh` or `simpici-dispatch` wrote:

```text
simpici-worker: SimpiCI::Worker dispatcher connection failed at /usr/local/bin/simpici-worker line N.
simpici-worker: SimpiCI::Worker invalid dispatcher response at /usr/local/bin/simpici-worker line N.
```

`completion.json` stays and is sent again every ten seconds, for as long as
it takes. Nothing is lost as long as the lease of the run stands; repair the
connection or the dispatcher. None of these failures says what the
dispatcher did with the completion, so none of them ever ends the retry.

**The dispatcher answered that it will never accept it.** The answer is
`{"rejected":"<reason>"}` with one of three reasons:

| Reason | What happened | The run at the dispatcher |
| --- | --- | --- |
| `expired claim` | The lease was over when the completion arrived: run, checkout and upload took longer than `timeout` plus 30 minutes, or the worker could not reach the dispatcher for that long | `interrupted`: by the daemon's next cycle after the lease ran out, at the latest by this request. It is not run again |
| `stale claim` | The run is claimed under another worker name or token, for example because the `--worker` name of the forced command was changed during the run | Keeps the lease of its claimant until that expires |
| `unknown run` | The dispatcher has no such run: its state was replaced, or the worker was pointed at another dispatcher | None |

The worker does not send such a completion again. It moves the file to
`<root>/rejected/<run>.json`, says so once in its journal, and claims work
in the next cycle:

```text
SimpiCI::Worker completion of run 7 rejected by the dispatcher: expired claim; kept as rejected/7.json
```

Search the journal for `rejected by the dispatcher`, or look into the
directory; nothing else reports it. For each file:

1. **Check the external effects of the run.** It ran to its end on the
   worker, publish and deploy jobs included, although the dispatcher shows
   it as `interrupted` or not at all. `result` in the file is the state and
   exit code the worker would have reported, `log` the log it would have
   delivered. There is no other copy of the log: the worker removed the
   unredacted one when it saved the completion.
2. **Do not expect the dispatcher to run it again.** The commit is
   deduplicated like any interrupted run.
3. **Remove the file when you are done with it.** SimpiCI never reads,
   rotates or removes anything below `rejected/`. A file holds one
   completion, with a log of at most 4 MiB, and a second refusal of the same
   run replaces it, so the directory grows by one file per refused run.

The file is the request as it was sent, mode `0600` in a directory of mode
`0700`: the result, the claim token and the log in which the assigned secret
values are already redacted. The `secrets/<run>/` files of the run are
removed before a completion is sent. It is private worker state like the
rest of `--root` and is not to be published; the redaction covers the
literal values of the claim, not other sensitive output.

A refused completion can be delivered again only if the reason was a `stale
claim` or `unknown run` whose cause is repaired while the lease of the run
still stands: stop the worker, move `rejected/<run>.json` back to
`completion.json`, start the worker. An `expired claim` stays refused.

Install this version on the dispatcher and on the workers together. A
dispatcher of an earlier version fails where this one answers, so a worker
of this version keeps sending as before. A worker of an earlier version
takes the answer for an acceptance and removes the completion without
keeping it.

#### Where secret values are kept, and for how long

Besides its file under `/etc/simpici/secrets`, a granted value is written to
two places and is in the environment of the job containers, and a job that
prints it or writes it to a file puts it in more. All of it is private
state: nothing of the dispatcher's is below its `public/`, and the worker's
`public/` directory is not to be served either. On the worker, nothing that
can hold a value in the clear outlasts its run, with two exceptions that are
described below: what a killed worker left, until it starts again, and files
a job wrote as another account than the worker.

| Where | Content | Removed |
| --- | --- | --- |
| Dispatcher, `<root>/claims/<run>.json` | The values handed out with the claim, in the clear, mode `0600`. Written for every claim, also one without secrets | When the completion of the run is accepted and recorded, and otherwise when the lease has run out: by the next polling cycle of `simpicid`, or by a worker's request if that comes first |
| Worker, `<root>/secrets/<run>/publish.env` and `deploy.env` | One `NAME=VALUE` line per secret, passed to the jobs of that phase | When the run ends, whichever way; after a killed worker, by the next start |
| Worker, the publish and deploy containers of the run | The values of their phase, as environment of the container | With the container: when its job ends, and within seconds when the run is ended by its timeout, by a signal for the worker or after a killed worker. What survives even that is removed by the next start |
| Worker, `<root>/public/runs/<run>.log` | Whatever the jobs printed, unredacted | When the completion of the run is saved, before it is sent; after a killed worker, by the next start |
| Worker, `<root>/tmp/<run>/` | The same output once more, per job, as `simpici.*/log.<phase>.<job>`; the output and artifact directories of the jobs | With the log. Files a job wrote as another account can stay, see below |
| Worker, `<root>/work/<run>/` and `<root>/runs/<run>/` | The checkout, which jobs cannot write to, and the event of the run | With the log |
| Worker, `<root>/completion.json` | The result, the claim token and the last 4 MiB of the log, with the values of the claim redacted | When the dispatcher accepted it. One it refuses for good is moved to `rejected/` |
| Worker, `<root>/rejected/<run>.json` | The same, for a completion the dispatcher refused | Never by SimpiCI |
| Worker, `<root>/public/runs/<run>.json` and `index.json` | The report: repository, ref, commit, state, exit code and times. No log and no value | Never by SimpiCI; a few hundred bytes per run |

The rest of a worker's state root holds no output of a job: `instance`,
`counter`, `counter.lock`, `worker.lock` and, while a run lasts,
`containers/<run>` with the label of its containers.

**Dispatcher.** The snapshot is what the log of the run is redacted from, so
a value rotated during the run is still found. It is removed only after the
redacted log is published and the result is recorded: a dispatcher that dies
in between keeps the file, and the worker's retry is redacted from it.

Everything else goes with one step, which `simpicid` takes at the beginning
of every polling cycle and `simpici-dispatch` before every request, a claim
or a completion: it marks the runs whose lease ran out as `interrupted` and
removes the snapshots of all runs that can no longer be completed. Those are
the expired leases, completed runs whose dispatcher died before it removed
the file, and the files a version before this one never removed, which go
with the first cycle or request after the upgrade. A file in `claims/` that
is not a snapshot is left alone.

**A snapshot therefore outlives its lease by one polling cycle at most:**
`timeout` plus 30 minutes from the claim, plus `interval` and the time the
cycle before it took. No worker has to connect for that. A repository that
cannot be read, or that hangs for its `ls_remote_timeout`, does not hold the
step back, because it comes first in the cycle. Three things do, and each
leaves the files where they are:

- `simpicid` is not running, or runs in local mode. Then only a worker's
  request removes them. With the daemon stopped and the workers gone for
  good, remove the files in `claims/` by hand.
- A file cannot be removed. The daemon ends with `SimpiCI::Dispatcher cannot
  remove secret snapshot <file>: <reason>`, and so does every request, until
  it can.
- The lease still stands. A snapshot is never removed before that, whatever
  became of the worker: its completion could still arrive.

The directory needs no backup and should be left out of one.

No log is published that the snapshot did not redact. If the snapshot of a
run is missing when its completion arrives, the result is recorded and the
log is replaced by one line:

```text
SimpiCI::Dispatcher log of run 7 withheld: no secret snapshot to redact it with
```

That happens only if the file was removed while the run was leased. The log
is then lost: the worker removed its own copy when it saved the completion,
and the completion is gone once the dispatcher has accepted it.

**Worker.** A secret is written only as one `NAME=VALUE` line. A claim with a
secret that is not one, such as an undefined or empty value, a structure
instead of a string, a value with a line end, a value that contains the
marker `[REDACTED]` or a name that is not `CICD_<NAME>` or `<NAME>_TOKEN`, is
not executed: the run becomes `failed`
with exit code `125` and the reason `invalid secret name in claim` or
`invalid secret value in claim`, which names neither the secret nor its
value. The dispatcher grants nothing of that kind, so this points to a
dispatcher of another version.

A worker process that is killed during a run cannot remove `secrets/<run>/`.
The worker removes everything below `secrets/` at its next start, before it
connects to the dispatcher, and again at the beginning of every cycle, and
says so in its journal:

```text
SimpiCI::Worker removed orphaned secret files: secrets/7
```

The line means that run 7 was cut off. It is not repeated: it keeps its
lease until that expires and is then `interrupted`, so check its external
effects as for any lost worker. If an entry below `secrets/` cannot be
removed, the worker logs `cannot remove secret files` with the path in every
cycle and neither delivers a completion nor claims work until it is gone.
Until the worker starts again, the files of the killed run stay where they
are; a VM that is taken out of service has to be cleaned by hand.

**What the jobs printed and wrote.** The log of a run is written as the jobs
print, unredacted, because a value can only be redacted once it is whole.
It is on the worker's disk for as long as the run lasts and no longer: the
worker redacts it into the completion, saves that, and removes the log, the
checkout, the executor's temporary files and the event of the run before it
sends anything. That holds for every way a run ends, also for a claim the
worker could not execute and for a completion it could not save. A
completion that waits for a dispatcher that cannot be reached, for hours if
need be, therefore waits without an unredacted log beside it.

A worker that was killed during a run left all of that behind. The next
start removes it before it connects to the dispatcher, with one journal line
per entry:

```text
SimpiCI::Worker removed orphaned run files: public/runs/7.log
SimpiCI::Worker removed orphaned run files: runs/7
SimpiCI::Worker removed orphaned run files: tmp/7
SimpiCI::Worker removed orphaned run files: work/7
```

Every cycle does the same, so the rule is simple: **when a worker asks for
work, its state root holds no log and no files of any run.** A log that
cannot be removed stops the worker like a secret file that cannot be: it
logs `cannot remove the log of a run` with the path in every cycle and
neither delivers nor claims until the log is gone.

**Upgrading from a version that kept everything.** Earlier versions never
removed a log, a checkout or a temporary file. The first start of this
version removes all of them, every `public/runs/*.log` and everything below
`work/`, `tmp/` and `runs/`, and names each in the journal. Copy what you
want to keep before you upgrade, and expect that first start to take as
long as removing the checkouts takes. The reports `public/runs/*.json` and
`rejected/` are kept. A worker that finds `queue/`, `claims/` or `state/`
under its `--root` removes nothing and logs in every cycle

```text
simpici-worker: SimpiCI::Worker root is the state of a dispatcher or a daemon, it has queue/: /var/lib/simpici at ...
```

because there the logs are the published ones.

**Files of another account.** A job runs as whatever user its image and the
container daemon give it, and what it writes to its output and artifact
directories below `tmp/<run>/` belongs to that user on the host. The worker
can remove a file in a directory it owns, but not what lies in a directory
that another account created. That is the case

- under rootful Docker, where a container's root is the host's root, for
  every directory a job created;
- under rootless Docker or Podman, for a directory created by a job that
  does not run as the container's root, or that changed its owner.

The worker removes what it can, which always includes the log, the checkout
and the per-job output files the executor kept, says once per start what is
left,

```text
SimpiCI::Worker cannot remove run files: tmp/7
```

goes on with the next claim and tries again in every cycle. What is left is
only what the jobs themselves wrote: if a publish or deploy job wrote a
secret value into its output directory, it is still there. Remove such
directories with an account that may, for example from a timer:

```sh
# rootless Podman: as the worker account, inside its user namespace
podman unshare find /var/lib/simpici-worker/tmp -mindepth 1 -maxdepth 1 -mmin +120 -exec rm -rf {} +
# rootful Docker: as root
find /var/lib/simpici-worker/tmp -mindepth 1 -maxdepth 1 -mmin +120 -exec rm -rf {} +
```

Choose the age well above `timeout`, so that no directory of a run in
progress is removed; under rootless Docker, enter the user namespace of the
daemon in the way your setup provides. Under rootless Docker or Podman with
jobs that run as the container's root, which is what the official `debian`,
`perl`, `node` and `python` images do, everything belongs to the worker
account and nothing is left.

A completion the dispatcher refused and the worker put aside under
`rejected/` is no further place for a value in the clear: its log was
redacted with the values of the claim before the completion was saved. It
is kept until an operator removes it, see
[a completion that cannot be delivered](#a-completion-that-cannot-be-delivered).
A completion that a killed worker was still writing,
`.completion.json.tmp.<pid>`, holds the same redacted log and is removed by
the next start.

Neither removal is a secure erase. The files are unlinked; what the file
system, a snapshot or a backup keeps of them is outside SimpiCI.

#### Stopping a worker, and a worker that is killed

A job container is started by the Docker daemon. It is no process of the
worker's unit, so nothing systemd does to the unit reaches it, and the
executor runs in a process group of its own, so a signal for the worker
alone does not reach it either. The worker therefore ends its run itself.

**`systemctl stop`, `TERM`, `INT`, `HUP`.** Between two runs the worker ends
at once. From the claim to the end of a run, at whatever point the signal
arrives, it starts no further command of the run and

1. sends `TERM` to the process group of the executor, which kills and
   removes the containers it started, and `KILL` to what is left of the
   group after five seconds;
2. asks Docker for the containers with the label of the run and kills and
   removes those that are still there;
3. saves the completion of the run, with the state `signalled`, the exit
   code `143` for `TERM` and the redacted log;
4. removes the secret files, the log and the files of the run, and ends by
   the signal it received.

```text
SimpiCI::Runner removed containers of run 7: 2
SimpiCI::Runner run 7 stopped by signal TERM
```

The first line appears only if the executor left containers behind. The
completion is not sent on the way out. The next start sends it, and the
dispatcher records the run as `signalled`; if the worker stays down longer
than the lease, `timeout` plus 30 minutes from the claim, the completion is
refused as an `expired claim` and kept under `rejected/`. Publish and deploy
jobs that had already run are not undone, and the run is not repeated.

The [worker unit](simpici-worker.service) is written for this. Keep
`KillMode=control-group`: systemd then sends `TERM` to the worker and to the
executor at the same time, which is harmless, and gives what is left of the
unit after a worker that died the same `TERM` and the same time. With
`KillMode=mixed` the rest of the unit never gets a `TERM` from systemd, only
its `KILL`, and that also ends the process that ends the run of a dead
worker: the containers of that run then stay until the next start.
`TimeoutStopSec=60` is the time the worker has for the four steps before
systemd kills it; they take well under a second with a daemon that answers
and are limited to 30 seconds per Docker command with one that does not.

**`KILL`, the out-of-memory killer, a crash.** The worker can do nothing.
A process it started beside the executor notices that the worker is gone and
does steps 1 and 2 in its place, within seconds. It writes to the journal
only if it could not remove the containers. Nobody saves a completion: the
run keeps its lease and becomes `interrupted` when that expires. The secret
files, the log and the files of the run stay until the worker starts again;
the next start removes them and says so, as described above.

That process holds the lock of the state root until it is done. A worker
that is started in those seconds ends with `simpici-worker already running`;
`Restart=on-failure` starts it again ten seconds later.

**Everything of the unit killed at once.** If the worker, the executor and
that process are killed together, as by `systemctl kill -s KILL` or by a
stop that ran into `TimeoutStopSec`, the containers of the run are still
there, and so is the file `<root>/containers/<run>`. At its next start the
worker removes every container that carries the label of its instance,
before it removes anything else or connects to the dispatcher:

```text
SimpiCI::Worker removed orphaned containers: 2
```

If Docker cannot be asked, or a container is still there afterwards, the
worker logs `cannot remove orphaned containers` with the reason in every
cycle and neither delivers a completion nor claims work until it could. The
secret files, the log and the files of the run that was cut off do not wait
for Docker: they are removed in the same cycle.

**Which containers.** Every container the executor starts for a worker
carries two labels: `simpici.instance=<instance>` and
`simpici.run=<instance>.<run>`. The instance is 32 random hexadecimal digits
in `<root>/instance`, written at the first start and never changed. The
worker asks Docker for exactly one of these labels and passes on only what
it gets back, so it never touches a container without the label: not that
of another workload on the host, and not that of a second worker with
another `--root` on the same daemon. A copy of a state root is the same
instance; remove `instance` from a copy before a worker runs on it beside
the original. To look for yourself, or to clean a VM whose worker will not
start again:

```sh
docker ps -a --filter "label=simpici.instance=$(cat /var/lib/simpici-worker/instance)"
```

A worker that was started to ignore a signal, as `HUP` under `nohup`, is
not ended by it, and neither is its run.

**What this does not reach.** A container or a build that a job started
itself through the Docker socket of a build or publish job carries no label
and is not removed; neither is a process that left the process group of the
executor. A VM that is switched off keeps what the worker would have
removed at its next start. And an ended publish or deploy job may have done
half of its work.

The same rules hold for a local `simpicid` and for `simpici`, which use the
same run supervisor: `TERM`, `INT` and `HUP` during a run end the run, its
process group and its containers, the run is reported as `signalled`, and a
killed daemon leaves a process that does it in its place. They differ in two
points. They keep the logs, checkouts and temporary files of their runs, as
before. And they do not look for orphaned containers at their start, because
nothing keeps two of them from running on one state root: after everything
of such a daemon was killed at once, remove the containers by hand with the
label in `<root>/containers/<run>`.

#### Redaction

The dispatcher reconstructs public metadata; the worker and dispatcher redact
assigned literal secret values from uploaded logs, with the same function.
Every occurrence of every value of the claim becomes `[REDACTED]`, in
whichever order the values are taken: where one value begins another one, or
two of them overlap in the output, nothing of either is left, and values that
overlap or stand side by side become one marker. This does not detect
arbitrary sensitive information, a value a job prints encoded or split, or
intentional exfiltration.

The dispatcher redacts a log the worker has redacted already, so a marker in
the text is treated as one and not as output of the job: a value is not
looked for inside a marker or across one of its ends. Otherwise a value that
is a piece of `[REDACTED]`, such as `RED` or `E`, or one that begins with
`]`, would be replaced in the worker's markers and show in the published log
what it is. Redacting a log twice gives what redacting it once gives, for
every value a grant can carry. That holds between a worker and a dispatcher
of this version: a dispatcher of an earlier one still looks for values in
the worker's markers, so install both together. Three consequences:

- A value that contains `[REDACTED]` cannot be a secret, see
  [secret grants](#understand-secret-grants).
- A marker that a job or one of its tools prints itself stays as it is, and a
  value is not found where it would share characters with that marker. A
  value directly before or behind a marker is redacted as everywhere else.
- A secret of a few characters is redacted wherever those characters stand,
  in ordinary words too. That shows where it was, which no redaction can
  avoid; use values that do not occur by chance.

Final logs are limited to the last 4 MiB, and the cut never falls into a
marker: one it would split is left out as a whole. Live logs
and artifacts are not transferred, and the worker keeps neither: checkouts,
outputs and artifacts are removed with the run, see
[where secret values are kept](#where-secret-values-are-kept-and-for-how-long).
A worker still needs disk for the largest run and for the images its daemon
pulls; SimpiCI removes no image.

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

What the poller has recorded for a repository is shown, and one ref of it
forgotten, with `simpici` inside the poller service:
`docker compose exec poller simpici --config /etc/simpici/dispatcher.json --state`.
[The recorded tips of a repository](#the-recorded-tips-of-a-repository)
describes the command and why it has to run in that service.

A repository the poller cannot read, such as one whose organization does not
exist on the forge yet, no longer restarts the container. The poller logs a
`not polled` line for it in every cycle, keeps polling the others and picks
the repository up once it is readable; section 2 describes the line and what
is built then. A repository that exists but returns no refs while refs of
its last poll are missed gets such a line as well, and so does one that has
no refs at all yet. Look for these lines in
`docker compose logs poller`: nothing else reports a repository that is never
read.

The poller is also what ends a lease that ran out: its log has an
`interrupted` line for each such run, and the secret snapshot of the run
leaves `state/claims/` in the same cycle, see
[recovery and limits](#recovery-and-limits). With the `poller` service
stopped, both wait for the next request of a worker.

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

A log is what git and the executor printed. SimpiCI itself adds three kinds
of lines to it, none of which names the state root, a file or line of the
installation or a value: that a run was stopped by a signal, that a command
could not be started, and, behind a dispatcher, that
[a claim was aborted](#recovery-and-limits) or that the log was withheld.
The checkout is made quietly for the same reason. What the tools print is
not looked at: `git fetch` names the clone URL of the event, and an error of
git, of the container runtime or of a job can name a path of the host.

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
