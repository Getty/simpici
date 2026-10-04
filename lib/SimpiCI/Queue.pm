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

# Read without the lock: a queue file is replaced as a whole, and a run that
# is not leased after it was claimed never becomes leased again.
sub leased {
  my ( $self, $run ) = @_;
  croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
  my $record = $self->_record($run) or return 0;
  return ($record->{state} // '') eq 'running' && ($record->{expires} // 0) > time ? 1 : 0;
}

# Every reason a completion is refused for good. Each is sent to the worker
# as it stands here, so it says nothing of the run or of the dispatcher.
sub refusal_reasons { ( 'unknown run', 'stale claim', 'expired claim' ) }

sub _record {
  my ( $self, $run ) = @_;
  my $file = $self->store->root->child('queue', $run.'.json');
  return unless $file->is_file;
  return JSON::MaybeXS->new->decode($file->slurp_utf8);
}

# The reason this worker and token can never complete the run, or nothing.
# A run that has its result is not refused to the claim that completed it.
sub _refusal {
  my ( $self, $record, $worker, $token ) = @_;
  return 'unknown run' unless $record;
  return 'stale claim' unless ($record->{worker} // '') eq $worker
    && ($record->{token} // '') eq $token;
  return if $record->{result};
  return 'expired claim' unless $record->{state} eq 'running' && $record->{expires} > time;
  return;
}

sub refusal {
  my ( $self, $worker, $run, $token ) = @_;
  croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
  my $lock = $self->_lock;
  my $record = $self->_record($run);
  return $self->_refusal($record, $worker, $token // '');
}

sub finish {
  my ( $self, $worker, $run, $token, $result, $log ) = @_;
  croak __PACKAGE__.' invalid run' unless defined $run && $run =~ /\A[1-9][0-9]*\z/;
  croak __PACKAGE__.' invalid result' unless ref $result eq 'HASH'
    && ($result->{state} // '') =~ /\A(?:success|skipped|failed|timed_out|signalled)\z/
    && defined $result->{exit_code} && $result->{exit_code} =~ /\A[0-9]{1,3}\z/;
  my $lock = $self->_lock;
  my $record = $self->_record($run);
  my $refusal = $self->_refusal($record, $worker, $token);
  croak __PACKAGE__.' '.$refusal if $refusal;
  return $self->_save($record) if $record->{result};
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

C<finish> publishes the log before it records the result. A dispatcher that
dies in between leaves the run leased, and the worker's retry publishes the
log again. Once the result is recorded, a repeated completion returns the
report and publishes nothing: the log of a run is written by the completion
that was accepted, never by a later one.

=head1 METHODS

=head2 run

  my $report = $queue->run($event);

Enqueues the event, or returns the report of the run that already has its
deduplication key.

=head2 claim

  my $record = $queue->claim($worker);

Marks the running records whose lease has expired as interrupted, then leases
the oldest queued run to the worker and returns its record, or nothing if no
run is queued.

=head2 leased

  my $open = $queue->leased($run);

True while a completion of the run can still be accepted: it is claimed, has
no result and its lease has not expired. False for a queued, completed,
interrupted or unknown run, and for a run whose lease has expired but that no
claim has marked as interrupted yet. A run that is not leased after it was
claimed never becomes leased again. Croaks unless C<$run> is a run number.

=head2 refusal

  my $reason = $queue->refusal($worker, $run, $token);

Returns why this worker and token can never complete the run, or nothing if
they can or already did:

=over 4

=item C<unknown run>

The queue has no such run.

=item C<stale claim>

The run is claimed by another worker or with another token, or not claimed
at all.

=item C<expired claim>

The lease is over: it ran out, or a later claim marked the run as
interrupted.

=back

None of them changes with time or with another attempt, which is what tells
a refusal from an error. A run that has its result is not refused to the
worker and token that completed it: L</finish> returns its report again.
Croaks unless C<$run> is a run number.

=head2 refusal_reasons

Lists the reasons L</refusal> gives. They are fixed phrases without a value
of the run or of the dispatcher, because L<SimpiCI::Dispatcher> sends them to
the worker as they are.

=head2 finish

  my $report = $queue->finish($worker, $run, $token, $result, $log);

Records the result of a leased run for the worker and token that claimed it
and publishes its log. Croaks with the reason of L</refusal> for a completion
that is refused, and with C<invalid result> for a result that is none.

=cut
