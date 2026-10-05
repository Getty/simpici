package SimpiCI::Queue;
our $VERSION = '0.001';

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

sub _write {
  my ( $self, $record ) = @_;
  $self->store->write_json('queue/'.$record->{run}.'.json', $record);
  return $record;
}

sub _save {
  my ( $self, $record ) = @_;
  $self->_write($record);
  return $self->_publish($record);
}

sub _publish {
  my ( $self, $record ) = @_;
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

# The one place where a lease ends without a completion, for whoever holds
# the lock. Never replay a possibly completed publish/deploy after losing a
# worker: the run becomes interrupted, not queued.
#
# The report is published before the queue has the new state. Nothing comes
# back for an interrupted run, so a step that was cut off between the two
# must be one the next step takes again: with the queue written first, the
# report would say running for good.
sub _expire_leases {
  my ( $self, @records ) = @_;
  my $now = time;
  my @reports;
  for my $record (grep { $_->{state} eq 'running' && $_->{expires} <= $now } @records) {
    $record->{state} = 'interrupted';
    push @reports, $self->_publish($record);
    $self->_write($record);
  }
  return @reports;
}

sub expire_leases {
  my ( $self ) = @_;
  my $lock = $self->_lock;
  return $self->_expire_leases($self->_records);
}

sub claim {
  my ( $self, $worker ) = @_;
  croak __PACKAGE__.' invalid worker' unless $worker =~ /\A[a-zA-Z0-9_-]{1,64}\z/;
  my $lock = $self->_lock;
  my @records = $self->_records;
  $self->_expire_leases(@records);
  for my $record (@records) {
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

A lease ends in one of two ways, and both are decided under the lock of the
queue: L</finish> records the result of a run whose lease stands, and
L</expire_leases> interrupts a run whose lease ran out. Whichever comes
first is final. A run that has its result is never interrupted, and a
completion for an interrupted run is refused, so a run is never both.

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

Ends the leases that ran out as L</expire_leases> does, then leases the
oldest queued run to the worker and returns its record, or nothing if no run
is queued.

=head2 expire_leases

  my @reports = $queue->expire_leases;

Marks every run as C<interrupted> that is C<running> on a lease that ran
out, publishes its report and returns the reports of the runs it marked, in
the order of their run numbers; nothing if there was none. An interrupted
run is not queued again and has no result.

The report of a run is published before the queue records the new state.
Nothing is ever asked about an interrupted run again, so a process that is
killed between the two leaves a lease that is still there and expired, and
the next call ends it once more; the other order would leave a report that
says C<running> for good.

L</claim> does the same before it leases a run. L<SimpiCI::Dispatcher> calls
it for every request and C<simpicid> in every polling cycle, so that a run
whose worker is gone does not stay C<running> until a worker asks.

=head2 leased

  my $open = $queue->leased($run);

True while a completion of the run can still be accepted: it is claimed, has
no result and its lease has not expired. False for a queued, completed,
interrupted or unknown run, and for a run whose lease has expired but that
L</expire_leases> has not marked as interrupted yet. A run that is not leased
after it was claimed never becomes leased again. Croaks unless C<$run> is a
run number.

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

The lease is over: it ran out, whether or not L</expire_leases> has marked
the run as interrupted yet.

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
