# Executor Reference

[README](../README.md) · [Cookbook](cookbook.md) · [Operations](../deploy/README.md)

This reference describes the existing `bin/simpici-executor`, not the
planned branch policy. The executor is a Bash program. Native Perl entry
points and the composite action call the same executor, but supply different
event, checkout and reporting contexts.

## Invocation and responsibilities

```sh
CICD_WORKSPACE="$PWD" SIMPICI_PROVIDERS='' SIMPICI_PLAN_ONLY=true \
  /path/to/simpici/bin/simpici-executor
```

The executor currently has **no CLI argument parser**. `--help`, `--dry-run`
and `--workspace` are not supported options. Use environment variables.
The `--help` options of the native Perl programs are independent of this.

Host prerequisites are Bash 4.3 or later and common Unix utilities such as
`mktemp`, `cp`, `sort`, `cut`, `uniq`, `tee` and `date`. The direct executor
does not determine Git HEAD metadata itself. Git is needed in particular for
native checkouts and polling; actually running providers and jobs requires
the Docker CLI and a reachable Docker daemon. `jq` is not an executor
dependency. The native programs also need their Perl dependencies.

The direct executor:

- uses an existing checkout;
- does not create a fresh Git checkout itself or check whether its contents
  match the specified `CICD_COMMIT`;
- does not create a native queue or native store;
- runs providers, assembles the effective job plan and starts its phases;
- does not replace prior authorization of repository code.

The native runner is responsible for an exact detached checkout, as is the
preceding checkout step in hosted operation.

## Key host settings

| Variable | Meaning |
| --- | --- |
| `CICD_WORKSPACE` | Absolute path to the existing target checkout; set explicitly for local invocations. |
| `SIMPICI_CONCURRENCY` | Maximum concurrent jobs per phase; defaults to `2`, `1` means serial execution. Invalid values and `0` currently fall back to `2`. |
| `SIMPICI_PROVIDERS` | Whitespace-separated OCI images that generate jobs; an empty value means no providers. |
| `SIMPICI_PLAN_ONLY` | Exactly `true` displays the job plan without starting job containers. Providers still run beforehand. |
| `SIMPICI_SECRETS_DIR` | Private directory with optional `publish.env` and `deploy.env` files; passed only to the respective phase. |
| `SIMPICI_INSTANCE` | Set by the native runner and the worker, not by hand: the 32 hexadecimal digits of their state root. With it, every container the executor starts is labelled, see [Containers of a run](#containers-of-a-run). Any other value ends the executor with exit `64`. |
| `DOCKER_HOST` / Docker context | Selects the Docker endpoint. A Unix socket can be mounted in build/publish; a TCP/TLS daemon is not automatically passed through to job containers. |
| `RUNNER_TEMP` / `TMPDIR` | Base directory for temporary data; keep outside the checkout. Defaults to `/tmp` if neither is set. |
| `GITHUB_STEP_SUMMARY` | Optional hosted path for a Markdown summary. |
| `CICD_IMAGE_REPOSITORY` | Target image chosen by the entry point, for example `ghcr.io/acme/example`; also passed to build jobs. |

The temporary working tree defaults to
`${RUNNER_TEMP:-${TMPDIR:-/tmp}}/simpici.XXXXXXXX`. Output and artifacts are
separated there by phase and job. A custom temporary directory inside the
checkout can cause copies and archives to include their own output.
The temporary directory's parent must exist. At the end, the executor removes
known containers, but does not automatically remove this temporary working tree.
It holds the output of every job as a file `log.<phase>.<job>`, unredacted,
next to the output and artifact directories. The distributed worker gives each
run a temporary directory of its own, `<root>/tmp/<run>`, and removes it when
the run is over. With the native runner and in hosted operation, retention
is an operational responsibility.

The existing registry handoff also uses `CICD_REGISTRY`,
`CICD_REGISTRY_USER`, `CICD_REGISTRY_PASSWORD` and `CICD_PUBLISH_IMAGE`.
Credentials belong at a trusted entry point, not in the candidate checkout.
The distributed worker also materializes dispatcher grants as private secret
files, only for an event it accepts and only until the run ends; a claim it
cannot execute is reported as `failed` with exit code `125` and one of a
fixed list of reasons, see
[Limits of output, logs and reports](#limits-of-output-logs-and-reports). It
writes each secret as one `NAME=VALUE` line of `publish.env` or `deploy.env`
and refuses, in the same way, a claim with a secret that is not one: an
undefined or empty value, a structure, a value with a line end, a name other
than `CICD_<NAME>` or `<NAME>_TOKEN`. The files of a worker that was killed
during a run are
removed when the worker starts again, and so are the log, the checkout and
the temporary files of that run. See
[Operations](../deploy/README.md#where-secret-values-are-kept-and-for-how-long).

## Variables inside jobs

Job scripts should use these variables instead of hardcoding host paths.
Unavailable context values may be empty in direct or hosted mode;
the native event contract is stricter than the executor's event synthesis.
Without context being set, `CICD_REF` and `CICD_COMMIT` are empty, the repository
is `unknown`, the event is `push` and the run ID is `0`. Without Forgejo context,
the source falls back to `github-actions` even for local invocations.
For traceable local runs, therefore, set at least `CICD_SOURCE=manual` and
`CICD_COMMIT="$(git rev-parse HEAD)"` yourself.

The source values `github-actions` and `forgejo-actions` represent hosted
context, not valid `source` values in the native `SimpiCI::Event` contract.
Branch and tag are derived from the ref, not accepted independently.

The executor reconstructs its job event from `source`, `event`, `repository`,
`clone_url`, `ref` and `commit`. An additional native `payload` is not
automatically passed through to the job event. Arbitrary custom host
environment variables do not automatically become job variables either.

| Variable | Meaning |
| --- | --- |
| `CICD_RUN_NUMBER` | Run ID supplied by the native or hosted entry point |
| `CICD_SOURCE` | Source, such as `git-poll`, `manual`, `github-actions` or `forgejo-actions` |
| `CICD_EVENT` | Event, such as `push` or `pull_request` |
| `CICD_REPOSITORY` | Repository identity from the entry point |
| `CICD_CLONE_URL` | Clone URL, if provided by the entry point, without credentials; see [The clone URL of a run](#the-clone-url-of-a-run) |
| `CICD_REF` | Ref context, canonical as `refs/...` in native mode |
| `CICD_BRANCH` / `CICD_TAG` | Branch or tag derived from the ref; otherwise empty |
| `CICD_COMMIT` | Commit metadata; does not by itself validate the direct workspace |
| `CICD_PHASE` / `CICD_JOB` | Phase and unique job name within that phase |
| `CICD_IMAGE_REF` | Resolved job image |
| `CICD_IMAGE_REPOSITORY` | Desired target for custom container builds, if configured |
| `CICD_EVENT_FILE` | Event JSON mounted read-only |
| `CICD_WORKSPACE` | Read-only checkout and working directory |
| `CICD_ROOT` | Effective read-only job plan, including provider files |
| `CICD_OUTPUT` | Writable working directory for this job alone |
| `CICD_ARTIFACTS` | Writable artifact directory of this job; jobs of later phases read it through `CICD_INPUTS` |
| `CICD_INPUTS` | Always `/inputs`; holds `<phase>/<job>/` for each job of an earlier phase, read-only. The directory is absent in the first phase that has jobs |

Only `publish` and `deploy` jobs receive the registry variables
`CICD_REGISTRY`, `CICD_REGISTRY_USER`, `CICD_REGISTRY_PASSWORD` and
`CICD_PUBLISH_IMAGE` through the designated handoff. Of these, a dispatcher
grant can supply only `CICD_REGISTRY_PASSWORD`, which the executor passes
through. The other three and every variable in the table above are assigned
by the executor and are rejected as secret names.

This phase boundary is **not a complete trust boundary**: an untrusted
candidate could include its own publish script. The decision about which
credentials a run may receive at all belongs before the executor.
`CICD_PUBLISH_IMAGE=false` is a convention for scripts, not a technical
barrier to publishing.

### The clone URL of a run

The executor uses the clone URL for nothing itself. It fetches nothing and
passes the value to no command as an option: it writes it into the event
file, which providers and jobs get read-only, and into the environment of
every job as `CICD_CLONE_URL`. Where the value comes from decides what it
can be:

- **Native runs.** The runner and the worker hand over the clone URL of
  their event, which is one of the
  [accepted clone URLs](../deploy/README.md#accepted-clone-urls): no
  credentials, no remote helper, nothing that begins with `-`. The executor
  passes it on as it is, a user name such as `ssh://git@host/path` included.
- **Hosted and direct runs.** The value is `CICD_CLONE_URL` of the caller's
  environment, or `<server URL>/<repository>.git` from `GITHUB_SERVER_URL`
  or `FORGEJO_SERVER_URL` if the caller sets none. The executor does not
  hold it against the native rule: its form, its scheme and whether it names
  a repository at all are the responsibility of the workflow or of whoever
  calls the executor, and a job must not treat it as checked.

One thing the executor does in every case, because every job of every phase
gets the value: it leaves out a user part that the native rule does not
accept. The user part is what stands between `://` and the last `@` ahead of
the first `/`. Only the user name of an `ssh://` or `file://` URL stays, if
it contains no `:` and no `%3A`; behind every other scheme a lone user part
may be a token and is left out too. Without a scheme it is the
`user:password` of `user:password@host:path`. `https://user:token@host/path`
and `https://token@host/path` become `https://host/path`,
`ssh://user:password@host/path` becomes `ssh://host/path`, and the executor
writes one line to standard error that names no part of the URL:

```text
SimpiCI: CICD_CLONE_URL carried credentials; its user part is not passed on to the jobs
```

A password that contains a `/`, or one in the path or the query of the URL,
is not recognised and is passed on. Credentials for a job do not belong in
the clone URL.

### The event file

The same holds for the other values of a hosted or direct run. `CICD_REF`,
`CICD_COMMIT`, `CICD_REPOSITORY`, `CICD_SOURCE` and `CICD_EVENT` come from
the caller's environment or from the hosted context and are not held
against the native event rules: that the ref is canonical, that the commit
is a full object id and that it is the commit of the checkout are the
responsibility of the workflow or of whoever calls the executor. A job must
not take them for checked values.

The one thing the executor requires of the six values it writes into the
event file, `source`, `event`, `repository`, `clone_url`, `ref` and
`commit`, is that the file can hold them: none contains a line end or
another control character. Otherwise it writes no event file, starts no
provider and no job, and exits with `65` and one line on standard error
that names the field and not the value:

```text
SimpiCI: event field ref must not contain a line end or another control character
```

A control character is a byte below `0x20` or `0x7f`; a `"` or a `\` is
escaped, and everything else is written as it is. A native event never has
such a value: `SimpiCI::Event` refuses a control character in each of these
fields, so the check is a second line there and the only one for a hosted
or direct run.

## Job files, images and phases

- Only top-level files in the effective `.cicd` plan are jobs. For example,
  `lib/` can hold shared helper files.
- The format is `<image>+<phase>[.<job>].sh`. Job filenames do not support
  `@sha256:` digests or registry port numbers. Single-component names without
  a tag must be one of the aliases `linux`, `perl`, `node` or `python`.
- Without `.job`, the image expression becomes the job name.
- The phase and job name pair must be unique. The same job name may appear
  in different phases, but not twice in the same phase.
- The executor starts the executable script directly, with the event file path
  as its first argument. The shebang, executable bit and image interpreter
  must match. An existing image `ENTRYPOINT` remains in effect.

| Phase | Order | Details |
| --- | --- | --- |
| `prepare` | 1 | Preliminary checks; no shared persistent job environment |
| `build` | 2 | Before tests; an available Docker socket is mounted |
| `test` | 3 | Before package and publish |
| `package` | 4 | Reads earlier artifacts through `CICD_INPUTS` |
| `publish` | 5 | Registry handoff; an available Docker socket is mounted |
| `deploy` | 6 | Registry handoff, but no automatic Docker socket mount |

A socket mount depends on a suitable socket being available.
Docker access effectively means control over the Docker host. The read-only
workspace mount does not reliably limit these privileges.

Within a phase, all jobs run under the concurrency limit. The decision about
whether the next phase may begin is made only after the entire phase batch
has finished; this is not an immediate fail-fast abort.

| Result | Meaning |
| --- | --- |
| Job exit `0` | Job succeeded |
| Job exit `78` | Job deliberately skipped |
| Other job exit | Phase failed; later phases do not run |
| All existing jobs skipped | Executor currently exits with `0`, not a distinct overall `skipped` status |
| No jobs present | Executor exit `127`; at least one repository or provider job must exist |
| Job plan error | For example, exit `64` for invalid names or duplicate job IDs |
| Event value with a line end or another control character | Executor exit `65` before any provider or job starts, see [The event file](#the-event-file) |

Provider or host errors can produce other nonzero codes. The executor has no
per-job timeout option of its own; the native runner limits the executor's
runtime. On TERM and INT the executor kills and removes the containers it
started, all of them in one `docker kill` and one `docker rm -f`, and exits
with `143` or `130`. From the first signal on it ignores further ones. It
knows a container from the `--cidfile` Docker writes for it, so a container
that is still being created when the signal arrives can be missed; the
native runner finds it by its label.

## Containers of a run

A job container is started by the Docker daemon, not by the executor: it is
no member of the executor's process group, does not end when the executor
does, and a service manager that ends the processes of a unit does not reach
it. The native runner and the worker therefore mark the containers of a run
and remove them themselves.

- The executor is given `SIMPICI_INSTANCE`, the random value in the file
  `instance` below the state root. Every provider and job container then
  carries two labels: `simpici.instance=<instance>` and
  `simpici.run=<instance>.<run>`. Hosted runs and direct invocations set no
  instance and get no labels.
- While the executor of a run is running, `<root>/containers/<run>` holds the
  second label. The file is removed once the containers of the run are known
  to be gone.
- The runner ends the executor, with `TERM` to its process group and `KILL`
  five seconds later for what is left of it, when the run is not over within
  `timeout` and when the runner itself receives `TERM`, `INT` or `HUP`, at
  whatever point of the run: a checkout that is told to end starts no
  executor. A signal the runner was started to ignore, as `HUP` under
  `nohup`, ends nothing. A run that was ended for a signal of the runner is
  `signalled` with that signal, and its log ends with
  `SimpiCI::Runner run <run> stopped by signal TERM`.
- Only an executor that exits with `0` has seen every job it started end.
  After every other end, a failure as well as a signal, the limit or a stop,
  the runner lists the containers with the label of the run, kills and
  removes them, and lists again. Whatever the executor left running in its
  process group is killed when it is over, in any case.
- A runner that is killed cannot do that. A process it starts in the group of
  the executor notices that the runner is gone and does the same, without a
  report: the run stays `running` in the native store, and in the dispatcher
  until its lease expires.
- What nobody removed, because runner and executor were killed together, is
  removed by the **worker** at its next start: a file below `containers/`
  makes it remove every container with the label of its instance before it
  does anything else. `simpicid` and `simpici` do not: they take no lock on
  their state root, so one of them cannot tell an orphaned container from
  that of a run in progress. There the file stays and names the label to
  look for: `docker ps -a --filter label="$(cat <root>/containers/<run>)"`.

Only containers with exactly the label of the own instance are ever passed
to `docker kill` or `docker rm`. A second worker on the same daemon has
another state root and so another instance; a copied state root has the
same one, so remove `instance` from a copy before it is used beside the
original. A container that a job itself starts through the Docker socket of
a build or publish job has no label and is not found, and neither is a
process that leaves the process group of the executor.

The native runner turns the way the executor ended into the state of the run:

| End of the executor | State | `exit_code` in the report |
| --- | --- | --- |
| Exit `0` | `success` | `0` |
| Exit `78` | `skipped` | `78` |
| Any other exit | `failed` | That exit code |
| Not over within `timeout` | `timed_out` | `124` |
| Ended by a signal | `signalled`, with the number as `signal` | `128` plus the signal, such as `137` for `KILL` |

A signal is never an exit code of `0`. The executor turns TERM and INT into
the exits `143` and `130` itself, so `signalled` is what a signal it cannot
handle leaves behind, such as the `KILL` of an out-of-memory killer. The same
rule holds for the four git commands of the native checkout: one that a
signal ends, or that exits with anything but `0`, ends the run with that
result, and neither the next command nor the executor starts. A job
container that a signal ends is an ordinary job failure: Docker reports it
as the exit `128` plus the signal.

The desired future semantics of the overall status must not be confused with
this current behavior. The executor produces logs and a summary, but not a
complete native run lifecycle.

## Provider contract

A provider is an OCI image with a suitable entrypoint. In particular, the
executor provides it with:

- the checkout, read-only, as `CICD_WORKSPACE`;
- the event, read-only, as `CICD_EVENT_FILE` and as a command argument;
- its own writable directory as `CICD_PROVIDER_OUT`;
- event context such as repository, ref, branch, tag and commit. This is not
  the complete job environment block: for example, the run ID and clone URL
  are not explicitly passed to the generator as separate variables.

The provider writes ordinary executable job files there, along with helper
files if needed. It receives neither registry credentials nor a Docker socket
through this contract. This does not make it a generally safe sandbox;
it remains executable code, and the jobs it generates later run with the
capabilities allowed for the run.

Merge priority: repository before first provider before second provider, and
so on. Files with the same name are not overwritten by later sources.
The effective plan is located at `CICD_ROOT`; provider files do not change
the original `.cicd` in the checkout.

Digest pinning and organizational ownership are not enforced. A provider error
causes preparation to fail, even with exit `78`; skip semantics apply only to
jobs. Plan-only runs the providers because their results are needed to assemble
the complete plan.

## Limits of output, logs and reports

- Job output is private. Job artifacts are readable by jobs of later phases of
  the same run through `CICD_INPUTS`, never by jobs of the same phase or by
  another worker.
- `CICD_INPUTS/<phase>/` exists only for an earlier phase that had jobs, and
  `CICD_INPUTS/<phase>/<job>/` is the complete `CICD_ARTIFACTS` of that job. A
  job that wrote nothing, such as one skipped with exit `78`, leaves an empty
  directory; a later job must check for the file it needs instead of assuming
  it. A failed phase stops the run, so a later phase never reads the artifacts
  of a failed job.
- There is no built-in hosted artifact upload or artifact transfer back from
  the worker to the dispatcher.
- Native local logs are written unfiltered and kept. Removing private fields
  from a report JSON is not log redaction.
- A log is the output of git and of the executor. The lines the native
  runner, the worker and the dispatcher add to it are fixed phrases that name
  no path of the state root, no file or line of the installation and no
  value: `SimpiCI::Runner run <run> stopped by signal <signal>`,
  `SimpiCI::Runner cannot start git: <reason>` or `cannot start the
  executor: <reason>` for a command that could not be started (exit `126`),
  `SimpiCI::Worker run <run> aborted: <reason>` and
  `SimpiCI::Dispatcher log of run <run> withheld: ...`. The checkout is made
  with `git init --quiet`, which would otherwise print its path. What the
  tools themselves print is not looked at: `git fetch` names the clone URL,
  and an error of git, of the container runtime or of a job can name a path
  of the host.
- The reason of an aborted claim is one of `invalid event in claim`,
  `invalid secrets in claim`, `invalid secret name in claim`,
  `invalid secret value in claim`, `invalid timeout in claim`,
  `cannot write secret files`, `cannot create temporary directory`,
  `run supervisor failed` and `internal error`, never the text of the error.
  That text, with the file it is about and where it was raised, is written
  to standard error of the worker and nowhere else. See
  [Operations](../deploy/README.md#recovery-and-limits).
- What a worker hears of a request the dispatcher could not serve is as
  fixed: one line, `simpici-dispatch: <reason>`, with one of
  `configuration unusable`, `request not read in time`, `request too large`,
  `invalid request` and `internal error`. Which repository, which grant or
  which file it was stays on the dispatcher, in `<root>/dispatch.log`. See
  [Operations](../deploy/README.md#when-a-request-of-a-worker-fails).
- Worker and dispatcher redact assigned secret values with one function:
  every literal occurrence of every value of the claim, so that nothing is
  left where one value begins another or two of them overlap. This does not
  automatically detect other sensitive content in logs, or a value that a job
  prints encoded or split.
- A `[REDACTED]` in the text is a marker, not output: no value is looked for
  inside it or across one of its ends, so the dispatcher's pass over the log
  the worker has redacted changes nothing, also for a value that is a piece
  of the marker. A marker a job prints itself is left as it is for the same
  reason. A value that contains the marker is refused as a secret, and the
  worker cuts the log to its last 4 MiB without splitting a marker.
- The dispatcher redacts from a snapshot of the claim's values that it keeps
  in `<root>/claims/<run>.json` until the completion is accepted, or until
  the lease has expired and the next polling cycle of `simpicid`, or a
  worker's request before it, ends it. A completion it has no snapshot for
  is recorded with its log withheld.
- A run whose lease expired becomes `interrupted` in that same step, with
  no request of a worker needed, and is never run again by itself. A claim
  that never reached its worker ends the same way, see
  [Operations](../deploy/README.md#a-claim-that-never-reached-its-worker).
- The worker's own copy of a log, `<root>/public/runs/<run>.log`, is not
  redacted and exists only while the run lasts. The worker removes it as
  soon as the completion with the redacted log is saved, together with the
  checkout `work/<run>`, the executor's `tmp/<run>` and `runs/<run>`; after
  a killed worker, the next start does. Only the report
  `public/runs/<run>.json` stays. Output and artifact files that a job wrote
  as another account than the worker can outlast this, see
  [Operations](../deploy/README.md#where-secret-values-are-kept-and-for-how-long).
- A completion the dispatcher refuses for good, because the lease of the run
  is over, the run is claimed under another worker name or token, or the run
  is unknown, is not published anywhere. The worker keeps it as
  `<root>/rejected/<run>.json`, with the log as it redacted it, and goes on;
  a completion it could not deliver is sent again instead. See
  [Operations](../deploy/README.md#a-completion-that-cannot-be-delivered).
- The local native `<root>/public/runs/index.json` currently contains only the
  most recently written run. The queue projection, by contrast, maintains its run list.
- Hosted step summaries are not the native static report store.

This reference describes the existing contract, not a promise that proposed
extensions are already complete.
