# Dispatcher and isolated VMware runner

The dispatcher polls Git and persists accepted jobs. The worker initiates SSH
connections to the dispatcher, fetches the exact commit on the build VM and
runs the same `.cicd/*.sh` container phases as the hosted Action. There is no
inbound runner API. Install the same SimpiCI distribution on both machines;
its executables must be on PATH (the units assume `/usr/local/bin`).

## Dispatcher

1. Create a dedicated `simpici` account and `/etc/simpici/secrets` owned by it,
   mode 0700. Install `etc/simpici.dispatcher.example.json` as
   `/etc/simpici/dispatcher.json`, mode 0600; adjust repositories and secrets.
2. Each secret is a single-line file, mode 0600. `refs` and `events` are exact
   allowlists; an empty/missing list grants nothing. `sources` optionally
   restricts origin, and `phases` permits only `publish` and `deploy`. Repository
   name **and clone URL** must match. Pull-request events never get secrets.
   Mirror entries need their own grants if either source may supply a run.
   Values are never stored in the public report tree or command arguments.
3. Install `simpicid.service`. Enable with `systemctl enable --now simpicid`.
   `mode: dispatcher` is essential: local mode retains the one-machine runner.
4. Add the worker's public key to this account's `authorized_keys` with:

   ```text
   restrict,command="/usr/local/bin/simpici-dispatch --config /etc/simpici/dispatcher.json --worker vm1" ssh-ed25519 WORKER_PUBLIC_KEY
   ```

   Keep this file and its parent administrator-owned so the service account
   cannot replace its restrictions. Disable password/interactive login for the
   account. Use a different forced worker name and key per VM. `restrict`
   disables forwarding, PTY, agent forwarding and user rc execution; never give
   this key a normal shell. Test that `ssh -T simpici@dispatcher id` cannot run
   `id` and only produces a protocol error.
5. Serve only `/var/lib/simpici/public` through the report web server. The
   dispatcher account requires no Docker socket, container runtime or build
   toolchain.

## VMware build VM

1. Use a dedicated Linux VM and `simpici-worker` user. Install Git, OpenSSH,
   Docker and SimpiCI. The supplied unit expects a `docker` group. Docker socket
   access gives builds control of this disposable VM: it must contain no
   internal credentials other than the restricted worker key and current run's
   scoped secrets. Do not co-locate other workloads or mount host directories.
2. Enforce isolation **outside the guest**, on the VMware port group/router:
   deny access to internal, management, link-local and metadata networks for
   IPv4 and IPv6. Permit required DNS and outbound access to GitHub, the public
   src.ci endpoint, registries and the dispatcher SSH endpoint. The guest's
   firewall alone cannot contain a build with Docker socket access. Provide
   administration through the VMware console or a separately controlled path.
3. Generate a dedicated SSH key for the worker. Install the dispatcher host key
   from a trusted administrative source in the worker's `known_hosts`.
   Connections use BatchMode and StrictHostKeyChecking; no TOFU prompt is used.
4. Write `/etc/simpici/worker.env`:

   ```text
   SIMPICI_DISPATCHER=simpici@PUBLIC_DISPATCHER_HOST
   ```

5. Install `simpici-worker.service`, then
   `systemctl enable --now simpici-worker`. The complete worker state directory
   is private, including its local `public` subdirectory. Do not web-serve it.
6. Verify from the VM that internal/management destinations are unreachable,
   allowed Git remotes and registries work, and one disposable repository run
   arrives in the dispatcher's public report tree. Reboot the worker and verify
   it resumes polling. These checks require the actual VM/network environment.

## Recovery and operational limits

Queue mutations and run allocation are locked. Each accepted event remains in
an atomic queue record so replayed poll/webhook events converge. Per-source
poll observations use a hash of repository and clone URL; GitHub and Forgejo
mirrors share run identity `repository NUL ref NUL commit`. Give them different
logical repository names if independent runs are wanted. Initial polling can
record history without builds; subsequently appearing refs are built.

Claims expire after configured execution timeout plus 30 minutes for checkout
and transfer. Workers use the dispatcher's execution timeout. An expired claim
becomes `interrupted` on the next claim request and is never automatically
replayed: publishing may already have happened. Investigate external effects
before making a new commit to retry. There is no automatic publish retry.

Completed results are persisted on the worker before upload. A lost SSH response
is retried idempotently without rebuilding. An expired completion is retained
for operator inspection in `completion.json`; stop the worker and archive that
file after reviewing the run to let it accept new work. A crash during execution
leaves the dispatcher lease to expire. Inspect and remove abandoned per-run
secret directories on the worker before returning the VM to service.

Public metadata is reconstructed by the dispatcher, and literal secret values
are redacted from uploaded logs. Logs are limited to the last 4 MiB; artifacts
remain on the worker. Only trusted revisions may receive publish secrets:
redaction cannot stop a script deliberately encoding or exporting a secret.
Different security domains should use separate dispatcher/worker pairs.

The current transport transfers final logs and status, not live logs or
artifacts. The worker retains its checkout and artifact/output directories for
operator inspection. Set VM disk limits and arrange retention before sustained
production use. Windows/native jobs remain outside this contract (k6).
