package SimpiCI::Dispatcher;
our $VERSION = '0.001';

use Moo;
with 'SimpiCI::Role::Secrets';

# ABSTRACT: Restricted worker protocol and dispatcher-owned secret policy

use Carp qw( croak );
use Fcntl qw( LOCK_EX );
use Path::Tiny qw( path );
use POSIX qw( strftime );
use SimpiCI::Config;
use SimpiCI::Event;
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

# The class whose rules say which events there can be. A grant that no event
# of that class can match is refused.
sub event_class { 'SimpiCI::Event' }

# The class that knows what the settings of a configuration may hold.
sub config_class { 'SimpiCI::Config' }

sub grant_keys { qw( name file refs events sources phases ) }

sub grant_phases { qw( publish deploy ) }

# What a worker is told of a request that failed, and nothing beyond it:
# standard error of simpici-dispatch is read on the machine of the worker.
sub failure_reasons {
  return ( 'configuration unusable', 'request not read in time', 'request too large',
    'invalid request', 'internal error' );
}

sub failure_reason {
  my ( $self, $reason ) = @_;
  return ( grep { $_ eq ( $reason // '' ) } $self->failure_reasons )[0] // 'internal error';
}

# A grant ref is either an exact ref or "refs/<path>/*", which matches every
# ref below that path. Anything else containing "*" is a configuration error,
# and so is a path no ref can begin with.
sub _ref_pattern_valid {
  my ( $self, $pattern ) = @_;
  return 1 if index($pattern, '*') < 0;
  return $pattern =~ m{\A(refs/[^*]+)/\*\z} && !defined $self->event_class->ref_rejection($1) ? 1 : 0;
}

sub _ref_matches {
  my ( $self, $pattern, $ref ) = @_;
  croak __PACKAGE__.' invalid ref pattern' unless $self->_ref_pattern_valid($pattern);
  return $pattern eq $ref if index($pattern, '*') < 0;
  my $prefix = substr($pattern, 0, -1);
  return length($ref) > length($prefix) && index($ref, $prefix) == 0;
}

# A name is printed if it is one line of text, and a secret name if it is
# one: what stands in their place may be anything, a value included.
sub _repository_label {
  my ( $self, $name ) = @_;
  return defined $name && !ref $name && !defined $self->event_class->name_rejection($name)
    ? $name : '?';
}

sub _secret_label {
  my ( $self, $secret ) = @_;
  my $name = ref $secret eq 'HASH' ? $secret->{name} : undef;
  return $self->secret_name_valid($name) ? $name : '?';
}

# The one place for the grant rules: returns the grant with its secret
# value, or nothing and the reason. A third value says that the reason lies
# in the entry of the repository, not in the grant. No reason repeats what
# the grant holds: not a pattern, not a name, not the path of the file.
sub _grant {
  my ( $self, $repo, $secret ) = @_;
  return ( undef, 'grant must be an object' ) unless ref $secret eq 'HASH';
  my $name = $secret->{name};
  return ( undef, 'invalid secret name' ) unless $self->secret_name_valid($name);
  return ( undef, 'invalid secret name: reserved for the executor' )
    if grep { $_ eq $name } $self->reserved_secret_names;
  return ( undef, 'repository needs name and clone_url', 1 )
    if grep { !defined || ref || !length } $repo->@{qw( name clone_url )};
  # The events of such a repository are refused, so its grants match none.
  my $unnamed = $self->event_class->name_rejection($repo->{name});
  return ( undef, 'repository name '.$unnamed, 1 ) if defined $unnamed;
  my %list;
  for my $key (qw( refs events sources phases )) {
    my $value = $secret->{$key} // next;
    return ( undef, $key.' must be a list of strings' )
      unless ref $value eq 'ARRAY' && !grep { !defined || ref } @$value;
    $list{$key} = [ @$value ];
  }
  # What follows would be accepted and never apply: a grant that looks as if
  # it gave a secret to a run and gives it to none.
  my $no_run = ': the grant would apply to no run';
  my @refs = ( $list{refs} // [] )->@*;
  return ( undef, 'refs must name at least one ref or pattern'.$no_run ) unless @refs;
  for my $index (0 .. $#refs) {
    if (index($refs[$index], '*') >= 0) {
      return ( undef, 'invalid ref pattern (refs['.$index.'])' )
        unless $self->_ref_pattern_valid($refs[$index]);
      next;
    }
    my $rejection = $self->event_class->ref_rejection($refs[$index]) // next;
    return ( undef, 'invalid ref (refs['.$index.']): '.$rejection );
  }
  my @events = ( $list{events} // [] )->@*;
  return ( undef, 'events must name at least one event'.$no_run ) unless @events;
  return ( undef, 'events must name an event other than pull_request, which receives no secret'.$no_run )
    unless grep { $_ ne 'pull_request' } @events;
  if (my $sources = $list{sources}) {
    return ( undef, 'sources must name at least one source if it is given'.$no_run ) unless @$sources;
    my @known = $self->event_class->sources;
    return ( undef, 'sources must be of '.join(', ', @known[ 0 .. $#known - 1 ]).' and '.$known[-1] )
      if grep { my $source = $_; !grep { $_ eq $source } @known } @$sources;
  }
  my $phases = $list{phases} // [ $self->grant_phases ];
  return ( undef, 'phases must name '.join(' or ', $self->grant_phases).' if it is given'.$no_run )
    unless @$phases;
  return ( undef, 'secrets only allowed in '.join('/', $self->grant_phases) )
    if grep { my $phase = $_; !grep { $_ eq $phase } $self->grant_phases } @$phases;
  my $file = $secret->{file};
  return ( undef, 'secret file missing' ) unless defined $file && !ref $file && length $file;
  my $value = eval { path($file)->slurp_utf8 };
  unless (defined $value) {
    my $error = $@;
    return ( undef, 'cannot read secret file: '
      .( ref $error eq 'Path::Tiny::Error' ? $error->{err} : 'content is not readable text' ) );
  }
  $value =~ s/\r?\n\z//;
  my $rejection = $self->secret_value_rejection($value);
  return ( undef, 'secret '.$rejection ) if defined $rejection;
  return {
    repository => $repo->{name},
    clone_url  => $repo->{clone_url},
    name       => $name,
    refs       => \@refs,
    events     => \@events,
    sources    => $list{sources},
    phases     => $phases,
    value      => $value
  };
}

# Every grant of every repository, read fresh on each call so that a rotated
# secret file needs no restart, and everything that is wrong with them: the
# grants, then one finding for each grant or entry that cannot be used.
sub _inspect {
  my ( $self, $config ) = @_;
  $config //= $self->config;
  my $repositories = ref $config eq 'HASH' ? $config->{repositories} : undef;
  return ( [], { entry => 1, message => 'repositories must be a list' } )
    unless ref $repositories eq 'ARRAY';
  my ( @grants, @findings );
  for my $r (0 .. $#$repositories) {
    my $repo = $repositories->[$r];
    unless (ref $repo eq 'HASH') {
      push @findings, { entry => 1, message => 'repositories['.$r.'] must be an object' };
      next;
    }
    my $where = 'repository '.$self->_repository_label($repo->{name}).' (repositories['.$r.'])';
    my $secrets = $repo->{secrets} // [];
    unless (ref $secrets eq 'ARRAY') {
      push @findings, { message => $where.': secrets must be a list' };
      next;
    }
    for my $s (0 .. $#$secrets) {
      my ( $grant, $reason, $entry ) = $self->_grant($repo, $secrets->[$s]);
      if ($grant) {
        push @grants, $grant;
        next;
      }
      push @findings, {
        $entry ? ( entry => 1 ) : (),
        message => $where.', secret '.$self->_secret_label($secrets->[$s]).' (secrets['.$s.']): '.$reason
      };
    }
  }
  return ( \@grants, @findings );
}

sub findings {
  my ( $self, $config ) = @_;
  my ( undef, @findings ) = $self->_inspect($config);
  return map { +{ %$_, message => __PACKAGE__.' '.$_->{message} } } @findings;
}

sub problems {
  my ( $self, $config ) = @_;
  return map { $_->{message} } $self->findings($config);
}

sub _grants {
  my ( $self ) = @_;
  my ( $grants, @findings ) = $self->_inspect;
  croak __PACKAGE__.' '.$findings[0]{message} if @findings;
  return $grants;
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

# Serves a request and croaks for whatever keeps it from that.
sub request {
  my ( $self, $worker, $request ) = @_;
  my ( $response, $reason, @details ) = $self->_serve($worker, $request);
  croak $details[0] if defined $reason;
  return $response;
}

# Serves a request and croaks for nothing: returns the response, or nothing,
# the reason of failure_reasons and what the operator is to read about it.
sub serve {
  my ( $self, $worker, $request ) = @_;
  my @answer = eval { $self->_serve($worker, $request) };
  return @answer if @answer;
  # As it was raised: where it croaked is what there is to know about it.
  return ( undef, 'internal error', ( split /\n/, $@ // '' )[0] // 'unknown error' );
}

# The reason of a failure follows from the step that failed, never from the
# text of an error. Whatever croaks in here is an internal error.
sub _serve {
  my ( $self, $worker, $request ) = @_;
  return ( undef, 'invalid request', __PACKAGE__.' invalid request' ) unless ref $request eq 'HASH';
  my $operation = $request->{operation} // '';
  $operation = '' if ref $operation;
  # Before anything of the request can fail: an unusable grant or a refused
  # completion must not keep a run running, or its secret values, that is
  # over.
  $self->expire_leases;
  if ($operation eq 'claim') {
    # Resolve every grant before taking a lease: a configuration error must
    # not use up queued work. The timeout goes into the claim, and a worker
    # aborts a claim whose timeout is none.
    my $timeout = $self->config_class->setting_rejection($self->config, 'timeout');
    my ( $grants, @findings ) = $self->_inspect;
    my @problems = map { __PACKAGE__.' '.$_ }
      defined $timeout ? $timeout : (), map { $_->{message} } @findings;
    return ( undef, 'configuration unusable', @problems ) if @problems;
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
    return ( undef, 'invalid request', __PACKAGE__.' invalid run' )
      unless defined $run && !ref $run && $run =~ /\A[1-9][0-9]*\z/;
    my $token = $request->{token} // '';
    # Answered, not croaked, and before anything else of the request is
    # looked at: the worker would send again what failed, and this can never
    # be accepted. The snapshot stays; it may belong to the lease of another.
    my $refusal = $self->queue->refusal($worker, $run, $token);
    return { rejected => $refusal } if $refusal;
    my $log = $request->{log} // '';
    return ( undef, 'invalid request', __PACKAGE__.' invalid log' )
      if ref $log || length($log) > 4 * 1024 * 1024;
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
  return ( undef, 'invalid request', __PACKAGE__.' unsupported operation' );
}

sub failure_log_name { 'dispatch.log' }

# At this size the log is set aside, in place of the one set aside before.
sub failure_log_limit { 1024 * 1024 }

# One line of text, of a length a log can take.
sub _printable {
  my ( $self, $text ) = @_;
  $text //= '';
  $text =~ s/\s+/ /g;
  $text =~ s/[\x00-\x1f\x7f]/?/g;
  return length $text > 2000 ? substr($text, 0, 2000).' [...]' : $text;
}

# Appends one line for each detail of a failed request to the log below the
# state root. True if they are written. It does not croak: the request has
# failed already, and the worker is told why whether this is written or not.
sub log_failure {
  my ( $self, $root, $worker, $reason, @details ) = @_;
  return $self->_log($root, $worker, $self->failure_reason($reason), @details);
}

# The same for what Perl warned of while a request was served: a warning
# names a file of the installation and may quote what it warns about.
sub log_warning {
  my ( $self, $root, $worker, @warnings ) = @_;
  return $self->_log($root, $worker, 'warning', @warnings);
}

sub _log {
  my ( $self, $root, $worker, $kind, @details ) = @_;

  my $stamp = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
  my $head = $stamp.' worker '.$self->_printable($worker).': '.$kind.': ';
  my @lines = map { $head.$self->_printable($_)."\n" } @details ? @details : 'no detail';
  return eval {
    my $log = path($root)->child($self->failure_log_name);
    $log->parent->mkpath;
    # The size is asked and the log set aside by whoever holds its lock, and
    # a handle that was waited for may be one of the log that was set aside
    # in between: it is then opened again.
    for my $attempt (1 .. 4) {
      my $handle = $log->opena_utf8;
      flock($handle, LOCK_EX) or croak __PACKAGE__.' cannot lock '.$log.': '.$!;
      my @open = stat $handle;
      my @named = stat $log->stringify;
      next unless @named && $open[0] == $named[0] && $open[1] == $named[1];
      if ($open[7] >= $self->failure_log_limit && $attempt < 4) {
        rename $log->stringify, $log->stringify.'.1'
          or croak __PACKAGE__.' cannot set '.$log.' aside: '.$!;
        next;
      }
      print {$handle} @lines or croak __PACKAGE__.' cannot write '.$log.': '.$!;
      close $handle or croak __PACKAGE__.' cannot write '.$log.': '.$!;
      return 1;
    }
    0;
  } ? 1 : 0;
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
names the repository, the secret and the reason, see L</problems>. A claim
runs this check before it takes a lease, so a configuration error leaves
queued work queued; the values read by that check are the ones handed out.
A completion is accepted without the check: it needs only the queue and the
secret snapshot of its claim.

An error never repeats what stands in a grant: not the secret value, not
the path of its file, not a ref pattern, not a name that is none. In the
wrong place each of them may be the value itself, and the error is written
to a journal and to L</The log of failed requests>. A repository is named
unless its name has a control character, a secret unless its name is no
secret name; a C<?> stands for a name that is not printed. A ref is named by
its position in C<refs>:

  SimpiCI::Dispatcher repository owner/project (repositories[0]), secret CICD_REGISTRY_PASSWORD (secrets[0]): cannot read secret file: No such file or directory
  SimpiCI::Dispatcher repository owner/project (repositories[0]), secret ? (secrets[1]): invalid secret name
  SimpiCI::Dispatcher repository owner/project (repositories[0]), secret PUBLISH_TOKEN (secrets[2]): invalid ref pattern (refs[1])

=head2 A grant that would apply to no run

A grant that is well formed and can never match an event is refused like
one that cannot be read. It would look as if it gave a secret to a run and
give it to none, and nothing would say so. An entry of one of its lists that
can match nothing is refused for the same reason, also beside entries that
can:

=over 4

=item *

C<refs> is missing or empty, or C<events> is: an empty list matches nothing.

  refs must name at least one ref or pattern: the grant would apply to no run
  events must name at least one event: the grant would apply to no run

=item *

C<events> names C<pull_request> and nothing else. An event of that name
receives no secret, whatever the grants say.

  events must name an event other than pull_request, which receives no secret: the grant would apply to no run

=item *

C<sources> or C<phases> is given and empty. Left out, C<sources> admits
every source and C<phases> means both phases.

  sources must name at least one source if it is given: the grant would apply to no run
  phases must name publish or deploy if it is given: the grant would apply to no run

=item *

An entry of C<sources> is none of L<SimpiCI::Event/sources>.

  sources must be of git-poll, webhook and manual

=item *

An exact ref in C<refs> is one L<SimpiCI::Event/ref_rejection> refuses, so
that no event can carry it, such as a branch name without C<refs/heads/>
in front. The path ahead of the C</*> of a pattern is held against the same
rule and refused as an invalid pattern.

  invalid ref (refs[0]): ref must start with refs/
  invalid ref (refs[0]): ref is not canonical

=item *

The name of the repository has a control character: every event of that
name is refused.

  repository name must not contain control characters

=back

The names in C<events> are not checked beyond that. An event is free text,
and there is no list a name could be held against: a grant for an event that
is misspelt is accepted and applies to nothing.

=head2 A request that fails

L</request> croaks for a request it cannot serve. L</serve> does the same
work and croaks for nothing: it returns the reason, one of
L</failure_reasons>, and what an operator is to read about it.
C<simpici-dispatch> uses it, because what that program writes to standard
error is read on the machine of a worker, and the configuration names the
repositories and secret files of every project. A worker is told one of
five things:

=over 4

=item C<configuration unusable>

The configuration cannot be read, a setting the request needs cannot be
used, or, for a claim, a grant or the C<timeout> cannot. No lease is taken.

=item C<request not read in time>

=item C<request too large>

Said by C<simpici-dispatch>, which reads the request.

=item C<invalid request>

The request is no JSON object, names no operation of the protocol, or is a
completion whose run is no run number or whose log is no text of at most
4 MiB.

=item C<internal error>

Everything else: a queue that cannot be locked, read or written, a snapshot
that cannot be removed, a worker name the queue refuses, a lease that ran
out between the two steps of a completion.

=back

The reason follows from the step that failed, never from the text of an
error, so nothing an error quotes can end up in it. A completion that is
refused for good is no failure: it is answered, see
L</A completion that is refused>.

=head2 The log of failed requests

Standard error of a forced command goes to the client, and the SSH server
logs the connection, not the program. What went wrong with a request is
therefore written to a file, C<dispatch.log> below the store root, by
L</log_failure>: one line for each detail,

  2026-10-04T10:15:02Z worker vm1: configuration unusable: SimpiCI::Dispatcher repository owner/project (repositories[0]), secret CICD_REGISTRY_PASSWORD (secrets[0]): cannot read secret file: No such file or directory

with the time in UTC, the worker name of the forced command, the reason the
worker was given and the detail. A line is one line: white space in it is
one space, a control character is C<?>, and a detail ends after 2000
characters. The file is created with the umask of the program, readable by
the account alone, and belongs to the private state like the queue.

At 1 MiB the file is renamed to C<dispatch.log.1>, in place of the file of
that name, and a new one is begun, so the two together stay below 2 MiB plus
the lines of one request. A request that is served writes nothing, unless
Perl warned of something on the way: a warning is a line with C<warning> in
the place of the reason, and the request is served all the same.

A request that fails before the store root is known has no log to write to:
a configuration that cannot be read, or one without a usable C<root>. The
worker is told C<configuration unusable>, and C<simpicid --check> with that
file says what is wrong with it. A log that cannot be written changes
nothing about the answer.

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

Checks every configured grant and croaks with the first of L</problems>.
Returns the dispatcher.

=head2 problems

  my @problems = $dispatcher->problems;
  my @problems = SimpiCI::Dispatcher->problems($config);

Returns one line for every grant that cannot be used and for every entry of
C<repositories> whose grants cannot be looked at, in the order of the
configuration, or nothing. Each line begins with the name of this class. It
reads the secret files and nothing else, and croaks for nothing. With a
decoded configuration as its argument it can be called on the class: the
check needs no queue.

=head2 findings

  my @findings = SimpiCI::Dispatcher->findings($config);

The same as hash references, each with the line as its C<message> and with
a true C<entry> if the finding is one about the entry of the repository, not
about the grant: C<repositories> that are no list, an entry that is no
object, one without name and clone URL, a name with a control character.
L<SimpiCI::App::Eventd/check> reports those itself and leaves them out.

=head2 event_class

Class whose rules say which events there can be, L<SimpiCI::Event>: its
C<sources>, its C<ref_rejection> and its C<name_rejection> are what a grant
is held against.

=head2 config_class

Class that has the rule for the C<timeout> of a claim, L<SimpiCI::Config>.

=head2 grant_keys

The keys a grant can have: C<name>, C<file>, C<refs>, C<events>, C<sources>
and C<phases>.

=head2 grant_phases

The phases a secret can be granted to, C<publish> and C<deploy>.

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

A claim is refused before it takes a lease if a grant cannot be used or if
the C<timeout> of the configuration is no positive integer: the timeout
goes into the claim, and a worker aborts a claim whose timeout is none.

=head2 serve

  my ( $response, $reason, @details ) = $dispatcher->serve($worker, $request);

Serves a request as L</request> does and croaks for nothing. Returns the
response alone, or nothing, one of L</failure_reasons> and the details: for
an unusable configuration every one of its problems, otherwise one line,
which for an internal error is the error as it was raised, with the place.
The details are for an operator. See L</A request that fails>.

=head2 failure_reasons

Returns the five reasons a request can fail for, in the words a worker is
told.

=head2 failure_reason

  my $reason = SimpiCI::Dispatcher->failure_reason($anything);

Returns its argument if it is one of L</failure_reasons>, exactly as written
there, and C<internal error> for everything else.

=head2 log_failure

  my $written = SimpiCI::Dispatcher->log_failure($root, $worker, $reason, @details);

Appends one line for each detail to L</The log of failed requests> below the
given store root, and sets the file aside first if it has reached
L</failure_log_limit>. Both happen under a lock on the file, so that
requests which fail at the same moment neither mix their lines nor set the
new file aside for the old one. Returns whether the lines are written. It
does not croak: the request has failed already.

=head2 log_warning

  my $written = SimpiCI::Dispatcher->log_warning($root, $worker, @warnings);

Appends one line for each warning to the same file, in the same way, with
C<warning> in the place of the reason. C<simpici-dispatch> hands the
warnings of Perl to it instead of leaving them to standard error.

=head2 failure_log_name

The name of that file below the store root, C<dispatch.log>.

=head2 failure_log_limit

The size at which it is set aside, 1 MiB.

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
