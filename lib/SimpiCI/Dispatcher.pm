package SimpiCI::Dispatcher;

use Moo;

# ABSTRACT: Restricted worker protocol and dispatcher-owned secret policy

use Carp qw( croak );
use Path::Tiny qw( path );
use Types::Standard qw( HashRef InstanceOf );
use namespace::autoclean;

has queue => (is => 'ro', isa => InstanceOf['SimpiCI::Queue'], required => 1);
has config => (is => 'ro', isa => HashRef, required => 1);

sub _secrets {
  my ( $self, $event ) = @_;
  my %phases;
  for my $repo ($self->config->{repositories}->@*) {
    next unless $repo->{name} eq $event->{repository}
      && $repo->{clone_url} eq $event->{clone_url};
    for my $secret (@{$repo->{secrets} // []}) {
      next unless grep { $_ eq $event->{ref} } @{$secret->{refs} // []};
      next unless grep { $_ eq $event->{event} } @{$secret->{events} // []};
      next if $event->{event} eq 'pull_request';
      next if $secret->{sources} && !grep { $_ eq $event->{source} } $secret->{sources}->@*;
      croak __PACKAGE__.' invalid secret name'
        unless ($secret->{name} // '') =~ /\A(?:CICD_[A-Z0-9_]+|[A-Z][A-Z0-9_]*_TOKEN)\z/
        && $secret->{name} !~ /\ACICD_(?:WORKSPACE|ROOT|OUTPUT|ARTIFACTS|EVENT_FILE|COMMIT|REF|SOURCE|EVENT|REPOSITORY|CLONE_URL|PHASE|JOB|IMAGE_REF|RUN_NUMBER)\z/;
      my $value = path($secret->{file})->slurp_utf8;
      $value =~ s/\r?\n\z//;
      croak __PACKAGE__.' secret must be one nonempty line' if !length($value) || $value =~ /[\r\n\0]/;
      for my $phase (@{$secret->{phases} // ['publish', 'deploy']}) {
        croak __PACKAGE__.' secrets only allowed in publish/deploy'
          unless $phase eq 'publish' || $phase eq 'deploy';
        $phases{$phase}{$secret->{name}} = $value;
      }
    }
  }
  return \%phases;
}

sub request {
  my ( $self, $worker, $request ) = @_;
  croak __PACKAGE__.' invalid request' unless ref $request eq 'HASH';
  my $operation = $request->{operation} // '';
  if ($operation eq 'claim') {
    my $record = $self->queue->claim($worker);
    return {} unless $record;
    my $secrets = $self->_secrets($record->{event});
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
repository, ref, event, optional source and publish/deploy phase. Public reports
are reconstructed from accepted events; worker-supplied metadata is discarded.

=cut
