package SimpiCI::Queue;

use Moo;

# ABSTRACT: Durable deduplicated dispatch queue with fenced leases

use Carp qw( croak );
use Fcntl qw( LOCK_EX );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use SimpiCI::Event;
use Types::Standard qw( InstanceOf Int );
use namespace::autoclean;

has store => (is => 'ro', isa => InstanceOf['SimpiCI::Store'], required => 1);
has lease_seconds => (is => 'ro', isa => Int, default => sub { 7200 });

sub _lock {
  my ( $self ) = @_;
  $self->store->prepare;
  my $fh = $self->store->root->child('queue.lock')->opena_raw;
  flock($fh, LOCK_EX) or croak __PACKAGE__.' cannot lock queue: '.$!;
  return $fh;
}

sub _records {
  my ( $self ) = @_;
  my $directory = $self->store->root->child('queue');
  $directory->mkpath;
  return map { JSON::MaybeXS->new->decode($_->slurp_utf8) }
    sort { (split /\./, $a->basename)[0] <=> (split /\./, $b->basename)[0] }
    grep { $_->basename =~ /\A[1-9][0-9]*\.json\z/ } $directory->children;
}

sub _save {
  my ( $self, $record ) = @_;
  $self->store->write_json('queue/'.$record->{run}.'.json', $record);
  my $event = $record->{event};
  my $report = {
    (map { $_ => $event->{$_} } qw( source event repository ref commit )),
    run => $record->{run}, state => $record->{state},
    log => '/runs/'.$record->{run}.'.log',
    $record->{result} ? ($record->{result}->%*) : ()
  };
  $self->store->write_json('public/runs/'.$record->{run}.'.json', $report);
  my @runs = sort { $b <=> $a } map { $_->{run} } $self->_records;
  $self->store->write_json('public/runs/index.json', { latest => $runs[0], runs => \@runs });
  return $report;
}

sub run {
  my ( $self, $event ) = @_;
  my $lock = $self->_lock;
  for my $record ($self->_records) {
    return $self->_save($record) if $record->{key} eq $event->deduplication_key;
  }
  return $self->_save({
    run => $self->store->allocate_run,
    key => $event->deduplication_key,
    event => $event->as_hash,
    state => 'queued'
  });
}

sub claim {
  my ( $self, $worker ) = @_;
  croak __PACKAGE__.' invalid worker' unless $worker =~ /\A[a-zA-Z0-9_-]{1,64}\z/;
  my $lock = $self->_lock;
  for my $record ($self->_records) {
    if ($record->{state} eq 'running' && $record->{expires} <= time) {
      # Never replay a possibly completed publish/deploy after losing a worker.
      $record->{state} = 'interrupted';
      $self->_save($record);
    }
    next unless $record->{state} eq 'queued';
    $record->{state} = 'running';
    $record->{worker} = $worker;
    my $random = path('/dev/urandom')->openr_raw;
    my $bytes;
    read($random, $bytes, 32) == 32 or croak __PACKAGE__.' cannot read entropy';
    $record->{token} = unpack 'H*', $bytes;
    $record->{expires} = time + $self->lease_seconds;
    $self->_save($record);
    return $record;
  }
  return;
}

sub finish {
  my ( $self, $worker, $run, $token, $result, $log ) = @_;
  croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
  croak __PACKAGE__.' invalid result' unless ref $result eq 'HASH'
    && ($result->{state} // '') =~ /\A(?:success|skipped|failed|timed_out|signalled)\z/
    && defined $result->{exit_code} && $result->{exit_code} =~ /\A[0-9]{1,3}\z/;
  my $lock = $self->_lock;
  my $file = $self->store->root->child('queue', $run.'.json');
  croak __PACKAGE__.' unknown run' unless $file->is_file;
  my $record = JSON::MaybeXS->new->decode($file->slurp_utf8);
  croak __PACKAGE__.' stale claim' unless ($record->{worker} // '') eq $worker
    && ($record->{token} // '') eq $token;
  return $self->_save($record) if $record->{result};
  croak __PACKAGE__.' expired claim' unless $record->{state} eq 'running'
    && $record->{expires} > time;
  $record->{state} = $result->{state};
  $record->{result} = { state => $result->{state}, exit_code => 0 + $result->{exit_code} };
  my $target = $self->store->root->child('public', 'runs', $run.'.log');
  my $temporary = $target->sibling('.'.$run.'.log.tmp');
  $temporary->spew_utf8($log // '');
  $temporary->move($target);
  return $self->_save($record);
}

1;

=head1 NAME

SimpiCI::Queue - durable dispatch and fenced completion

=head1 DESCRIPTION

C<run> accepts an event once by its deduplication key. C<claim> serializes
workers through a filesystem lock and atomically publishes a lease before
returning it. C<finish> accepts only the owning worker and claim token.
Expired leases become interrupted, never automatically replayed: a lost
worker may already have performed an external publish operation.

=cut
