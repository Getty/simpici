package SimpiCI::Runner;

use Moo;

# ABSTRACT: Exact-checkout SimpiCI run supervisor

use SimpiCI::Store;
use Carp qw( croak );
use File::Which qw( which );
use IO::Select;
use Path::Tiny qw( path );
use POSIX qw( WNOHANG setpgid strftime );
use Time::HiRes qw( sleep time );
use Types::Standard qw( CodeRef Int InstanceOf );
use namespace::autoclean;

has store => (
  is       => 'ro',
  isa      => InstanceOf['SimpiCI::Store'],
  required => 1,
);

has timeout => (
  is      => 'ro',
  isa     => Int,
  default => sub { 3600 },
);

has runner_script => (
  is      => 'lazy',
  isa     => InstanceOf['Path::Tiny'],
  coerce  => 1
);

# Asked instead of a signal: a caller that holds the signals which end it
# back itself, because it has more to finish than the run, says here which
# one it received.
has stop_requested => (
  is        => 'ro',
  isa       => CodeRef,
  predicate => 1,
);

# The signal the runner itself took while it made a run. Written by its
# handler, and so not read-only.
has _stopped_by => (
  is       => 'rw',
  init_arg => undef,
);

sub _build_runner_script {
  my ( $self ) = @_;

  my $repository_executor = path('bin/simpici-executor')->absolute;
  return $repository_executor if -x $repository_executor;
  my $installed_executor = which('simpici-executor');
  croak __PACKAGE__.' cannot find simpici-executor' unless $installed_executor;
  return path($installed_executor);
}

# The signals that end a supervisor in an orderly way. While a command of a
# run is executed, each of them ends the run first.
sub stop_signals { qw( TERM INT HUP ) }

# Those of them the process does not ignore. What its caller chose to
# ignore, as under nohup, ends no run either.
sub stop_signals_in_effect {
  my ( $self ) = @_;
  return grep { ( $SIG{$_} // '' ) ne 'IGNORE' } $self->stop_signals;
}

# How long a process group that was told to end has before it is killed: the
# time the executor has to remove the containers it started.
sub termination_grace { 5 }

# How long one docker command of the supervisor itself may take.
sub docker_timeout { 30 }

sub run {
  my ( $self, $event, $assigned_run ) = @_;

  croak __PACKAGE__.' invalid assigned run'
    if defined $assigned_run && $assigned_run !~ /\A[1-9][0-9]*\z/;
  $self->_stopped_by(undef);
  my ( $report, $failure ) = $self->has_stop_requested
    ? $self->_run($event, $assigned_run)
    : $self->_run_holding_signals($event, $assigned_run);
  # Passed on once the run is ended and reported, and with the handlers of
  # the caller in place again: the signal ends this process as it would have
  # without a run, unless the caller has something to finish first.
  $self->end_by($self->_stopped_by) if defined $self->_stopped_by;
  croak $failure if defined $failure;
  return $report;
}

# The signals are taken for the whole run, not only while a command is
# waited for: one that arrives between two commands ends the run as well.
sub _run_holding_signals {
  my ( $self, @arguments ) = @_;

  my @signals = $self->stop_signals_in_effect;
  local @SIG{@signals}
    = ( sub { $self->_stopped_by($_[0]) unless defined $self->_stopped_by } ) x @signals;
  return $self->_run(@arguments);
}

# The signal that ends the run, whoever received it.
sub _stop_signal {
  my ( $self ) = @_;
  return $self->has_stop_requested ? $self->stop_requested->() : $self->_stopped_by;
}

# Returns the report, and what could not be written of a run that was
# stopped: that is no reason not to pass the signal on.
sub _run {
  my ( $self, $event, $assigned_run ) = @_;

  $self->store->prepare;
  my $run = $assigned_run // $self->store->allocate_run;
  my $state_root = $self->store->root->absolute;
  my $workspace = $state_root->child('work', $run);
  my $log = $state_root->child('public', 'runs', $run.'.log');
  my $started = time;
  my $report = {
    run        => $run,
    state      => 'running',
    started_at => $self->_timestamp($started),
    log        => '/runs/'.$run.'.log',
    $event->as_hash->%*
  };
  delete $report->{payload};
  delete $report->{clone_url};
  $self->_publish($report);

  $workspace->mkpath;
  my $git = sub {
    my ( $timeout, @arguments ) = @_;
    return $self->_execute(log => $log, timeout => $timeout, name => 'git',
      command => [ 'git', @arguments ]);
  };
  # Quietly: git would say where it made the repository, and the log of a
  # run is published.
  my $result = $git->(120, 'init', '--quiet', $workspace->stringify);
  # The event accepts a clone URL that begins with "-"; its commit, being an
  # object id, cannot.
  $result = $git->(120, '-C', $workspace->stringify,
    'remote', 'add', '--', 'origin', $event->clone_url) if $result->{exit_code} == 0;
  $result = $git->(300, '-C', $workspace->stringify,
    'fetch', '--depth=1', 'origin', $event->commit) if $result->{exit_code} == 0;
  $result = $git->(120, '-C', $workspace->stringify,
    'checkout', '--detach', $event->commit) if $result->{exit_code} == 0;

  if ($result->{exit_code} == 0) {
    my $event_file = $self->store->write_json('runs/'.$run.'/event.json',
      $event->as_hash);
    my %environment = (
      CICD_RUN_NUMBER => $run,
      CICD_SOURCE     => $event->source,
      CICD_EVENT      => $event->event,
      CICD_REPOSITORY => $event->repository,
      CICD_CLONE_URL  => $event->clone_url,
      CICD_REF        => $event->ref,
      CICD_COMMIT     => $event->commit,
      CICD_WORKSPACE  => $workspace->stringify,
      CICD_EVENT_FILE => $event_file->stringify,
      CICD_ROOT       => $workspace->child('.cicd')->stringify,
      GITHUB_WORKSPACE => $workspace->stringify,
      SIMPICI_INSTANCE => $self->store->instance
    );
    # Written before the executor starts and removed once none of its
    # containers can be left: while it is there, some may be.
    my $containers = $self->_containers_file($run);
    $containers->parent->mkpath;
    $containers->spew_utf8($self->container_label($run)."\n");
    $result = $self->_execute(log => $log, timeout => $self->timeout, run => $run,
      environment => { %ENV, %environment }, directory => $workspace->stringify,
      name => 'the executor', command => [ $self->runner_script->stringify ]);
    $self->_settle_containers($run, $result);
  }
  my $finished = time;
  $report->{state} = $result->{timed_out} ? 'timed_out'
    : $result->{signal} ? 'signalled'
    : $result->{exit_code} == 0 ? 'success'
    : $result->{exit_code} == 78 ? 'skipped' : 'failed';
  $report->{exit_code} = $result->{exit_code};
  $report->{signal} = $result->{signal} if $result->{signal};
  $report->{finished_at} = $self->_timestamp($finished);
  $report->{duration_seconds} = int($finished - $started);
  my $stopped = $result->{stopped};
  unless (defined $stopped) {
    $self->_publish($report);
    return { $report->%* };
  }
  my $reason = __PACKAGE__.' run '.$run.' stopped by signal '.$stopped."\n";
  warn $reason;
  my $failure;
  eval { $log->append_utf8($reason); $self->_publish($report); 1 }
    or $failure = __PACKAGE__.' cannot report run '.$run.': '.$self->_reason($@);
  warn $failure."\n" if defined $failure;
  return ( { $report->%* }, $failure );
}

sub end_by {
  my ( $self, $signal ) = @_;

  croak __PACKAGE__.' invalid signal' unless grep { $_ eq ( $signal // '' ) } $self->stop_signals;
  kill $signal, $$;
  # Still here. With a handler in place, the caller decides what follows.
  # Without one the signal was spared this process, as the first process of
  # a container is spared its own: it ends all the same, with the exit code
  # a shell gives the signal.
  my $handler = $SIG{$signal};
  return if ref $handler || ( defined $handler && length $handler && $handler ne 'DEFAULT' );
  exit 128 + $self->_signal_number($signal);
}

sub _signal_number {
  my ( $self, $signal ) = @_;
  return POSIX->can('SIG'.$signal)->();
}

sub _publish {
  my ( $self, $report ) = @_;

  $self->store->write_json('public/runs/'.$report->{run}.'.json', $report);
  $self->store->write_json('public/runs/index.json', {
    latest => $report->{run},
    runs   => [ $report->{run} ]
  });
}

sub _execute {
  my ( $self, %arg ) = @_;

  my @command = $arg{command}->@*;
  # A run that was told to end starts no further command.
  my $stop = $self->_stop_signal;
  return $self->_stopped($stop) if defined $stop;
  # The writing end of the first pipe is held by this process alone. Its end
  # closes the pipe, whatever ended it, and that is how the watcher in the
  # group of the command learns of it. The second pipe holds the command
  # back until the watcher is there.
  pipe(my $watched, my $alive) or croak __PACKAGE__.'->_execute cannot create a pipe: '.$!;
  pipe(my $gate, my $go) or croak __PACKAGE__.'->_execute cannot create a pipe: '.$!;
  my $pid = fork;
  croak __PACKAGE__.'->_execute cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    # Not the handlers of the supervisor: a signal for the group that
    # arrives before the command is one must end this process, not be noted.
    $SIG{$_} = 'DEFAULT' for grep { ref $SIG{$_} } $self->stop_signals;
    setpgid(0, 0);
    close $_ for $watched, $alive, $go;
    # Without a supervisor to say so, the command is not started at all.
    my ( $read, $byte );
    do { $read = sysread $gate, $byte, 1 } while !defined $read && $!{EINTR};
    POSIX::_exit(126) unless $read;
    close $gate;
    chdir $arg{directory} if defined $arg{directory};
    %ENV = $arg{environment}->%* if defined $arg{environment};
    # Kept for a command that cannot be started, if there is one to keep. A
    # command that can be started closes it: Perl opens it to be closed on
    # exec.
    my $operator;
    open $operator, '>&', \*STDERR or undef $operator;
    open STDOUT, '>>', $arg{log} or POSIX::_exit(126);
    open STDERR, '>&', STDOUT or POSIX::_exit(126);
    # Not the warning of Perl, which would go to the log and name the
    # command and this file: the log is published and gets what was to be
    # started, standard error of the supervisor gets the command.
    { no warnings 'exec'; exec { $command[0] } @command; }
    my $reason = $!;
    syswrite STDERR, __PACKAGE__.' cannot start '.( $arg{name} // 'a command' ).': '.$reason."\n";
    syswrite $operator, __PACKAGE__.' cannot start '.$command[0].': '.$reason."\n" if $operator;
    POSIX::_exit(126);
  }
  # From this side as well: the watcher joins the group, and a signal for
  # the group must not arrive before there is one.
  setpgid($pid, $pid);
  my $watcher = fork;
  unless (defined $watcher) {
    my $reason = $!;
    kill 'KILL', $pid;
    waitpid($pid, 0);
    croak __PACKAGE__.'->_execute cannot fork: '.$reason;
  }
  $self->_watch_supervisor($watched, $pid, $arg{run}, $alive, $gate, $go) unless $watcher;
  close $_ for $watched, $gate;
  local $SIG{PIPE} = 'IGNORE';
  syswrite $go, '.';
  close $go;
  my $deadline = time + $arg{timeout};
  my ( $waited, $ended_for );
  while (($waited = waitpid($pid, WNOHANG)) == 0) {
    $stop = $self->_stop_signal;
    if (defined $stop || time >= $deadline) {
      $ended_for = $stop // 'timeout';
      $self->_terminate($pid);
      last;
    }
    sleep 0.05;
  }
  my $status = $?;
  # The command is over. Said to the watcher, which would take a pipe that
  # only closes for the end of the supervisor; it may be gone already. It
  # is a child of this process and is waited for like the command.
  syswrite $alive, '.';
  close $alive;
  waitpid($watcher, 0);
  # Whatever the command left running in its group does not outlive it.
  kill 'KILL', -$pid;
  return { exit_code => 124, timed_out => 1 } if ( $ended_for // '' ) eq 'timeout';
  return $self->_stopped($ended_for) if defined $ended_for;
  # No status at all, as under an ignored SIGCHLD: how the command ended is
  # not known, and what is not known is not a result.
  croak __PACKAGE__.'->_execute lost '.$command[0].': '.$! if $waited < 0;
  # A command that a signal ended has no exit code, and the 0 in its place
  # would read as success. It gets the one a shell reports for it.
  my $signal = $status & 127;
  return { exit_code => $signal ? 128 + $signal : $status >> 8, signal => $signal };
}

# The result of a command that was ended, or not started, because the
# supervisor was told to end.
sub _stopped {
  my ( $self, $signal ) = @_;
  my $number = $self->_signal_number($signal);
  return { exit_code => 128 + $number, signal => $number, stopped => $signal };
}

# TERM for the whole group, so that the executor can remove the containers
# it started, then KILL for whatever of the group is left by then: a command
# that did not end, what it left running, and the watcher.
sub _terminate {
  my ( $self, $pid ) = @_;

  kill 'TERM', -$pid;
  my $deadline = time + $self->termination_grace;
  my $reaped;
  until ($reaped = waitpid($pid, WNOHANG)) {
    last if time >= $deadline;
    sleep 0.05;
  }
  kill 'KILL', -$pid;
  waitpid($pid, 0) unless $reaped;
  return;
}

# Never returns: this is the watcher, a child of the supervisor in the
# group of the command. It waits for the supervisor to end. A supervisor
# that is killed cannot end the command, and a command in a group of its
# own does not end because its supervisor did: the watcher then does what
# the supervisor would have done.
sub _watch_supervisor {
  my ( $self, $watched, $leader, $run, @others ) = @_;

  $SIG{$_} = 'IGNORE' for $self->stop_signals;
  # Its own copy of the writing end would keep the pipe open for ever.
  close $_ for @others;
  setpgid(0, $leader);
  my ( $read, $byte );
  do { $read = sysread $watched, $byte, 1 } while !defined $read && $!{EINTR};
  # A byte says that the command is over, the end of the pipe that the
  # supervisor is.
  POSIX::_exit(0) if $read;
  kill 'TERM', -$leader;
  my $deadline = time + $self->termination_grace;
  sleep 0.05 while kill(0, $leader) && time < $deadline;
  # The watcher leaves the group before it kills the rest of it: the
  # containers are removed once nothing is left that starts another.
  setpgid(0, 0);
  kill 'KILL', -$leader;
  POSIX::_exit(0) unless defined $run;
  eval {
    $self->remove_containers($run);
    $self->_containers_file($run)->remove;
    1;
  } or print STDERR __PACKAGE__.' cannot remove the containers of run '.$run.': '
    .$self->_reason($@)."\n";
  POSIX::_exit(0);
}

sub _containers_file {
  my ( $self, $run ) = @_;
  return $self->store->root->absolute->child('containers', $run);
}

# Only an executor that ended with 0 has seen every job it started end. One
# that was ended, or gave up, may have left containers it did not get to.
sub _settle_containers {
  my ( $self, $run, $result ) = @_;

  if ($result->{timed_out} || $result->{signal} || $result->{exit_code} != 0) {
    my $removed;
    unless (eval { $removed = $self->remove_containers($run); 1 }) {
      warn __PACKAGE__.' cannot remove the containers of run '.$run.': '.$self->_reason($@)."\n";
      return;
    }
    warn __PACKAGE__.' removed containers of run '.$run.': '.$removed."\n" if $removed;
  }
  $self->_containers_file($run)->remove;
  return;
}

# What an error says, without where it was raised.
sub _reason {
  my ( $self, $error ) = @_;
  my $reason = (split /\n/, $error // '')[0] // 'unknown error';
  $reason =~ s/\A(.*) at .+? line \d+\.?\z/$1/;
  return $reason;
}

sub container_label {
  my ( $self, $run ) = @_;

  return 'simpici.instance='.$self->store->instance unless defined $run;
  croak __PACKAGE__.' invalid run' unless $run =~ /\A[1-9][0-9]*\z/;
  return 'simpici.run='.$self->store->instance.'.'.$run;
}

sub remove_containers {
  my ( $self, $run ) = @_;

  my $label = $self->container_label($run);
  # The executor finds docker in the same way: where there is none, it
  # started no container.
  return 0 unless which('docker');
  my @containers = $self->_containers($label);
  return 0 unless @containers;
  # Killed first: not every daemon kills at once what it is told to remove,
  # and a job has no claim to the seconds it would be given to stop. How
  # the two commands ended is not asked, and what they say is not passed on:
  # a container that ended by itself in between is no error. What counts is
  # what is left.
  $self->_docker_quietly('kill', @containers);
  $self->_docker_quietly('rm', '-f', @containers);
  # A daemon that removes a killed container by itself may list it a moment
  # longer and refuse to remove it twice.
  my $deadline = time + $self->termination_grace;
  my @left;
  while (@left = $self->_containers($label)) {
    last if time >= $deadline;
    sleep 0.2;
  }
  croak __PACKAGE__.' containers left with the label '.$label.': '.scalar @left if @left;
  return scalar @containers;
}

# A file below containers/ names a run whose containers nobody removed: its
# supervisor ended with all of its group, or docker could not be asked.
sub remove_orphaned_containers {
  my ( $self ) = @_;

  my $directory = $self->store->root->absolute->child('containers');
  return 0 unless $directory->is_dir;
  my @files = $directory->children or return 0;
  my $removed = $self->remove_containers;
  $_->remove for @files;
  return $removed;
}

# Only ever with a label of this store, and only what looks like the id of
# a container: nothing else is passed on to docker rm.
sub _containers {
  my ( $self, $label ) = @_;

  # A filter without a value would name the containers of every store.
  croak __PACKAGE__.' cannot list containers: invalid label'
    unless $label =~ /\Asimpici\.(?:instance|run)=[0-9a-f]{32}(?:\.[1-9][0-9]*)?\z/;
  my $answer = $self->_docker('ps', '-aq', '--no-trunc', '--filter', 'label='.$label);
  croak __PACKAGE__.' cannot list containers: docker ps '.$answer->{error}
    if defined $answer->{error};
  my @containers = split /\n/, $answer->{output};
  croak __PACKAGE__.' cannot list containers: unexpected answer of docker ps'
    if grep { !/\A[0-9a-f]{12,64}\z/ } @containers;
  return @containers;
}

sub _docker_quietly {
  my ( $self, @arguments ) = @_;
  return $self->_docker(@arguments, { quiet => 1 });
}

sub _docker {
  my ( $self, @arguments ) = @_;

  my $option = ref $arguments[-1] eq 'HASH' ? pop @arguments : {};
  pipe(my $reader, my $writer) or croak __PACKAGE__.' cannot create a pipe: '.$!;
  my $pid = fork;
  croak __PACKAGE__.' cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    setpgid(0, 0);
    open STDIN, '<', '/dev/null' or POSIX::_exit(126);
    open STDOUT, '>&', $writer or POSIX::_exit(126);
    if ($option->{quiet}) { open STDERR, '>', '/dev/null' or POSIX::_exit(126) }
    { no warnings 'exec'; exec { 'docker' } 'docker', @arguments; }
    POSIX::_exit(127);
  }
  close $writer;
  my $limit = $self->docker_timeout;
  my $deadline = time + $limit;
  my $open = IO::Select->new($reader);
  my $output = '';
  my $drain = sub {
    my ( $wait ) = @_;
    return 0 unless $open->count && $open->can_read($wait);
    my $read = sysread $reader, $output, 65536, length $output;
    $open->remove($reader) unless $read || ( !defined $read && $!{EINTR} );
    return 1;
  };
  my $waited;
  until ($waited = waitpid($pid, WNOHANG)) {
    if (time >= $deadline) {
      kill 'KILL', -$pid;
      waitpid($pid, 0);
      return { output => $output, error => 'not over within '.$limit.' s' };
    }
    $drain->(0.05) or $open->count or sleep 0.05;
  }
  my $status = $?;
  1 while $drain->(0);
  return { output => $output, error => 'ended in a way that cannot be read' } if $waited < 0;
  return { output => $output, error => 'ended by signal '.( $status & 127 ) } if $status & 127;
  return { output => $output, error => 'ended with '.( $status >> 8 ) } if $status >> 8;
  return { output => $output };
}

sub _timestamp {
  my ( $self, $epoch ) = @_;
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch));
}

1;

=head1 NAME

SimpiCI::Runner - exact-checkout SimpiCI run supervisor

=head1 SYNOPSIS

  use Path::Tiny qw( path );

  my $runner = SimpiCI::Runner->new(
    store         => $store,
    timeout       => 3600,
    runner_script => path('/opt/simpici/bin/simpici-executor')
  );
  my $report = $runner->run($event);

=head1 DESCRIPTION

Makes one run: an exact detached checkout, then the shared executor, with a
published report at the beginning and at the end. Whatever ends a run before
its executor is over also ends the process group of the executor and
removes the containers it started; that is what L</Ending a run> and
L</Containers of a run> describe. The methods follow them.

=head2 The log of a run

C<public/runs/E<lt>runE<gt>.log> below the store root is what the commands
of a run printed, standard output and standard error together and
unfiltered. It is published: by a local C<simpicid> as it stands, by a
worker through its dispatcher. The runner adds two lines of its own to it,
that a run was stopped and that a command could not be started, see L</run>
and L</Ending a run>. Neither names the store root, a file of the
installation or a line of one, and the checkout is initialised quietly for
the same reason: git would say where it made the repository.

What git and the executor print otherwise is not looked at. git names the
clone URL of the event when it fetches, and an error of a tool or of a job
may name a path of the host.

=head2 Ending a run

Each command of a run is started in a process group of its own. Once a
command is over, whatever it left running in that group is killed. A run is
ended before its command is over in three cases, and in each of them the
group is sent C<TERM>, has L</termination_grace> seconds to end, and is sent
C<KILL> with whatever of it is left by then. The executor answers C<TERM> by
killing and removing the containers it started; the grace is the time it has
for that.

=over 4

=item *

The command is not over within its limit.

=item *

The process that called C<run> receives one of L</stop_signals>. C<run>
takes these signals for as long as it lasts, between two commands as well
as during one. The command that is executed is ended and no further one is
started, a line

  SimpiCI::Runner run N stopped by signal TERM

is appended to the log of the run and warned, the report is published as
C<signalled>, and then the signal is passed on with L</end_by>, now with
whatever the caller had in place for it. Without a handler of the caller
that ends the process as the signal would have without a run. The signal is
passed on also if the line or the report could not be written; that is
warned as C<cannot report run N> with the reason, and croaked for a caller
that is still there. A run whose last command ended by itself before the
signal was noticed keeps its result, and the signal is passed on after it.

A signal the process ignores when C<run> is called, as C<HUP> under
C<nohup>, is left ignored and ends nothing, see L</stop_signals_in_effect>.

A caller that has more to finish than the run holds the signals back itself
and tells the runner where to ask, see L</stop_requested>: C<run> then takes
no signal and passes none on, and ends the run as soon as the caller says
that one arrived. L<SimpiCI::Worker> does that.

=item *

The process that called C<run> ends without having ended the command, as
when it is killed with C<KILL>. For every command, C<run> starts a second
process in the group of the command, which waits for exactly that and then
ends the group in the same way and removes the containers of the run. The
command is not started before that process is there. It holds what the
supervisor had open, a lock on the store included, until it is done. Nobody
is left to publish a result: the report stays at C<running>. If that
process is killed as well, as when a service manager kills everything of a
unit at once, the containers stay until L</remove_orphaned_containers> is
called.

=back

Nothing of this reaches a process that left the group of its command, or a
container that a job itself started through a Docker socket it was given.

=head2 Containers of a run

The executor is told the L<SimpiCI::Store/instance> of the store as
C<SIMPICI_INSTANCE> and labels every container it starts with
C<simpici.instance=INSTANCE> and C<simpici.run=INSTANCE.RUN>. While the
executor of a run is executed, the file C<containers/E<lt>runE<gt>> below
the store root holds the second of these labels.

An executor that ends with 0 has seen every job it started end, and the
file is removed with no question asked of docker. For every other end, an
exit code but 0 as well as a signal, the limit and a stop, the executor may
have given up with jobs still running, and L</remove_containers> is called
for the run. What it removed is warned as

  SimpiCI::Runner removed containers of run N: COUNT

and the file is removed. If it fails, the result of the run stands, the
reason is warned as

  SimpiCI::Runner cannot remove the containers of run N: REASON

and the file stays: it names a run whose containers may still be there.
C<run> never looks for the files of other runs; L<SimpiCI::Worker> does
before each claim.

=head1 ATTRIBUTES

=head2 store

The L<SimpiCI::Store> of the runs. Required.

=head2 timeout

The seconds the executor of a run may take. Defaults to 3600.

=head2 runner_script

The executor. Defaults to C<bin/simpici-executor> below the current
directory, or else to the C<simpici-executor> found in C<PATH>.

=head2 stop_requested

  my $stopped;
  local $SIG{TERM} = sub { $stopped //= $_[0] };
  my $runner = SimpiCI::Runner->new(store => $store, stop_requested => sub { $stopped });

A code reference that returns one of L</stop_signals> once the caller
received it, and nothing before. With it, C<run> installs no handlers of its
own, asks before each command and about every 50 milliseconds during one,
ends the run when it gets a signal and leaves ending the process to the
caller. For a caller that holds the signals back because it has more to put
away than the run.

=head1 METHODS

=head2 run

Allocates a run, checks out the event's exact commit detached, invokes the
shared container executor, writes public report JSON excluding C<payload> and
C<clone_url>, captures unfiltered logs, and returns a report hash.

The checkout is four git commands: C<init>, C<remote add>, C<fetch> and
C<checkout>. Each starts only after the one before it exited with 0, and the
executor only after all four did. The first command that ends in another way
ends the run, and how it ended is the result of the run:

=over 4

=item *

An exit code is the C<exit_code> of the report. From the executor, 0 is the
state C<success> and 78 is C<skipped>; every other exit code, and every exit
code but 0 of a git command, is C<failed>.

=item *

A command that cannot be started, because there is no C<git> in C<PATH> or
the executor is no file that can be executed, counts as one that exited
with 126, and so as C<failed>. The log gets one line for it, with the reason
the system gave,

  SimpiCI::Runner cannot start the executor: No such file or directory

or C<cannot start git>. Standard error of the supervisor gets the same line
with the path of the command in the place of C<the executor>, which the log
does not name.

=item *

A command that a signal ended is the state C<signalled>, with the number of
the signal as C<signal> and 128 plus that number as C<exit_code>, which is
what a shell reports for it. It never counts as an exit code of 0.

=item *

A command that is not over within its limit is ended with its process group
and is the state C<timed_out> with C<exit_code> 124. The limit is C<timeout>
for the executor, 300 seconds for C<fetch> and 120 for the other git
commands.

=item *

A command that is ended, or not started any more, because the supervisor
was told to end, see L</Ending a run>, is the state C<signalled> with the
signal the supervisor received: C<signal> 15 and C<exit_code> 143 for
C<TERM>.

=back

Croaks with C<lost> and the command if the way a command ended cannot be
read, as in a process that ignores C<SIGCHLD>: the report then stays at
C<running>, because there is no result to publish.

=head2 container_label

  my $label = $runner->container_label($run);
  my $label = $runner->container_label;

Returns the label of the containers of a run, C<simpici.run=INSTANCE.RUN>,
or without a run the label of every container of this store,
C<simpici.instance=INSTANCE>. Croaks with C<invalid run> for what is no run
number.

=head2 remove_containers

  my $removed = $runner->remove_containers($run);
  my $removed = $runner->remove_containers;

Removes the containers that carry L</container_label>, those of one run or
without a run those of every run of this store, with C<docker kill> and
C<docker rm -f>, and returns how many there were. It asks C<docker ps> for
the containers with exactly that label, passes on only what looks like the
id of a container, and asks again afterwards. Containers without the label,
and so those of another store on the same daemon, are never named to
C<docker kill> or C<docker rm>. They are killed before they are removed
because not every daemon kills at once what it is told to remove: Podman
gives a container ten seconds to stop first.

Croaks with C<cannot list containers> and the reason if C<docker ps> fails,
is not over within L</docker_timeout> seconds or answers anything but ids,
and with C<containers left with the label> if some are still listed
L</termination_grace> seconds after they were removed: a daemon that removes
a killed container by itself may list it a moment longer. Returns 0 without
asking if there is no C<docker> in C<PATH>: the executor finds it in the
same way and then started none.

Without a run it must not be called while a run is executed on the store.

=head2 remove_orphaned_containers

  my $removed = $runner->remove_orphaned_containers;

Removes the containers of every run of this store with L</remove_containers>
if a file below C<containers/> names a run whose containers nobody removed,
and then removes the files. Returns how many containers there were, and 0
without asking docker if there is no such file. Croaks as
L</remove_containers> does, and the files stay then.

It must not be called while a run is executed on the store, and so only by
a caller that is the only one to run on it, as C<simpici-worker> is by its
lock. C<run> does not call it: C<simpici> and C<simpicid> take no such lock,
and the containers of another run of theirs on the same store would be
removed with the orphaned ones.

=head2 end_by

  $runner->end_by('TERM');

Sends this process one of L</stop_signals>, as C<run> does for a signal it
took during a run. With no handler in place that ends the process. With
one, the handler runs and C<end_by> returns. A process the signal has no
effect on
although nothing handles it, as the first process of a container, is ended
with the exit code 128 plus the signal. Croaks with C<invalid signal> for
any other signal.

=head2 stop_signals

Returns the signals that end a run when the supervisor receives them:
C<TERM>, C<INT> and C<HUP>.

=head2 stop_signals_in_effect

Returns those of L</stop_signals> that the process does not ignore at the
moment. A signal its caller chose to ignore, as C<HUP> under C<nohup>, gets
no handler and ends no run.

=head2 termination_grace

Returns 5, the seconds a process group has to end after C<TERM> before it is
sent C<KILL>. An executor that is ended needs them to kill and remove the
containers it started; what it does not get to, L</remove_containers> does.

=head2 docker_timeout

Returns 30, the seconds one C<docker> command of L</remove_containers> may
take.

=cut
