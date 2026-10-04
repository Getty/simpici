package SimpiCI::Worker;

use Moo;
with 'SimpiCI::Role::Secrets';

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
  # Before the dispatcher is asked for anything: it may be out of reach.
  $self->remove_orphaned_secrets;
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
  $self->_remove_secrets($secrets_root);
  croak __PACKAGE__.' cannot save the completion of run '.$claim->{run}.': '.$error
    unless $request;
  my $response = $self->_request($request);
  $pending->remove;
  return $response;
}

# One claim is executed at a time, and once removes its secret files before
# it returns: what lies below secrets/ when it begins was left by a worker
# that did not live to do that.
sub remove_orphaned_secrets {
  my ( $self ) = @_;
  my $directory = $self->store->root->child('secrets');
  return 0 unless $directory->is_dir;
  my @orphans = sort { $a->basename cmp $b->basename } $directory->children;
  for my $orphan (@orphans) {
    $self->_remove_secrets($orphan);
    warn __PACKAGE__.' removed orphaned secret files: secrets/'.$orphan->basename."\n";
  }
  return scalar @orphans;
}

# A link is removed, not followed. Whatever cannot be removed is an error:
# the worker does not go on with secret values it meant to delete.
sub _remove_secrets {
  my ( $self, $path ) = @_;
  my $name = $path->stringify;
  my $is_tree = !-l $name && -d $name;
  # Why it failed is not told apart: that it is still there is the error.
  eval { $is_tree ? $path->remove_tree({ safe => 0 }) : $path->remove; 1 };
  croak __PACKAGE__.' cannot remove secret files: '.$name if -l $name || -e $name;
  return;
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
    my $reason = $self->redact(__PACKAGE__.' run '.$claim->{run}.' aborted: '
      .$self->_abort_reason($error)."\n", $claim->{secrets});
    warn $reason;
    $log .= "\n" if length $log && $log !~ /\n\z/;
    $log .= $reason;
  }
  $log = substr($self->redact($log, $claim->{secrets}), -4 * 1024 * 1024);
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
  # Each secret becomes one NAME=VALUE line of an environment file. Whatever
  # is not one such line is refused before a file is written, and without
  # being quoted: an undefined value would be written as an empty one, a
  # reference as its address, a line end would begin a variable of its own.
  for my $values (values %$secrets) {
    croak __PACKAGE__.' invalid secret name in claim'
      if grep { !$self->secret_name_valid($_) } keys %$values;
    croak __PACKAGE__.' invalid secret value in claim'
      if grep { !$self->secret_value_valid($_) } values %$values;
  }
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

1;

=head1 NAME

SimpiCI::Worker - outbound SSH runner

=head1 DESCRIPTION

C<once> first retries a persisted completion, otherwise claims and executes one
exact revision. The SSH private key is never mounted in job containers. The
worker's entire state tree is private and must not be served by a web server.

A claim that cannot be executed is completed as a failed run instead of being
left to its lease: an event L<SimpiCI::Event> refuses, a claim of another
shape than the dispatcher sends, a secret that is not one line of an
environment file, secret files that cannot be written, a croak of
L<SimpiCI::Runner>. The event is built and the secrets are checked before any
secret file is written.
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

=head2 Secrets of a claim

The secrets of a claim are written to C<secrets/E<lt>runE<gt>/publish.env> and
C<deploy.env> below the store root, one C<NAME=VALUE> line each, and the
executor passes each file to the jobs of its phase. Every secret of the claim,
in whichever phase, has to be such a line: a name
L<SimpiCI::Role::Secrets/secret_name_valid> accepts and a value
L<SimpiCI::Role::Secrets/secret_value_valid> accepts. An undefined value, a
reference, an empty value and a value with a line end are refused, like a name
that would not be a variable of its own. The reasons are

  SimpiCI::Worker invalid secret name in claim
  SimpiCI::Worker invalid secret value in claim

and name neither the secret nor its value. The dispatcher grants nothing
else, so such a claim comes from a dispatcher of another version or is not
what the dispatcher sent.

The log is redacted by L<SimpiCI::Role::Secrets/redact> with every value of
the claim before it is saved as the completion; the dispatcher redacts it
again with its own copy of them. The log of the run below C<public/runs> in
the store of the worker is what the jobs wrote, unredacted.

The secret files of a claim are removed whatever became of it, also when its
completion could not be saved. C<once> croaks in that case, and for a claim
whose run is not a run number, which is refused before anything is written
and cannot be reported. It also croaks, with C<cannot remove secret files>
and the path, if the files are still there after it removed them.

A worker that is killed during a run removes nothing. Its secret files are
removed by the next C<once> on the same store, see
L</remove_orphaned_secrets>; the run itself keeps its lease at the dispatcher
until that expires.

=head1 METHODS

=head2 once

  my $response = $worker->once;

Returns the dispatcher's answer to the completion it delivered, or nothing if
there was no work. Before it asks the dispatcher for anything, it calls
L</remove_orphaned_secrets>.

Only one C<once> may run on a store at a time. C<simpici-worker> holds a lock
on the store for that.

=head2 remove_orphaned_secrets

  my $removed = $worker->remove_orphaned_secrets;

Removes every entry of C<secrets/> below the store root and returns how many
there were. C<once> removes the secret files of its claim before it returns,
so what is found there was left by a worker that ended during a run, and it
must not be called while a claim is executed on the same store. Each entry is
warned as

  SimpiCI::Worker removed orphaned secret files: secrets/N

without a value. A link is removed, not followed. Croaks if an entry cannot
be removed; C<once> then asks for no work, so that the worker does not go on
beside secret files it could not delete.

=head2 aborted_exit_code

Returns 125, the exit code reported for a claim that was not executed to its
end.

=cut
