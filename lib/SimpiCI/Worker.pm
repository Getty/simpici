package SimpiCI::Worker;

use Moo;

# ABSTRACT: Outbound-only worker with durable completion retry

use Carp qw( croak );
use IPC::Open3 qw( open3 );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;
use Types::Standard qw( Str InstanceOf );
use namespace::autoclean;

has host => (is => 'ro', isa => Str, required => 1);
has store => (is => 'ro', isa => InstanceOf['SimpiCI::Store'], required => 1);
has runner => (is => 'ro', isa => InstanceOf['SimpiCI::Runner'], required => 1);

sub _request {
  my ( $self, $request ) = @_;
  croak __PACKAGE__.' invalid SSH destination' unless $self->host =~ /\A[a-zA-Z0-9_][a-zA-Z0-9_.@-]*\z/;
  my $json = JSON::MaybeXS->new(canonical => 1, convert_blessed => 1);
  my $pid = open3(my $input, my $output, '>&STDERR',
    'ssh', '-T', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes',
    '-oConnectTimeout=15', '-oServerAliveInterval=15', '-oServerAliveCountMax=2',
    $self->host, 'simpici-dispatch');
  print {$input} $json->encode($request) or croak __PACKAGE__.' cannot send request';
  close $input;
  my $response = do { local $/; <$output> };
  waitpid($pid, 0);
  croak __PACKAGE__.' dispatcher connection failed' if $?;
  return $json->decode($response);
}

sub once {
  my ( $self ) = @_;
  $self->store->prepare;
  my $pending = $self->store->root->child('completion.json');
  if ($pending->is_file) {
    my $request = JSON::MaybeXS->new->decode($pending->slurp_utf8);
    my $response = $self->_request($request);
    $pending->remove;
    return $response;
  }
  my $claim = $self->_request({ operation => 'claim' });
  return unless $claim->{run};
  # The run number names the secret directory and the completion: a claim
  # without one can be neither executed nor reported.
  croak __PACKAGE__.' invalid run in claim' unless $claim->{run} =~ /\A[1-9][0-9]*\z/;
  my $secrets_root = $self->store->root->absolute->child('secrets', $claim->{run});
  my ( $request, $error );
  eval { $request = $self->_completion($claim, $secrets_root); 1 }
    or $error = $@ || 'unknown error';
  # No outcome of a claim leaves its secret files behind, not even a
  # completion that could not be saved.
  $secrets_root->remove_tree;
  croak __PACKAGE__.' cannot save the completion of run '.$claim->{run}.': '.$error
    unless $request;
  my $response = $self->_request($request);
  $pending->remove;
  return $response;
}

# Runs the claim and saves what is to be reported about it. A claim that
# cannot be executed is a failed run with its reason, not an error of the
# worker: the dispatcher would otherwise hear nothing until the lease expires.
sub _completion {
  my ( $self, $claim, $secrets_root ) = @_;
  my ( $report, $error );
  eval { $report = $self->_run_claim($claim, $secrets_root); 1 }
    or $error = $@ || 'unknown error';
  my $log_path = $self->store->root->child('public', 'runs', $claim->{run}.'.log');
  my $log = $log_path->is_file ? $log_path->slurp_utf8 : '';
  unless ($report) {
    $report = { state => 'failed', exit_code => $self->aborted_exit_code };
    my $reason = $self->_redact($claim, __PACKAGE__.' run '.$claim->{run}.' aborted: '
      .$self->_abort_reason($error)."\n");
    warn $reason;
    $log .= "\n" if length $log && $log !~ /\n\z/;
    $log .= $reason;
  }
  $log = substr($self->_redact($claim, $log), -4 * 1024 * 1024);
  my $request = {
    operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => { state => $report->{state}, exit_code => $report->{exit_code} },
    log => $log
  };
  $self->store->write_json('completion.json', $request);
  return $request;
}

# What an error says, without where it was raised. Only the first line: a
# backtrace below it would carry arguments. And without the " at FILE line N"
# that croak, die and a type error end it with: the log is public, the file is
# one of the installation. The greedy start keeps an " at " of the message
# itself.
sub _abort_reason {
  my ( $self, $error ) = @_;
  my $reason = (split /\n/, $error)[0] // 'unknown error';
  $reason =~ s/\A(.*) at .+? line \d+(?:, <.*> (?:line|chunk) \d+)?\.?\z/$1/;
  return $reason;
}

sub _run_claim {
  my ( $self, $claim, $secrets_root ) = @_;
  # The event is built first: one this worker refuses gets no secret written.
  # Its fields need their types before that, because a type error would quote
  # what it found in their place, and the reason is published.
  my $fields = $claim->{event};
  croak __PACKAGE__.' invalid event in claim' unless ref $fields eq 'HASH'
    && ref($fields->{payload} // {}) eq 'HASH'
    && !grep { !defined || ref } $fields->@{qw( source event repository clone_url ref commit )};
  my $event = SimpiCI::Event->new(%$fields);
  my $secrets = $claim->{secrets} // {};
  croak __PACKAGE__.' invalid secrets in claim'
    unless ref $secrets eq 'HASH' && !grep { ref $_ ne 'HASH' } values %$secrets;
  $secrets_root->mkpath;
  for my $phase (qw( publish deploy )) {
    my $values = $secrets->{$phase} // {};
    $secrets_root->child($phase.'.env')->spew_utf8(join '',
      map { $_.'='.$values->{$_}."\n" } sort keys %$values);
  }
  my $temporary = $self->store->root->absolute->child('tmp');
  $temporary->mkpath;
  local $ENV{RUNNER_TEMP} = $temporary->stringify;
  local $ENV{SIMPICI_SECRETS_DIR} = $secrets_root->stringify;
  return SimpiCI::Runner->new(
    store => $self->store, runner_script => $self->runner->runner_script,
    timeout => $claim->{timeout}
  )->run($event, $claim->{run});
}

sub aborted_exit_code { 125 }

# Every assigned value of the claim, whatever shape the claim arrived in.
sub _secret_values {
  my ( $self, $secrets ) = @_;
  return ref $secrets eq 'HASH' ? map { $self->_secret_values($_) } values %$secrets
    : defined $secrets && !ref $secrets && length $secrets ? $secrets
    : ();
}

sub _redact {
  my ( $self, $claim, $text ) = @_;
  for my $value ($self->_secret_values($claim->{secrets})) {
    $text =~ s/\Q$value\E/[REDACTED]/g;
  }
  return $text;
}

1;

=head1 NAME

SimpiCI::Worker - outbound SSH runner

=head1 DESCRIPTION

C<once> first retries a persisted completion, otherwise claims and executes one
exact revision. The SSH private key is never mounted in job containers. The
worker's entire state tree is private and must not be served by a web server.

A claim that cannot be executed is completed as a failed run instead of being
left to its lease: an event L<SimpiCI::Event> refuses, a claim of another
shape than the dispatcher sends, secret files that cannot be written, a croak
of L<SimpiCI::Runner>. The event is built before any secret file is written.
The result is the state C<failed> with L</aborted_exit_code>. The log is what
the run wrote up to then, followed by the line

  SimpiCI::Worker run N aborted: REASON

which C<once> also warns. REASON is the first line of the error, without the
C< at FILE line N> that C<croak> and C<die> end it with, and with the assigned
secret values redacted as in the rest of the log. The log is public, so the
reason does not say where in the installation the error was raised. A path the
message itself names stays in it, such as the file L<SimpiCI::Store> could not
publish, and so does the C<source> of a refused event; the other fields of an
event are refused without being quoted.

The secret files of a claim are removed whatever became of it, also when its
completion could not be saved. C<once> croaks in that case, and for a claim
whose run is not a run number, which is refused before anything is written
and cannot be reported.

=head1 METHODS

=head2 once

  my $response = $worker->once;

Returns the dispatcher's answer to the completion it delivered, or nothing if
there was no work.

=head2 aborted_exit_code

Returns 125, the exit code reported for a claim that was not executed to its
end.

=cut
