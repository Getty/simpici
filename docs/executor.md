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
| `DOCKER_HOST` / Docker context | Selects the Docker endpoint. A Unix socket can be mounted in build/publish; a TCP/TLS daemon is not automatically passed through to job containers. |
| `RUNNER_TEMP` / `TMPDIR` | Base directory for temporary data; keep outside the checkout. Defaults to `/tmp` if neither is set. |
| `GITHUB_STEP_SUMMARY` | Optional hosted path for a Markdown summary. |
| `CICD_IMAGE_REPOSITORY` | Target image chosen by the entry point, for example `ghcr.io/acme/example`; also passed to build jobs. |

The temporary working tree defaults to
`${RUNNER_TEMP:-${TMPDIR:-/tmp}}/simpici.XXXXXXXX`. Output and artifacts are
separated there by phase and job. A custom temporary directory inside the
checkout can cause copies and archives to include their own output.
The temporary directory's parent must exist. At the end, the executor removes
known containers, but does not automatically remove this temporary working tree;
retention is an operational responsibility.

The existing registry handoff also uses `CICD_REGISTRY`,
`CICD_REGISTRY_USER`, `CICD_REGISTRY_PASSWORD` and `CICD_PUBLISH_IMAGE`.
Credentials belong at a trusted entry point, not in the candidate checkout.
The distributed worker also materializes dispatcher grants as private secret
files, only for an event it accepts and only until the run ends; a claim it
cannot execute is reported as `failed` with exit code `125`. It writes each
secret as one `NAME=VALUE` line of `publish.env` or `deploy.env` and refuses,
in the same way, a claim with a secret that is not one: an undefined or empty
value, a structure, a value with a line end, a name other than `CICD_<NAME>`
or `<NAME>_TOKEN`. The files of a worker that was killed during a run are
removed when the worker starts again. See
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
| `CICD_CLONE_URL` | Clone URL, if provided by the entry point |
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

Provider or host errors can produce other nonzero codes. The executor has no
per-job timeout option of its own; the native runner limits the executor's
runtime. TERM/INT are handled with an attempt to clean up known containers.

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
- Native local logs are written unfiltered. Removing private fields from a
  report JSON is not log redaction.
- Worker and dispatcher redact assigned secret values with one function:
  every literal occurrence of every value of the claim, so that nothing is
  left where one value begins another or two of them overlap. This does not
  automatically detect other sensitive content in logs, or a value that a job
  prints encoded or split.
- The dispatcher redacts from a snapshot of the claim's values that it keeps
  in `<root>/claims/<run>.json` until the completion is accepted, or until
  the first worker request after the lease expired. A completion it has no
  snapshot for is recorded with its log withheld. The worker's own copy of a log, under its `<root>/public/runs/`,
  is not redacted.
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
