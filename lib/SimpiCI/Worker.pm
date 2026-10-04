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
use Types::Standard qw( Int Str InstanceOf );
use namespace::autoclean;

has host => (is => 'ro', isa => Str, required => 1);
has store => (is => 'ro', isa => InstanceOf['SimpiCI::Store'], required => 1);
has runner => (is => 'ro', isa => InstanceOf['SimpiCI::Runner'], required => 1);

# What could not be removed and was said so, so that it is said once and not
# in every cycle.
has _kept => (is => 'ro', init_arg => undef, default => sub { {} });

sub _request {
  my ( $self, $request ) = @_;
  croak __PACKAGE__.' invalid SSH destination' unless $self->host =~ /\A[a-zA-Z0-9_][a-zA-Z0-9_.@-]*\z/;
  my $json = JSON::MaybeXS->new(canonical => 1, convert_blessed => 1);
  my $pid = open3(my $input, my $output, '>&STDERR',
    'ssh', '-T', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes',
    '-oConnectTimeout=15', '-oServerAliveInterval=15', '-oServerAliveCountMax=2',
    $self->host, 'simpici-dispatch');
  # An ssh that ended before it read the request must not end the worker
  # with it: the write fails instead, and the request is sent again later.
  local $SIG{PIPE} = 'IGNORE';
  my $sent = print {$input} $json->encode($request);
  $sent = close($input) && $sent;
  my $response = do { local $/; <$output> };
  close $output;
  # Waited for in every case, so that no ssh is left behind unreaped.
  waitpid($pid, 0);
  croak __PACKAGE__.' dispatcher connection failed' if $? || !$sent;
  # Only a complete answer is one: whatever else arrived says nothing about
  # what the dispatcher did with the request.
  my $answer = eval { $json->decode($response // '') };
  croak __PACKAGE__.' invalid dispatcher response' unless ref $answer eq 'HASH';
  return $answer;
}

sub once {
  my ( $self ) = @_;
  $self->_own_root;
  $self->store->prepare;
  # Before the dispatcher is asked for anything: it may be out of reach.
  # Containers first, because they still write what is removed after them.
  # Each is tried whatever became of the one before: secret files and logs
  # do not wait for a docker that cannot be asked.
  my @kept;
  for my $remove (qw( remove_orphaned_containers remove_orphaned_secrets
      remove_orphaned_run_files )) {
    eval { $self->$remove; 1 } or push @kept, $self->_message($@);
  }
  croak join('; ', @kept) if @kept;
  my $pending = $self->_pending;
  return $self->_deliver(JSON::MaybeXS->new->decode($pending->slurp_utf8)) if $pending->is_file;
  my $claim = $self->_request({ operation => 'claim' });
  return unless $claim->{run};
  # The run number names the secret directory and the completion: a claim
  # without one can be neither executed nor reported.
  croak __PACKAGE__.' invalid run in claim' unless $claim->{run} =~ /\A[1-9][0-9]*\z/;
  my $secrets_root = $self->store->root->absolute->child('secrets', $claim->{run});
  my ( $request, $error, $kept, $stopped );
  {
    # A signal that ends the worker waits until the claim is put away. The
    # runner is asked for it between and during its commands and ends the
    # run; what the run leaves is removed here.
    my @signals = $self->runner->stop_signals_in_effect;
    local @SIG{@signals} = ( sub { $stopped //= $_[0] } ) x @signals;
    eval { $request = $self->_completion($claim, $secrets_root, sub { $stopped }); 1 }
      or $error = $@ || 'unknown error';
    # No outcome of a claim leaves its secret files or its log behind, not
    # even a completion that could not be saved. Both are tried.
    eval { $self->_remove_secrets($secrets_root); 1 } or $kept = $@;
    eval { $self->_remove_run_files($claim->{run}); 1 } or $kept //= $@;
  }
  if (defined $stopped) {
    # The completion waits for the next start. What else is to be said is
    # said now: the signal ends the worker, unless the caller holds it back.
    warn $self->_message($kept)."\n" if defined $kept;
    warn __PACKAGE__.' cannot save the completion of run '.$claim->{run}.': '
      .$self->_message($error)."\n" unless $request;
    $self->runner->end_by($stopped);
    return;
  }
  croak $self->_message($kept) if defined $kept;
  # One line, as everything the worker says on standard error: the error
  # ends with where it was raised, and croak adds where once was called.
  croak __PACKAGE__.' cannot save the completion of run '.$claim->{run}.': '
    .$self->_message($error) unless $request;
  return $self->_deliver($request);
}

sub _pending { $_[0]->store->root->child('completion.json') }

# Sends the saved completion. It leaves completion.json only when the
# dispatcher answered: accepted, it is removed; refused for good, it is put
# aside. A request that failed, for whatever reason, keeps it for the next
# cycle, and so does an answer that is neither.
sub _deliver {
  my ( $self, $request ) = @_;
  my $response = $self->_request($request);
  if (exists $response->{rejected}) {
    my $reason = $response->{rejected};
    croak __PACKAGE__.' invalid dispatcher response' unless $self->_refusal_valid($reason);
    $self->_set_aside($request, $reason);
    return $response;
  }
  $self->_pending->remove;
  return $response;
}

# A reason is a few lowercase words, as SimpiCI::Queue->refusal_reasons has
# them. It is written to standard error, so nothing else passes as one.
sub _refusal_valid {
  my ( $self, $reason ) = @_;
  return defined $reason && !ref $reason && length $reason <= 64
    && $reason =~ /\A[a-z]+(?: [a-z]+)*\z/;
}

# Renamed, not copied: the completion is either still to be sent or kept
# under rejected/, whenever the worker is interrupted.
sub _set_aside {
  my ( $self, $request, $reason ) = @_;
  my $run = $request->{run};
  croak __PACKAGE__.' invalid run in completion'
    unless defined $run && !ref $run && $run =~ /\A[1-9][0-9]*\z/;
  my $kept = $self->store->root->child('rejected', $run.'.json');
  $kept->parent->mkpath;
  rename($self->_pending->stringify, $kept->stringify)
    or croak __PACKAGE__.' cannot keep the rejected completion of run '.$run.': '.$!;
  warn __PACKAGE__.' completion of run '.$run.' rejected by the dispatcher: '.$reason
    .'; kept as rejected/'.$run.".json\n";
  return $kept;
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

# Whatever cannot be removed is an error: the worker does not go on with
# secret values it meant to delete.
sub _remove_secrets {
  my ( $self, $path ) = @_;
  croak __PACKAGE__.' cannot remove secret files: '.$path unless $self->_removed($path);
  return;
}

# Whether nothing is left of it. A link is removed, not followed. Why
# something stayed is not told apart: that it is still there is what counts.
sub _removed {
  my ( $self, $path ) = @_;
  my $name = $path->stringify;
  my $is_tree = !-l $name && -d $name;
  eval { $is_tree ? $path->remove_tree({ safe => 0 }) : $path->remove; 1 };
  return -l $name || -e $name ? 0 : 1;
}

# Where a run leaves files of its own below the store root, besides its log
# and its report: its event, the temporary files of the executor with the
# raw logs, outputs and artifacts of its jobs, and its checkout.
sub run_directories { qw( runs tmp work ) }

sub _log_directory { $_[0]->store->root->child('public', 'runs') }

# What only a dispatcher or a polling daemon keeps in its state root. Their
# logs are the published ones and their checkouts those of local runs: a
# worker that was pointed at such a root by mistake removes neither.
sub foreign_state { qw( claims queue state ) }

sub _own_root {
  my ( $self ) = @_;
  my $root = $self->store->root;
  my @theirs = grep { $root->child($_)->exists } $self->foreign_state or return;
  croak __PACKAGE__.' root is the state of a dispatcher or a daemon, it has '
    .join(', ', map { $_.'/' } @theirs).': '.$root;
}

# The containers of a run that was cut off may still write what is removed
# after them, and still carry the secrets of its claim.
sub remove_orphaned_containers {
  my ( $self ) = @_;
  my $removed;
  eval { $removed = $self->runner->remove_orphaned_containers; 1 }
    or croak __PACKAGE__.' cannot remove orphaned containers: '.$self->_message($@);
  warn __PACKAGE__.' removed orphaned containers: '.$removed."\n" if $removed;
  return $removed;
}

# One claim is executed at a time, and once removes what its run left before
# it returns: what lies there when it begins was left by a worker that did
# not live to do that, or by a version that removed nothing.
sub remove_orphaned_run_files {
  my ( $self ) = @_;
  $self->_own_root;
  my $root = $self->store->root;
  my $removed = 0;
  my $logs = $self->_log_directory;
  my @logs = $logs->is_dir ? grep { $_->basename =~ /\.log\z/ } $logs->children : ();
  for my $log (sort { $a->basename cmp $b->basename } @logs) {
    $self->_remove_log($log);
    warn __PACKAGE__.' removed orphaned run files: public/runs/'.$log->basename."\n";
    $removed++;
  }
  # A completion that a killed worker was still writing: never the one that
  # is delivered, and with the log of its run in it.
  for my $unfinished (sort { $a->basename cmp $b->basename }
      $root->children(qr/\A\.completion\.json\.tmp\.[0-9]+\z/)) {
    next unless $self->_remove_run_entry($unfinished, $unfinished->basename);
    warn __PACKAGE__.' removed orphaned run files: '.$unfinished->basename."\n";
    $removed++;
  }
  for my $directory ($self->run_directories) {
    my $parent = $root->child($directory);
    next unless $parent->is_dir;
    for my $entry (sort { $a->basename cmp $b->basename } $parent->children) {
      next unless $self->_remove_run_entry($entry, $directory.'/'.$entry->basename);
      warn __PACKAGE__.' removed orphaned run files: '.$directory.'/'.$entry->basename."\n";
      $removed++;
    }
  }
  return $removed;
}

sub _remove_run_files {
  my ( $self, $run ) = @_;
  $self->_remove_log($self->_log_directory->child($run.'.log'));
  $self->_remove_run_entry($self->store->root->child($_, $run), $_.'/'.$run)
    for $self->run_directories;
  return;
}

# The log is what the jobs printed, with the secret values in it. It is an
# error like a secret file that cannot be removed.
sub _remove_log {
  my ( $self, $log ) = @_;
  croak __PACKAGE__.' cannot remove the log of a run: '.$log unless $self->_removed($log);
  return;
}

# What a job wrote may belong to another account than the worker, when the
# container daemon maps none to it. That stops no run: it is said once, and
# tried again in every cycle.
sub _remove_run_entry {
  my ( $self, $entry, $name ) = @_;
  if ($self->_removed($entry)) {
    delete $self->_kept->{$name};
    return 1;
  }
  warn __PACKAGE__.' cannot remove run files: '.$name."\n" unless $self->_kept->{$name}++;
  return 0;
}

# Runs the claim and saves what is to be reported about it. A claim that
# cannot be executed is a failed run with its reason, not an error of the
# worker: the dispatcher would otherwise hear nothing until the lease expires.
sub _completion {
  my ( $self, $claim, $secrets_root, $stop ) = @_;
  my ( $report, $reason, $error );
  eval { ( $report, $reason, $error ) = $self->_run_claim($claim, $secrets_root, $stop); 1 }
    or ( $report, $reason, $error ) = ( undef, undef, $@ || 'unknown error' );
  my $log_path = $self->store->root->child('public', 'runs', $claim->{run}.'.log');
  my $log = $log_path->is_file ? $log_path->slurp_utf8 : '';
  unless ($report) {
    $report = { state => 'failed', exit_code => $self->aborted_exit_code };
    # The log is published and gets the reason, which is one of a list. What
    # the error said names files of this worker and is for whoever reads its
    # standard error, with the secret values of the claim redacted.
    my $aborted = __PACKAGE__.' run '.$claim->{run}.' aborted: '.$self->abort_reason($reason);
    warn $self->redact($aborted.( defined $error ? ': '.$self->_first_line($error) : '' )."\n",
      $claim->{secrets});
    $log .= "\n" if length $log && $log !~ /\n\z/;
    $log .= $aborted."\n";
  }
  $log = $self->redacted_tail($self->redact($log, $claim->{secrets}), 4 * 1024 * 1024);
  my $request = {
    operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => { state => $report->{state}, exit_code => $report->{exit_code} },
    log => $log
  };
  $self->store->write_json('completion.json', $request);
  return $request;
}

# Every reason the log gives for a claim that was not executed to its end.
# The log is published: it gets one of these as it stands here and nothing of
# what an error said, so that no path, no file of the installation and no
# value of the claim can be in it. The last one is for everything that is none
# of the others.
sub abort_reasons {
  return (
    'invalid event in claim',
    'invalid secrets in claim',
    'invalid secret name in claim',
    'invalid secret value in claim',
    'invalid timeout in claim',
    'cannot write secret files',
    'cannot create temporary directory',
    'run supervisor failed',
    'internal error'
  );
}

# What is published for a reason: itself if it is one of the list, the last
# one of the list for whatever else it may be.
sub abort_reason {
  my ( $self, $reason ) = @_;
  my @reasons = $self->abort_reasons;
  return $reasons[-1] unless defined $reason && !ref $reason;
  return ( grep { $_ eq $reason } @reasons )[0] // $reasons[-1];
}

# What an error says, in one line: a backtrace below it would carry
# arguments. For standard error, which has one line for one event.
sub _first_line {
  my ( $self, $error ) = @_;
  return ( split /\n/, $error // '' )[0] // 'unknown error';
}

# The same without the " at FILE line N" that croak, die and a type error
# end it with, for an error that is raised again and gets its own. The greedy
# start keeps an " at " of the message itself, and a message that ends like
# that is cut short. Nothing that is published is made with it.
sub _message {
  my ( $self, $error ) = @_;
  my $message = $self->_first_line($error);
  $message =~ s/\A(.*) at .+? line \d+(?:, <.*> (?:line|chunk) \d+)?\.?\z/$1/;
  return $message;
}

# Returns the report of the run. For a claim that is not executed to its end
# it returns nothing in its place, then the reason, one of abort_reasons, and
# what the error said if there was one. Only the reason is published.
sub _run_claim {
  my ( $self, $claim, $secrets_root, $stop ) = @_;
  # The event is built first: one this worker refuses gets no secret written.
  my $fields = $claim->{event};
  return ( undef, 'invalid event in claim' ) unless ref $fields eq 'HASH'
    && ref($fields->{payload} // {}) eq 'HASH'
    && !grep { !defined || ref } $fields->@{qw( source event repository clone_url ref commit )};
  my $event;
  eval { $event = SimpiCI::Event->new(%$fields); 1 }
    or return ( undef, 'invalid event in claim', $@ );
  my $secrets = $claim->{secrets} // {};
  return ( undef, 'invalid secrets in claim' )
    unless ref $secrets eq 'HASH' && !grep { ref $_ ne 'HASH' } values %$secrets;
  # Each secret becomes one NAME=VALUE line of an environment file. Whatever
  # is not one such line is refused before a file is written, and without
  # being quoted: an undefined value would be written as an empty one, a
  # reference as its address, a line end would begin a variable of its own.
  for my $values (values %$secrets) {
    return ( undef, 'invalid secret name in claim' )
      if grep { !$self->secret_name_valid($_) } keys %$values;
    return ( undef, 'invalid secret value in claim' )
      if grep { !$self->secret_value_valid($_) } values %$values;
  }
  # What the runner accepts as its limit, asked before a secret is written.
  return ( undef, 'invalid timeout in claim' ) unless Int->check($claim->{timeout});
  eval { $self->_write_secrets($secrets_root, $secrets); 1 }
    or return ( undef, 'cannot write secret files', $@ );
  # A directory of the run, so that what the executor keeps there goes with it.
  my $temporary = $self->store->root->absolute->child('tmp', $claim->{run});
  eval { $temporary->mkpath; 1 } or return ( undef, 'cannot create temporary directory', $@ );
  local $ENV{RUNNER_TEMP} = $temporary->stringify;
  local $ENV{SIMPICI_SECRETS_DIR} = $secrets_root->stringify;
  # A runner of the class the worker was given: the same signals end it, and
  # its containers are found by the same store. The signals themselves are
  # held back by once, so the runner is told where to ask for them.
  my $report;
  eval {
    $report = ( ref $self->runner )->new(
      store => $self->store, runner_script => $self->runner->runner_script,
      timeout => $claim->{timeout}, $stop ? ( stop_requested => $stop ) : ()
    )->run($event, $claim->{run});
    1;
  } or return ( undef, 'run supervisor failed', $@ );
  return $report;
}

sub _write_secrets {
  my ( $self, $secrets_root, $secrets ) = @_;
  $secrets_root->mkpath;
  for my $phase (qw( publish deploy )) {
    my $values = $secrets->{$phase} // {};
    $secrets_root->child($phase.'.env')->spew_utf8(join '',
      map { $_.'='.$values->{$_}."\n" } sort keys %$values);
  }
  return;
}

sub aborted_exit_code { 125 }

1;

=head1 NAME

SimpiCI::Worker - outbound SSH runner

=head1 DESCRIPTION

C<once> first retries a persisted completion, otherwise claims and executes one
exact revision. A completion the dispatcher refuses for good is put aside
instead of being retried. The SSH private key is never mounted in job
containers. The worker's entire state tree is private and must not be served
by a web server.

A claim that cannot be executed is completed as a failed run instead of being
left to its lease: an event L<SimpiCI::Event> refuses, a claim of another
shape than the dispatcher sends, a secret that is not one line of an
environment file, secret files that cannot be written, a croak of
L<SimpiCI::Runner>. The event is built and the secrets and the timeout are
checked before any secret file is written.
The result is the state C<failed> with L</aborted_exit_code>. The log is what
the run wrote up to then, followed by the line

  SimpiCI::Worker run N aborted: REASON

The log is published, so REASON is one of the fixed phrases of
L</abort_reasons> and nothing of what the error itself said. No reason has a
path below the store of the worker in it, a file or a line of the
installation, or a value of the claim, and an error nobody foresaw is
C<internal error>, whatever its message. What the error said goes to
standard error and nowhere else: C<once> warns the same line with it,

  SimpiCI::Worker run N aborted: REASON: ERROR

ERROR is the first line of the error as it was raised, with the files it
names and with the C< at FILE line N> that C<croak> and C<die> end it with,
and with the assigned secret values redacted as in the log. A reason that
came of no error, such as C<invalid secret name in claim>, is warned alone.

=head2 What is written to standard error

Standard error is the log of whoever operates the worker, and is not
published. Its lines name files below the store root and, for an error, the
file and the line of the installation where it was raised: that is what an
error is found by. One event is one line. A line that C<once> warns begins
with the class that says it, C<SimpiCI::Worker> or C<SimpiCI::Runner>. What
C<once> croaks with is one line as well, the first of the error it passes
on, and C<simpici-worker> writes it after C<simpici-worker: >.

=head2 Delivering a completion

The completion of a run is saved as C<completion.json> below the store root
before it is sent, and C<once> sends a saved one before it claims anything.
What becomes of the file depends on what the dispatcher answered:

=over 4

=item *

The report of the run: the completion was accepted, now or by an earlier
attempt whose answer was lost. The file is removed.

=item *

C<{ "rejected": REASON }>: the dispatcher will never accept it, see
L<SimpiCI::Queue/refusal>. The file is renamed to
C<rejected/E<lt>runE<gt>.json>, replacing what was kept there for the same
run, and C<once> warns

  SimpiCI::Worker completion of run N rejected by the dispatcher: REASON; kept as rejected/N.json

and returns the answer. The next C<once> claims work again. REASON is one of
the phrases of L<SimpiCI::Queue/refusal_reasons>; the worker accepts a few
lowercase words and nothing else in its place.

=item *

Anything else: no connection, an C<ssh> or a dispatcher that ended with
another exit code than 0, an answer that is not one JSON object or whose
C<rejected> is not such a reason. C<once> croaks with
C<dispatcher connection failed> or C<invalid dispatcher response>, the file
stays, and the next C<once> sends it again. None of these says what the
dispatcher did with the completion, so none of them ends the retry.

=back

What is kept under C<rejected/> is the request as it was sent: the result,
the claim token, and the log with the secret values of the claim already
redacted. The secret files of the run are removed before a completion is
sent. Nothing reads the directory and nothing removes from it; it is the
operator's to look at and to empty. A completion can be put back as
C<completion.json> while no worker runs on the store, and is then sent
again.

A request to the dispatcher that cannot be written, because C<ssh> ended
before it read it, fails like any other connection; it does not end the
process with C<SIGPIPE>.

=head2 Secrets of a claim

The secrets of a claim are written to C<secrets/E<lt>runE<gt>/publish.env> and
C<deploy.env> below the store root, one C<NAME=VALUE> line each, and the
executor passes each file to the jobs of its phase. Every secret of the claim,
in whichever phase, has to be such a line: a name
L<SimpiCI::Role::Secrets/secret_name_valid> accepts and a value
L<SimpiCI::Role::Secrets/secret_value_valid> accepts. An undefined value, a
reference, an empty value, a value with a line end and a value that contains
the redaction marker are refused, like a name that would not be a variable of
its own. The reasons are
C<invalid secret name in claim> and C<invalid secret value in claim>, which
name neither the secret nor its value. The dispatcher grants nothing
else, so such a claim comes from a dispatcher of another version or is not
what the dispatcher sent.

The log is redacted by L<SimpiCI::Role::Secrets/redact> with every value of
the claim before it is saved as the completion; the dispatcher redacts it
again with its own copy of them. The completion carries the last 4 MiB of
the redacted log, cut by L<SimpiCI::Role::Secrets/redacted_tail> so that no
marker is split: the second pass leaves a marker alone, but not what is left
of one. The log of the run below C<public/runs> in
the store of the worker is what the jobs wrote, unredacted, and is removed
as soon as the completion is saved, see L</What a run leaves>.

The secret files of a claim are removed whatever became of it, also when its
completion could not be saved. C<once> croaks in that case, and for a claim
whose run is not a run number, which is refused before anything is written
and cannot be reported. It also croaks, with C<cannot remove secret files>
and the path, if the files are still there after it removed them.

A worker that is killed during a run removes nothing. Its secret files are
removed by the next C<once> on the same store, see
L</remove_orphaned_secrets>; the run itself keeps its lease at the dispatcher
until that expires.

=head2 What a run leaves

While a claim is executed, the store of the worker holds what a job printed
and wrote, and a secret value among it if a job printed one:

=over 4

=item *

C<public/runs/E<lt>runE<gt>.log>, the log as the jobs wrote it;

=item *

C<tmp/E<lt>runE<gt>/>, which the executor is given as C<RUNNER_TEMP>: the
output of every job once more, its output and artifact directories and the
event;

=item *

C<work/E<lt>runE<gt>/>, the checkout, and C<runs/E<lt>runE<gt>/>, the event
the run was started from.

=back

C<once> removes all of it when the run is over, whichever way it ended and
before it sends anything: the redacted log is in the completion by then, and
nothing else of a run is reported. Only C<public/runs/E<lt>runE<gt>.json>
stays, the report with the state, the exit code and the times of the run. No
log is kept for a completion that waits to be delivered or was put aside
under C<rejected/> either: both carry the redacted one.

A log that cannot be removed is an error like a secret file that cannot be:
C<once> croaks with C<cannot remove the log of a run> and the path, and the
next one asks for no work until it is gone. A directory that cannot be
removed, or not all of it, is not: a job may write files as another account
than the worker, which the worker cannot delete below a directory of that
account. C<once> removes what it can, warns once per process

  SimpiCI::Worker cannot remove run files: tmp/7

goes on, and tries again in every cycle. The log of the run and the output
the executor kept of each job are files of the worker and are removed in
any case; what stays is what the jobs themselves wrote there.

A worker that is killed during a run removes nothing of this. The next
C<once> on the same store does, see L</remove_orphaned_run_files>.

=head2 Ending during a run

C<once> holds back the signals of L<SimpiCI::Runner/stop_signals>, C<TERM>,
C<INT> and C<HUP>, from the claim until what the run left is removed. The
runner is told where to ask for them, see L<SimpiCI::Runner/stop_requested>,
and ends the run as soon as one arrived, with its process group and its
containers: during a command, between two commands, and before the first
one, which is then not started. See L<SimpiCI::Runner/Ending a run>. A
signal the process ignores, as C<HUP> under C<nohup>, is not held back and
ends nothing.

For a run that was ended in this way, C<once> saves the completion like that
of any other run, with the state C<signalled>, the exit code 128 plus the
signal and the redacted log, which ends with

  SimpiCI::Runner run N stopped by signal TERM

removes the secret files and the files of the run, and passes the signal on
with L<SimpiCI::Runner/end_by> instead of delivering the completion: the
process ends by it, and the next start delivers what was saved. C<once>
returns nothing if a handler of its caller kept the process alive. An error
of the removal is warned, not raised, on this way out.

A worker that is killed can do none of this. The runner starts a process
that ends the run for it and removes its containers; the secret files, the
log and the files of the run stay until the next C<once>.

=head1 METHODS

=head2 once

  my $response = $worker->once;

Returns the dispatcher's answer to the completion it delivered, or nothing if
there was no work or if it was told to end during the run, see
L</Ending during a run>. The answer is the report of the run, or
C<{ rejected =E<gt> REASON }> for a completion that was put aside, see
L</Delivering a completion>. Croaks if the dispatcher gave no answer; the
completion is then still saved. Before it asks the dispatcher for anything,
it calls L</remove_orphaned_containers>, L</remove_orphaned_secrets> and
L</remove_orphaned_run_files>, in this order: a container that is still
there writes what the other two remove. Each of them is called whatever
became of the one before, so that secret files and logs do not wait for a
docker that cannot be asked, and C<once> croaks afterwards with what they
could not remove. Before that it croaks if the store is not that of a
worker, see L</foreign_state>.

Only one C<once> may run on a store at a time. C<simpici-worker> holds a lock
on the store for that. The process that ends the run of a killed worker
holds the same lock until it is done, so no C<once> begins before that.

=head2 remove_orphaned_containers

  my $removed = $worker->remove_orphaned_containers;

Removes the containers of runs that were cut off, with
L<SimpiCI::Runner/remove_orphaned_containers> of the runner the worker was
given, and returns how many there were. Docker is asked only if a file below
C<containers/> in the store names such a run, and then for the containers
with the label of this store and no others. A count other than 0 is warned as

  SimpiCI::Worker removed orphaned containers: 2

Croaks with C<cannot remove orphaned containers> and the reason if docker
cannot be asked or a container is still there afterwards; C<once> then
removes the orphaned secret files and run files all the same, asks for no
work, and the file stays for the next attempt. It must not be called while a
claim is executed on the same store.

=head2 remove_orphaned_run_files

  my $removed = $worker->remove_orphaned_run_files;

Removes what runs left in the store and returns how many entries it removed:
every C<public/runs/*.log>, every entry of the directories
L</run_directories> names, and a completion that was still being written,
C<.completion.json.tmp.E<lt>pidE<gt>>. C<once> removes the files of its run
before it returns, so what is found was left by a worker that ended during a
run, or by a version that removed nothing: the first C<once> of this version
on an older store removes every log and checkout it finds there. Each entry
is warned as

  SimpiCI::Worker removed orphaned run files: work/7

A link is removed, not followed. The reports C<public/runs/*.json>, a
completion that waits and C<rejected/> are not touched. Croaks if a log
cannot be removed; an entry of a directory that cannot be removed is warned
once per process instead, as in L</What a run leaves>, and not counted. It
must not be called while a claim is executed on the same store, and the
store must be that of a worker alone. In the store of a dispatcher or of a
C<simpicid> it removes nothing and croaks, see L</foreign_state>; a root
that only C<simpici> made runs in is not recognised, and those runs would
lose their logs and checkouts.

=head2 foreign_state

Returns the entries a worker never has in its store and a dispatcher or a
polling daemon does: C<claims>, C<queue> and C<state>. In a root that has one
of them, the logs below C<public/runs> are the published ones and the
checkouts those of local runs. L</once> and L</remove_orphaned_run_files>
remove nothing there and croak with

  SimpiCI::Worker root is the state of a dispatcher or a daemon, it has queue/: ROOT

=head2 run_directories

Returns the directories below the store root that hold one entry per run and
are emptied: C<runs>, C<tmp> and C<work>.

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

=head2 abort_reasons

  my @reasons = SimpiCI::Worker->abort_reasons;

Lists every reason the log gives for a claim that was not executed to its
end. They are fixed phrases, a few lowercase words each, because the
dispatcher publishes the log it receives:

=over 4

=item C<invalid event in claim>

The event of the claim is no object with the fields of an event, or
L<SimpiCI::Event> refuses it for its commit, its ref, its clone URL, its
repository, its event name or its source. Standard error has the rule it
broke. The
dispatcher enqueues only what the same class accepts, so this is a queue
entry written by hand or by another version.

=item C<invalid secrets in claim>

The secrets of the claim are not an object of phases, each with an object of
names and values.

=item C<invalid secret name in claim>

=item C<invalid secret value in claim>

A secret is not one C<NAME=VALUE> line, see L</Secrets of a claim>.

=item C<invalid timeout in claim>

The timeout of the claim is no integer. The dispatcher sends the C<timeout>
of its configuration as it stands there.

=item C<cannot write secret files>

C<secrets/E<lt>runE<gt>/> or one of its two files could not be written.

=item C<cannot create temporary directory>

C<tmp/E<lt>runE<gt>/> could not be created.

=item C<run supervisor failed>

L<SimpiCI::Runner> croaked: it could not write a report, the checkout
directory or another file below the store root, could not start a process,
could not read how a command ended, or could not report a run that was
stopped. The log has what the run wrote up to then.

=item C<internal error>

Everything else, and so every error nobody foresaw.

=back

The first five are checked before a secret file is written, and nothing is
executed for them. Standard error has the file, the rule or the message
behind each of the others, see L</What is written to standard error>.

=head2 abort_reason

  my $published = $worker->abort_reason($reason);

Returns the reason as the log gets it: itself if it is one of
L</abort_reasons>, and C<internal error> for anything else, also for a
reason that is undefined or no string. Nothing else decides what the log
says of an aborted claim.

=head2 aborted_exit_code

Returns 125, the exit code reported for a claim that was not executed to its
end.

=cut
