package SimpiCI::App::Eventd;

use strict;
use warnings;

# ABSTRACT: Implementation of the simpicid polling daemon

use Carp qw( croak );
use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Pod::Usage qw( pod2usage );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Queue;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;

sub dispatcher_class { 'SimpiCI::Dispatcher' }

sub event_class { 'SimpiCI::Event' }

sub run {
  my ( $class, @arguments ) = @_;

  my ($config_path, $once, $runner_script, $help, $man);
  GetOptionsFromArray(
    \@arguments,
    'config=s' => \$config_path,
    'once'     => \$once,
    'runner=s' => \$runner_script,
    'help|h'   => \$help,
    'man'      => \$man
  ) or pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1);
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 1) if $help;
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 2) if $man;
  pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1,
    -message => 'A configuration file is required.') unless $config_path;

  umask 0077;
  my $config = JSON::MaybeXS->new->decode(path($config_path)->slurp_utf8);
  # In either mode and before anything is polled: an entry of the wrong
  # shape or a refused URL would show too, but with the daemon long running.
  $class->check_repositories($config);
  my $store = $class->store($config);
  my $configured_runner = $runner_script // $config->{runner};
  my $runner = SimpiCI::Runner->new(
    store   => $store,
    timeout => $config->{timeout} // 3600,
    $configured_runner ? (runner_script => path($configured_runner)) : ()
  );

  my $dispatcher;
  if (($config->{mode} // 'local') eq 'dispatcher') {
    $runner = SimpiCI::Queue->new(store => $store);
    # Do not poll for a configuration that no claim could be served from.
    $dispatcher = $class->dispatcher_class->new(queue => $runner, config => $config)->validate;
  }

  my $status = 0;
  while (1) {
    # First, so that no repository that hangs or cannot be read keeps it
    # back: a lease that ran out is seen in the next cycle, with or without
    # a worker that asks. It is the step every request of a worker takes.
    if ($dispatcher) {
      warn $class->interrupted_message($_) for $dispatcher->expire_leases;
    }
    for my $repository ($config->{repositories}->@*) {
      my $poller = SimpiCI::Source::GitPoll->new(
        store      => $store,
        runner     => $runner,
        repository => $repository,
        defined $config->{ls_remote_timeout}
          ? ( ls_remote_timeout => $config->{ls_remote_timeout} ) : ()
      );
      # Only the observation is survivable: a remote that is unreadable, has
      # no refs or shows none of those its last poll saw changes no state,
      # and the next cycle reads it again. Both of its queries are made in
      # observe, for that reason. A failing run or queue still ends the
      # daemon, and so do recorded tips that cannot be read: the rejection
      # is asked for outside the eval.
      my $observed = eval { $poller->observe };
      my $unpolled = $observed ? $poller->rejection($observed) : $@;
      if (defined $unpolled) {
        warn $class->unread_message($repository, $unpolled);
        $status = 1;
        next;
      }
      $poller->poll($observed);
    }
    last if $once;
    sleep($config->{interval} // 60);
  }
  return $status;
}

sub store {
  my ( $class, $config ) = @_;

  return SimpiCI::Store->new(root => path($config->{root} // './var'));
}

sub check_repositories {
  my ( $class, $config ) = @_;

  # No message repeats what stands in an entry: in the wrong place that may
  # be a clone URL with its token.
  my $repositories = $config->{repositories};
  croak __PACKAGE__.' repositories must be a list' unless ref $repositories eq 'ARRAY';
  for my $index (0 .. $#$repositories) {
    my $repository = $repositories->[$index];
    croak __PACKAGE__.' repositories['.$index.'] must be an object'
      unless ref $repository eq 'HASH';
    my $name = $repository->{name};
    my $where = __PACKAGE__.' repository '.( defined $name && !ref $name ? $name : '?' )
      .' (repositories['.$index.']): ';
    croak $where.'repository needs name and clone_url'
      if grep { !defined || ref || !length } $repository->@{qw( name clone_url )};
    my $reason = $class->event_class->clone_url_rejection($repository->{clone_url}) // next;
    croak $where.$reason;
  }
  return;
}

sub interrupted_message {
  my ( $class, $report ) = @_;

  return 'simpicid: run '.$report->{run}.' interrupted: its lease expired without a completion'."\n";
}

sub unread_message {
  my ( $class, $repository, $reason ) = @_;

  # run refuses a clone URL with credentials before it polls, so it never
  # gets here with one; a direct caller is not held to that.
  my $configured = $repository->{clone_url} // '';
  my $clone_url = $class->event_class->clone_url_without_credentials($configured);
  $reason =~ s/\Q$configured\E/$clone_url/g if length $configured;
  $reason =~ s/\s+/ /g;
  $reason =~ s/ \z//;
  return 'simpicid: repository '.( $repository->{name} // '' ).' ('.$clone_url
    .') not polled: '.$reason."\n";
}

1;

=head1 NAME

SimpiCI::App::Eventd - implementation of the simpicid polling daemon

=head1 SYNOPSIS

  simpicid --config simpici.json
  simpicid --config simpici.json --once
  simpicid --config simpici.json --runner /opt/simpici/action/run.sh
  simpicid --help

=head1 DESCRIPTION

Polls configured Git refs and tracks their last observed tips. In local mode,
changed tips run exact revisions through the shared phased container executor.
Dispatcher mode enqueues events with durable repository/ref/commit
deduplication. In that mode the daemon checks every secret grant before it
polls and exits with a message naming the repository, the secret and the
reason if one is unusable; it therefore needs read access to the secret files.
Local mode does not evaluate grants.

In dispatcher mode every polling cycle begins with
L<SimpiCI::Dispatcher/expire_leases>, before the first repository is read:
a run whose lease ran out becomes C<interrupted>, and the secret snapshot of
its claim is removed. The daemon writes one line to standard error for each
run it interrupted:

  simpicid: run 7 interrupted: its lease expired without a completion

It is the step every request of a worker begins with. Taken here, it does
not wait for a worker: a run whose worker is gone, or whose claim never
reached a worker, is C<interrupted> within one C<interval> after its lease
ran out. A repository that cannot be read or that hangs does not hold it
back, because it comes first, and a cycle without any repository takes it
too. The line is written once, by the cycle that interrupted the run; a run
that a request of a worker interrupted first gets none. The exit status of
C<--once> is not changed by it. A failure of the step, a queue that cannot
be written or a snapshot that cannot be removed, ends the daemon like any
other failure of the queue; a run it had interrupted by then stays
interrupted, without the line. A daemon that is ended in the middle of the
step leaves nothing half done that its next cycle does not finish, see
L<SimpiCI::Queue/expire_leases>. Local mode has no queue and takes no such
step.

In either mode the daemon first looks at C<repositories>, see
L</check_repositories>, and exits before it polls if an entry cannot be used.
C<repositories> has to be a list of objects, each with a C<name> and a
C<clone_url> that are nonempty strings:

  SimpiCI::App::Eventd repositories must be a list
  SimpiCI::App::Eventd repositories[1] must be an object
  SimpiCI::App::Eventd repository owner/project (repositories[0]): repository needs name and clone_url

It then holds every C<clone_url> against
L<SimpiCI::Event/clone_url_rejection>:

  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git
  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must not contain a password; a user name alone is accepted, and SSH authenticates with a key of the account that runs git

A message names the repository, if it has a name, and its position in the
configuration, never the URL or what else stands in the entry. The credentials
of an C<https://user:token@...> URL belong in the Git configuration of the
account the daemon runs as, see C<gitcredentials(7)>; the password of an
C<ssh://user:password@...> URL is replaced by a key of that account. In
dispatcher mode the worker fetches the commit and needs its own.

A repository whose refs cannot be read does not end the daemon. It writes one
line to standard error and goes on with the next repository:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: ...

The line carries the text C<git ls-remote> printed and repeats in every cycle
until the repository is readable again. The recorded tips of that repository
stay as they are, so nothing is built merely because it is back; a repository
that was never read gets its first observation then, subject to
C<build_initial>.

A repository that answers without any ref, while configured refs are missed
that its last poll still saw, is treated the same way, with its own reason:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: remote returned no refs, configured refs seen at the last poll: 2

This is what a mirror gives that was set up again and is not synchronised
yet. The line is a signal and nothing more: the recorded tips would stay
without it, as those of any ref that disappears do, so refs that return where
they were build nothing. The number counts the refs that are missed, not the
recorded ones: a ref that was gone at the last poll already, or that C<refs>
no longer selects, is not among them, and an answer that misses none is
polled without a line. If the refs are gone for good, forget them with
C<simpici --forget>, see L<SimpiCI::App::Run>, or remove the repository from
the configuration.

Refs that disappear while others stay are not reported. Each keeps its last
tip in the state and starts no run; back on that commit it builds nothing, on
another commit it is built like a ref that moved. Only a ref that was never
recorded is new. The same holds for a ref that C<refs> no longer selects: its
tip stays, and when the filter is widened again, the ref is built if it has
moved since and not otherwise. The state therefore holds every ref that was
ever observed for the repository and drops none by itself, see
L<SimpiCI::Source::GitPoll/poll>. C<simpici --state> shows what is recorded
and which of it the last poll did not see, C<simpici --forget> takes one ref
out.

The state of a repository is written only when a poll changes it, and it is
locked from reading to writing, the runs of the poll included. A second
C<simpicid> on the same state root, a C<--once> beside the running daemon for
instance, therefore waits for a repository the first is polling, in local
mode until its build has ended, and then sees what the first recorded: no
tip is lost and no change is built twice. C<simpici --forget> waits in the
same way.

A repository that has no refs at all and nothing recorded is not polled
either:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: SimpiCI::Source::GitPoll repository has no refs yet at ...

This is a mirror before its first synchronisation, or a project nobody has
pushed to. It gets no baseline, so its refs are a first observation when they
arrive, subject to C<build_initial>; with an empty baseline each of them would
be built as new, an old tag with what its grants give. The daemon learns it
from a second C<git ls-remote> without the configured refs, which it runs
only for an empty answer of a repository without recorded state. The line
repeats until the repository has a ref or leaves the configuration; there is
no state to delete. A repository that has refs, but none of the configured
ones, is not reported: its empty answer is the baseline, and refs that appear
afterwards are built.

Only a repository without any ref is recognised. A mirror that is polled in
the middle of its first synchronisation gets a baseline of what is there, and
what arrives later is built as new: let it finish before the daemon polls it.

A repository that does not answer is given up after C<ls_remote_timeout>
seconds, a top-level setting of the configuration that defaults to 60. It is
then not polled in this cycle either, and the line names the limit:

  simpicid: repository owner/project (ssh://example/owner/project.git) not polled: ... git ls-remote timed out after 60 s

If set, it must be a positive integer; any other value ends the daemon before
the first repository is read. It limits the reading of each repository on its
own, a second query included, so a cycle can take that long for every
repository that hangs, and it is not the C<timeout> setting, which limits a
run. See
L<SimpiCI::Source::GitPoll/observe> for how the command is ended.

Nothing beyond the observation is covered: a run that cannot be
started, an unwritable queue or state root, an unusable entry of
C<repositories>, a refused clone URL and an unusable grant still end the
daemon.

In local mode, C<TERM>, C<INT> and C<HUP> during a run end the run before
they end the daemon: the process group of the executor is ended, the
containers of the run are removed, and the run is reported as C<signalled>
with the exit code 128 plus the signal. A daemon that is killed leaves a
process that ends the run in the same way, without a report. See
L<SimpiCI::Runner/Ending a run>. Between two runs, and in dispatcher mode,
the signals end the daemon at once.

The daemon does not look for containers at its start. If it is killed
together with everything it started, the containers of its run stay; the
file C<containers/E<lt>runE<gt>> below the state root names their label for
C<docker ps --filter label=...>. Logs and checkouts of local runs are kept
as they are and never removed.

=head1 METHODS

=head2 dispatcher_class

Class used in dispatcher mode to check the grants at the start and to end
the leases that ran out in every cycle.

=head2 event_class

Class whose clone URL rule L</check_repositories> applies and L</unread_message>
shows a clone URL by.

=head2 store

  my $store = SimpiCI::App::Eventd->store($config);

The L<SimpiCI::Store> of a decoded configuration: its C<root>, or F<./var>
without one. C<simpici> finds the recorded tips of the daemon by it.

=head2 check_repositories

  SimpiCI::App::Eventd->check_repositories($config);

Croaks for the first entry of C<repositories> in a decoded configuration that
the daemon could not poll or build an event from: C<repositories> is no list,
an entry is no object, its C<name> or C<clone_url> is missing, empty or no
string, or its C<clone_url> is refused by
L<SimpiCI::Event/clone_url_rejection>. The message gives the index of the
entry, its name if it has one and the reason, never the clone URL or any
other value of the entry: a URL with a token may stand in the place of the
object. L</run> calls it before it polls.

It is no validation of the whole configuration. C<refs>, C<build_initial>,
the top-level settings and everything else in an entry are not looked at and
show when they are used; the grants are checked by
L<SimpiCI::Dispatcher/validate>, which refuses the same mistakes in
C<repositories> with the same words when C<simpici-dispatch> reads the file.

=head2 run

  my $status = SimpiCI::App::Eventd->run(@arguments);

Runs the daemon with an explicit argument list and returns its process exit
status when C<--once> is used or the loop otherwise ends: 1 if a repository
was not polled, 0 otherwise.

=head2 interrupted_message

  warn SimpiCI::App::Eventd->interrupted_message($report);

Formats the single log line for a run that L</run> interrupted because its
lease ran out, from the report L<SimpiCI::Dispatcher/expire_leases> returned
for it. It names the run number and nothing else of the run.

=head2 unread_message

  warn SimpiCI::App::Eventd->unread_message($repository, $reason);

Formats the single log line for a repository that was not polled, be it that
its refs could not be read, that it has none yet or that
L<SimpiCI::Source::GitPoll/rejection> refused what was read. The clone URL is
shown as L<SimpiCI::Event/clone_url_without_credentials> gives it, also where
the reason repeats it, so the user part the clone URL rule refuses is left
out. L</run> refuses such a URL before it polls, so this only matters to a
direct caller.

=head1 OPTIONS

=over 4

=item B<--config> I<file>

Required JSON configuration. See C<etc/simpici.example.json>.

=item B<--once>

Poll every configured repository once and exit instead of sleeping. A normally
completed poll returns zero even if a local build failed; inspect the run
reports for build status. The exit status is 1 if the refs of a repository
could not be read, be it that the query failed or that it ran into
C<ls_remote_timeout>, if it returned none while configured refs of its last
poll are missed, or if it has none at all and nothing is recorded; the other
repositories are polled all the same. In dispatcher mode the leases that ran
out are ended before the repositories are read, as in every cycle.

=item B<--runner> I<file>

Override the executor path from configuration or the C<simpici-executor>
default.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
