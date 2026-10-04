package SimpiCI::Dispatcher;

use Moo;
with 'SimpiCI::Role::Secrets';

# ABSTRACT: Restricted worker protocol and dispatcher-owned secret policy

use Carp qw( croak );
use Path::Tiny qw( path );
use Types::Standard qw( HashRef InstanceOf );
use namespace::autoclean;

has queue => (is => 'ro', isa => InstanceOf['SimpiCI::Queue'], required => 1);
has config => (is => 'ro', isa => HashRef, required => 1);

# Every CICD_ variable bin/simpici-executor assigns in a container. A secret of
# such a name would lose against the executor's own -e or forge job context.
# CICD_REGISTRY_PASSWORD is absent on purpose: the executor only passes it
# through. t/62-grant-validation.t holds this list against the executor.
sub reserved_secret_names {
  return qw(
    CICD_ARTIFACTS CICD_BRANCH CICD_CLONE_URL CICD_COMMIT CICD_EVENT
    CICD_EVENT_FILE CICD_IMAGE_REF CICD_IMAGE_REPOSITORY CICD_INPUTS CICD_JOB
    CICD_OUTPUT CICD_PHASE CICD_PROVIDER_OUT CICD_PUBLISH_IMAGE CICD_REF
    CICD_REGISTRY CICD_REGISTRY_USER CICD_REPOSITORY CICD_ROOT CICD_RUN_NUMBER
    CICD_SOURCE CICD_TAG CICD_WORKSPACE
  );
}

# A grant ref is either an exact ref or "refs/<path>/*", which matches every
# ref below that path. Anything else containing "*" is a configuration error.
sub _ref_pattern_valid {
  my ( $self, $pattern ) = @_;
  return index($pattern, '*') < 0 || $pattern =~ m{\Arefs/[^*]+/\*\z};
}

sub _ref_matches {
  my ( $self, $pattern, $ref ) = @_;
  croak __PACKAGE__.' invalid ref pattern: '.$pattern
    unless $self->_ref_pattern_valid($pattern);
  return $pattern eq $ref if index($pattern, '*') < 0;
  my $prefix = substr($pattern, 0, -1);
  return length($ref) > length($prefix) && index($ref, $prefix) == 0;
}

sub _label {
  my ( $self, $value ) = @_;
  return defined $value && !ref $value ? $value : '?';
}

sub _reject {
  my ( $self, $where, $reason ) = @_;
  croak __PACKAGE__.' '.$where.': '.$reason;
}

# The one place for the grant rules: returns the grant with its secret value
# or croaks naming the configuration entry.
sub _grant {
  my ( $self, $repo, $secret, $where ) = @_;
  $self->_reject($where, 'grant must be an object') unless ref $secret eq 'HASH';
  my $name = $secret->{name};
  $self->_reject($where, 'invalid secret name') unless $self->secret_name_valid($name);
  $self->_reject($where, 'invalid secret name: reserved for the executor')
    if grep { $_ eq $name } $self->reserved_secret_names;
  $self->_reject($where, 'repository needs name and clone_url')
    if grep { !defined || ref || !length } $repo->@{qw( name clone_url )};
  my %list;
  for my $key (qw( refs events sources phases )) {
    my $value = $secret->{$key} // next;
    $self->_reject($where, $key.' must be a list of strings')
      unless ref $value eq 'ARRAY' && !grep { !defined || ref } @$value;
    $list{$key} = [ @$value ];
  }
  for my $pattern (@{$list{refs} // []}) {
    $self->_reject($where, 'invalid ref pattern: '.$pattern)
      unless $self->_ref_pattern_valid($pattern);
  }
  my $phases = $list{phases} // ['publish', 'deploy'];
  $self->_reject($where, 'secrets only allowed in publish/deploy')
    if grep { $_ ne 'publish' && $_ ne 'deploy' } @$phases;
  my $file = $secret->{file};
  $self->_reject($where, 'secret file missing')
    unless defined $file && !ref $file && length $file;
  my $value = eval { path($file)->slurp_utf8 };
  unless (defined $value) {
    my $error = $@;
    $self->_reject($where, 'cannot read secret file '.$file.': '
      .(ref $error eq 'Path::Tiny::Error' ? $error->{err} : 'content is not readable text'));
  }
  $value =~ s/\r?\n\z//;
  my $rejection = $self->secret_value_rejection($value);
  $self->_reject($where, 'secret '.$rejection) if defined $rejection;
  return {
    repository => $repo->{name},
    clone_url  => $repo->{clone_url},
    name       => $name,
    refs       => $list{refs} // [],
    events     => $list{events} // [],
    sources    => $list{sources},
    phases     => $phases,
    value      => $value
  };
}

# Every grant of every repository, read fresh on each call so that a rotated
# secret file needs no restart.
sub _grants {
  my ( $self ) = @_;
  my $repositories = $self->config->{repositories};
  croak __PACKAGE__.' repositories must be a list' unless ref $repositories eq 'ARRAY';
  my @grants;
  for my $r (0 .. $#$repositories) {
    my $repo = $repositories->[$r];
    croak __PACKAGE__.' repositories['.$r.'] must be an object' unless ref $repo eq 'HASH';
    my $where = 'repository '.$self->_label($repo->{name}).' (repositories['.$r.'])';
    my $secrets = $repo->{secrets} // [];
    $self->_reject($where, 'secrets must be a list') unless ref $secrets eq 'ARRAY';
    for my $s (0 .. $#$secrets) {
      my $secret = $secrets->[$s];
      my $name = $self->_label(ref $secret eq 'HASH' ? $secret->{name} : undef);
      push @grants, $self->_grant($repo, $secret,
        $where.', secret '.$name.' (secrets['.$s.'])');
    }
  }
  return \@grants;
}

sub validate {
  my ( $self ) = @_;
  $self->_grants;
  return $self;
}

sub _secrets {
  my ( $self, $event, $grants ) = @_;
  $grants //= $self->_grants;
  my %phases;
  return \%phases if $event->{event} eq 'pull_request';
  for my $grant (@$grants) {
    next unless $grant->{repository} eq $event->{repository}
      && $grant->{clone_url} eq $event->{clone_url};
    next unless grep { $self->_ref_matches($_, $event->{ref}) } $grant->{refs}->@*;
    next unless grep { $_ eq $event->{event} } $grant->{events}->@*;
    next if $grant->{sources} && !grep { $_ eq $event->{source} } $grant->{sources}->@*;
    $phases{$_}{$grant->{name}} = $grant->{value} for $grant->{phases}->@*;
  }
  return \%phases;
}

sub _snapshot {
  my ( $self, $run ) = @_;
  return $self->queue->store->root->child('claims', $run.'.json');
}

# The snapshot of a run, or what SimpiCI::Store->write_json leaves of one it
# did not write to its end. Anything else in claims/ is not ours to remove.
sub _snapshot_run {
  my ( $self, $file ) = @_;
  return $file->basename =~ /\A(?:([1-9][0-9]*)\.json|\.([1-9][0-9]*)\.json\.tmp\.[0-9]+)\z/
    ? $1 // $2 : undef;
}

sub remove_stale_snapshots {
  my ( $self ) = @_;
  my $directory = $self->queue->store->root->child('claims');
  return 0 unless $directory->is_dir;
  my $removed = 0;
  # The directory is listed before a lease is read: a snapshot is written
  # after its lease, so one that is seen here has a lease that can be read.
  for my $file ($directory->children) {
    my $run = $self->_snapshot_run($file) // next;
    next if !$file->is_file || $self->queue->leased($run);
    $removed += $self->_remove_snapshot($file);
  }
  return $removed;
}

# Two requests may remove the same file at the same moment: that it is gone
# is what counts, not who removed it.
sub _remove_snapshot {
  my ( $self, $file ) = @_;
  my $removed = eval { $file->remove };
  my $error = $@;
  croak __PACKAGE__.' cannot remove secret snapshot '.$file.': '
    .(ref $error eq 'Path::Tiny::Error' ? $error->{err} : 'it is still there')
    if !$removed && $file->exists;
  return $removed ? 1 : 0;
}

# The one step that ends what a lost worker left, for a request as for the
# polling daemon. The queue decides under its lock; the snapshots follow what
# it decided, and a completion that is being served beside this finds its
# run interrupted when it asks the queue to record it.
sub expire_leases {
  my ( $self ) = @_;
  my @reports = $self->queue->expire_leases;
  $self->remove_stale_snapshots;
  return @reports;
}

sub request {
  my ( $self, $worker, $request ) = @_;
  croak __PACKAGE__.' invalid request' unless ref $request eq 'HASH';
  my $operation = $request->{operation} // '';
  # Before anything of the request can fail: an unusable grant or a refused
  # completion must not keep a run running, or its secret values, that is
  # over.
  $self->expire_leases;
  if ($operation eq 'claim') {
    # Resolve every grant before taking a lease: a configuration error must
    # not use up queued work.
    my $grants = $self->_grants;
    my $record = $self->queue->claim($worker);
    return {} unless $record;
    my $secrets = $self->_secrets($record->{event}, $grants);
    # Keep a private snapshot so rotation cannot prevent completion redaction.
    # It is written for a claim without secrets too: a completion whose
    # snapshot is missing has nothing to prove its log needs no redaction.
    $self->queue->store->write_json('claims/'.$record->{run}.'.json', $secrets);
    return { %$record, secrets => $secrets, timeout => $self->config->{timeout} // 3600 };
  }
  if ($operation eq 'finish') {
    my $run = $request->{run};
    croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
    my $token = $request->{token} // '';
    # Answered, not croaked, and before anything else of the request is
    # looked at: the worker would send again what failed, and this can never
    # be accepted. The snapshot stays; it may belong to the lease of another.
    my $refusal = $self->queue->refusal($worker, $run, $token);
    return { rejected => $refusal } if $refusal;
    my $log = $request->{log} // '';
    croak __PACKAGE__.' invalid log' if ref $log || length($log) > 4 * 1024 * 1024;
    my $snapshot = $self->_snapshot($run);
    # No log goes on that the snapshot did not redact. A repeated completion
    # finds none any more; the queue publishes nothing for it either way.
    $log = $snapshot->is_file
      ? $self->redact($log, $self->queue->store->_json->decode($snapshot->slurp_utf8))
      : $self->_withheld_log($run);
    # A lease that ran out since it was asked about croaks here, and is
    # answered as a refusal when the worker sends the completion again.
    my $report = $self->queue->finish($worker, $run, $token, $request->{result}, $log);
    # Only now: a completion that failed, or one the dispatcher died in,
    # still has its lease and is redacted from the snapshot when it returns.
    $self->_remove_snapshot($snapshot);
    return $report;
  }
  croak __PACKAGE__.' unsupported operation';
}

sub _withheld_log {
  my ( $self, $run ) = @_;
  return __PACKAGE__.' log of run '.$run.' withheld: no secret snapshot to redact it with'."\n";
}

1;

=head1 NAME

SimpiCI::Dispatcher - fixed claim/finish protocol

=head1 DESCRIPTION

Worker identity comes from the administrator's SSH forced command, never from
the request. Secret references are resolved on the dispatcher, scoped to exact
repository, event, optional source and publish/deploy phase. A grant ref is an
exact ref or C<refs/E<lt>pathE<gt>/*>, which matches every ref below that path;
any other use of C<*> is rejected. Public reports are reconstructed from
accepted events; worker-supplied metadata is discarded.

The grants of all repositories are checked as a whole, not only those that
match an event: name, ref patterns, list shapes, phases and a readable secret
file holding a value L<SimpiCI::Role::Secrets/secret_value_rejection> has
nothing against, one nonempty line without the redaction marker. An error
names the repository, the secret and the reason, never a secret value. A
claim runs this check before it takes a lease, so a configuration error
leaves queued work queued; the values read by that check are the ones handed
out. A completion is accepted without the check: it needs only the queue and
the secret snapshot of its claim.

=head2 A completion that is refused

A worker keeps a completion until it has an answer to it, and sends it again
after every request that failed. A completion that can never be accepted
therefore has to be answered: L</request> returns

  { rejected => 'expired claim' }

for it and croaks for everything else that goes wrong. The reason is one of
L<SimpiCI::Queue/refusal_reasons>, a fixed phrase and the only key of the
answer: nothing of the run, of the queue or of this installation goes to a
worker that is refused. The worker stops sending the completion and keeps it
aside, see L<SimpiCI::Worker/Delivering a completion>.

The queue is asked before anything else of the completion is looked at, so a
refused completion is refused whatever its result or log are. Nothing is
published or recorded for it, and the secret snapshot of the run is not
removed by it: a completion with a foreign token must not take the snapshot
from the worker that holds the lease. A completion that comes too late finds
its run C<interrupted>, by the step every request begins with if nothing
ended the lease before, see L</A lease that ends without a completion>.

A completion of a run that already has its result, from the worker and token
that completed it, is not refused. It is answered with the report again, as
the retry after a lost answer needs it.

A completion of a leased run with a result or log the protocol does not
allow is an error, not a refusal: no worker of this version sends one.

=head2 A lease that ends without a completion

A run that was claimed is C<running> until its completion is recorded or its
lease runs out. L</expire_leases> is the one step that ends a lease that ran
out: the run becomes C<interrupted>, is never handed out again, and its
secret snapshot is removed. Two callers take the step, so that it does not
depend on a worker that asks:

=over 4

=item *

L</request>, before it looks at the request. That covers a dispatcher whose
polling daemon is not running.

=item *

C<simpicid> in dispatcher mode, at the beginning of every polling cycle and
before it reads a repository, see L<SimpiCI::App::Eventd>. A run whose
worker is gone is therefore C<interrupted> one cycle after its lease ran
out, and the daemon logs it.

=back

A completion can arrive while the step ends the lease of its run. The queue
decides both under its lock, see L<SimpiCI::Queue/expire_leases>, and
L</request> asks it to record the result only after the log is redacted, so
one of two things happens. The completion is recorded first: the run has its
result and its redacted log, and the step leaves it alone. Or the lease is
ended first: the completion fails with C<expired claim> where it was being
served and is answered as L</A completion that is refused> when the worker
sends it again; nothing of it is published. In neither order is a log
published that the snapshot did not redact, because a snapshot is removed
only for a lease that is over, and a lease that is over accepts nothing.

=head2 A claim that is leased but not delivered

A C<claim> saves the lease, then writes the snapshot, then returns the
claim. A dispatcher that dies in between, or an answer that is lost on its
way, leaves a run that is leased to a worker that never received it. It is
not handed out again: nothing tells this run from one whose worker received
the claim and was lost in the middle of a publish, and an answer cannot be
confirmed over the transport. The run stays C<running> until its lease runs
out and is then C<interrupted> by L</expire_leases>, without a log.

Holding the lease back until the answer is delivered was considered and not
built: standard output of a forced command gives no acknowledgement, so the
dispatcher would have to guess, and a guess that is wrong runs a publish
twice. What an operator sees and does is in the operations guide,
F<deploy/README.md>, under "A claim that never reached its worker".

=head2 Secret snapshot of a claim

A claim writes the secret values it hands out to C<claims/E<lt>runE<gt>.json>
below the store root, in the clear and readable by the account alone, also
when it hands out none. The completion of the run is redacted from this file
by L<SimpiCI::Role::Secrets/redact>, not from the secret files, so that a
value rotated during the run is still found in its log.

The file lives as long as a completion of the run can be accepted, see
L<SimpiCI::Queue/leased>:

=over 4

=item *

A completion that was accepted removes it, after the log is published and
the result is recorded. If the dispatcher dies before that, the run is still
leased, the file is still there and the worker's retry is redacted from it.

=item *

L</expire_leases> removes the file of a lease that ran out, of a run that
was completed by a dispatcher that died before it removed the file, and of
every run completed by a version that kept them. Every request takes that
step first, a claim as well as a completion, and C<simpicid> takes it at
the beginning of every polling cycle.

=back

A lease that runs out while no worker asks for anything therefore keeps its
file until the next cycle of the daemon, and only where no C<simpicid> runs
in dispatcher mode until the next request.

No log is published that was not redacted from the snapshot. A completion
that is accepted while the file is missing, as after it was removed by hand,
gets this line as its log instead of what the worker sent:

  SimpiCI::Dispatcher log of run N withheld: no secret snapshot to redact it with

A repeated completion of a run that already has its result finds no file
either; L<SimpiCI::Queue> publishes nothing for it, so the log of the
accepted completion stays.

=head1 METHODS

=head2 validate

  $dispatcher->validate;

Checks every configured grant and croaks on the first unusable one. Returns
the dispatcher. C<simpicid> calls it before polling in dispatcher mode.

=head2 reserved_secret_names

Lists the C<CICD_> variables the executor assigns in a container. A grant
cannot use one of them as its name: the executor's own value would win, or the
secret would forge job context. C<CICD_REGISTRY_PASSWORD> is not reserved,
because the executor only passes it through.

=head2 request

  my $response = $dispatcher->request($worker, { operation => 'claim' });

Serves one C<claim> or C<finish> request for the given worker identity, after
it called L</expire_leases>. A C<claim> returns the claim, or an
empty hash if nothing is queued. A C<finish> returns the report of the run,
or C<{ rejected =E<gt> REASON }> for L</A completion that is refused>.
Croaks for any other request and for every error.

=head2 expire_leases

  my @reports = $dispatcher->expire_leases;

Ends what a worker that is gone left behind: L<SimpiCI::Queue/expire_leases>
marks every run as C<interrupted> whose lease ran out, and
L</remove_stale_snapshots> removes the secret snapshots nothing can be
completed with any more. Returns the reports of the runs that were
interrupted by this call, nothing if there was none.

It needs no grant and reads no secret file, so it works on a configuration
that serves no claim. L</request> calls it before anything else, and
C<simpicid> in dispatcher mode at the beginning of every polling cycle, so
that a lease does not wait for a worker to ask before it is seen to be over,
see L</A lease that ends without a completion>.

=head2 remove_stale_snapshots

  my $removed = $dispatcher->remove_stale_snapshots;

Removes from C<claims/> the secret snapshot of every run that is not leased
any more and returns how many files it removed. A snapshot that
L<SimpiCI::Store/write_json> did not write to its end is removed the same
way. The snapshot of a leased run and any file of another name stay. Croaks
if a file cannot be removed.

=cut
