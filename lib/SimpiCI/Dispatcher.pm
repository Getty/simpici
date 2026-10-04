package SimpiCI::Dispatcher;

use Moo;

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
  $self->_reject($where, 'invalid secret name')
    unless defined $name && !ref $name
    && $name =~ /\A(?:CICD_[A-Z0-9_]+|[A-Z][A-Z0-9_]*_TOKEN)\z/;
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
  $self->_reject($where, 'secret must be one nonempty line')
    if !length($value) || $value =~ /[\r\n\0]/;
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

sub request {
  my ( $self, $worker, $request ) = @_;
  croak __PACKAGE__.' invalid request' unless ref $request eq 'HASH';
  my $operation = $request->{operation} // '';
  if ($operation eq 'claim') {
    # Resolve every grant before taking a lease: a configuration error must
    # not use up queued work.
    my $grants = $self->_grants;
    my $record = $self->queue->claim($worker);
    return {} unless $record;
    my $secrets = $self->_secrets($record->{event}, $grants);
    # Keep a private snapshot so rotation cannot prevent completion redaction.
    $self->queue->store->write_json('claims/'.$record->{run}.'.json', $secrets);
    return { %$record, secrets => $secrets, timeout => $self->config->{timeout} // 3600 };
  }
  if ($operation eq 'finish') {
    my $run = $request->{run};
    croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
    my $log = $request->{log} // '';
    croak __PACKAGE__.' invalid log' if ref $log || length($log) > 4 * 1024 * 1024;
    my $file = $self->queue->store->root->child('claims', $run.'.json');
    if ($file->is_file) {
      my $secrets = $self->queue->store->_json->decode($file->slurp_utf8);
      my @values = sort { length($b) <=> length($a) }
        map { values %$_ } values %$secrets;
      for my $value (@values) { $log =~ s/\Q$value\E/[REDACTED]/g; }
    }
    return $self->queue->finish($worker, $run, $request->{token} // '',
      $request->{result}, $log);
  }
  croak __PACKAGE__.' unsupported operation';
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
file holding one nonempty line. An error names the repository, the secret and
the reason, never a secret value. A claim runs this check before it takes a
lease, so a configuration error leaves queued work queued; the values read by
that check are the ones handed out. A completion is accepted without the
check: it needs only the queue and the secret snapshot of its claim.

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

Serves one C<claim> or C<finish> request for the given worker identity.

=cut
