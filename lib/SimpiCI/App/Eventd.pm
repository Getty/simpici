package SimpiCI::App::Eventd;
our $VERSION = '0.001';

use strict;
use warnings;

# ABSTRACT: Implementation of the simpicid polling daemon

use Carp qw( croak );
use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Pod::Usage qw( pod2usage );
use SimpiCI::Config;
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Queue;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;

sub config_class { 'SimpiCI::Config' }

sub dispatcher_class { 'SimpiCI::Dispatcher' }

sub event_class { 'SimpiCI::Event' }

sub poller_class { 'SimpiCI::Source::GitPoll' }

sub repository_keys { qw( name clone_url refs build_initial secrets ) }

sub run {
  my ( $class, @arguments ) = @_;

  my ($config_path, $once, $check, $runner_script, $help, $man);
  GetOptionsFromArray(
    \@arguments,
    'config=s' => \$config_path,
    'once'     => \$once,
    'check'    => \$check,
    'runner=s' => \$runner_script,
    'help|h'   => \$help,
    'man'      => \$man
  ) or pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1);
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 1) if $help;
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 2) if $man;
  pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1,
    -message => 'A configuration file is required.') unless $config_path;

  umask 0077;
  # In either mode and before anything is polled, written or queued: a
  # mistake would show too, but with the daemon long running. It is one
  # check, whether it is asked for alone or made on the way to the first
  # cycle.
  my ( $config, $unreadable ) = $class->config_class->read($config_path);
  my ( $errors, $warnings ) = defined $unreadable
    ? ( [ __PACKAGE__.' '.$unreadable ], [] ) : $class->check($config);
  return $class->report($errors, $warnings) if $check;
  croak $errors->[0] if @$errors;
  my $store = $class->store($config);
  my $configured_runner = $runner_script // $config->{runner};
  my $runner = SimpiCI::Runner->new(
    store   => $store,
    timeout => $config->{timeout} // 3600,
    $configured_runner ? (runner_script => path($configured_runner)) : ()
  );

  my $dispatcher;
  if ($class->config_class->mode($config) eq 'dispatcher') {
    $runner = SimpiCI::Queue->new(store => $store);
    # Its grants are checked: no configuration is polled for that no claim
    # could be served from.
    $dispatcher = $class->dispatcher_class->new(queue => $runner, config => $config);
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
      my $poller = $class->poller_class->new(
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

# Everything that is wrong with a decoded configuration, and what is merely
# odd about it. Nothing in here croaks and nothing is handed on as an
# argument that a backtrace could print: what stands in a configuration in
# the wrong place may be a token.
sub check {
  my ( $class, $config ) = @_;

  return ( [ __PACKAGE__.' configuration must be an object' ], [] ) unless ref $config eq 'HASH';
  my $rules = $class->config_class;
  my @errors = map { __PACKAGE__.' '.$_ }
    ( map { $rules->setting_rejection($config, $_) } $rules->setting_names ),
    $class->repository_problems($config);
  # Grants are evaluated by the dispatcher alone. What it says about the
  # entry of a repository is what was said above already.
  my $dispatching = ( $rules->mode($config) // '' ) eq 'dispatcher';
  push @errors, map { $_->{message} } grep { !$_->{entry} } $class->dispatcher_class->findings($config)
    if $dispatching;
  return ( \@errors, [ $class->unknown_keys($config, $dispatching) ] );
}

sub report {
  my ( $class, $errors, $warnings ) = @_;

  print STDERR 'simpicid: '.$_."\n" for @$errors;
  print STDERR 'simpicid: warning: '.$_."\n" for @$warnings;
  return @$errors ? 1 : 0;
}

sub check_repositories {
  my ( $class, $config ) = @_;

  my ( $first ) = $class->repository_problems($config);
  croak __PACKAGE__.' '.$first if defined $first;
  return;
}

# No message repeats what stands in an entry: in the wrong place that may be
# a clone URL with its token.
sub repository_problems {
  my ( $class, $config ) = @_;

  my $repositories = $config->{repositories};
  return 'repositories must be a list' unless ref $repositories eq 'ARRAY';
  my @problems;
  for my $index (0 .. $#$repositories) {
    my $repository = $repositories->[$index];
    unless (ref $repository eq 'HASH') {
      push @problems, 'repositories['.$index.'] must be an object';
      next;
    }
    my $where = $class->_entry($repository, $index).': ';
    push @problems, map { $where.$_ } $class->_entry_problems($repository);
  }
  return @problems;
}

# How an entry is named: by its name, if it has one that is a line of text,
# and by its position. A name the event would refuse is not printed.
sub _entry {
  my ( $class, $repository, $index ) = @_;

  my $name = $repository->{name};
  my $printable = defined $name && !ref $name && !defined $class->event_class->name_rejection($name);
  return 'repository '.( $printable ? $name : '?' ).' (repositories['.$index.'])';
}

sub _entry_problems {
  my ( $class, $repository ) = @_;

  my @problems;
  my ( $name, $clone_url ) = $repository->@{qw( name clone_url )};
  if (grep { !defined || ref || !length } $name, $clone_url) {
    push @problems, 'repository needs name and clone_url';
  } else {
    my $unnamed = $class->event_class->name_rejection($name);
    push @problems, 'name '.$unnamed if defined $unnamed;
    my $refused = $class->event_class->clone_url_rejection($clone_url);
    push @problems, $refused if defined $refused;
  }
  # Without the list, every cycle would fail where the refs are read, and
  # an entry without it would be polled for every ref the repository has.
  my $refs = $repository->{refs};
  push @problems, 'refs must be a list of ref names or patterns'
    unless ref $refs eq 'ARRAY' && !grep { !defined || ref || !length } @$refs;
  my $initial = $repository->{build_initial};
  push @problems, 'build_initial must be true or false'
    unless !defined $initial || JSON::MaybeXS::is_bool($initial)
      || ( !ref $initial && $initial =~ /\A[01]\z/ );
  return @problems;
}

# The keys nothing reads. A key is named if it is a word; anything else may
# be a value that slipped into the place of a key.
sub unknown_keys {
  my ( $class, $config, $dispatching ) = @_;

  my @unknown = map { __PACKAGE__.' '.$_ }
    $class->_unknown($config, $class->config_class->setting_names, 'repositories');
  my $repositories = $config->{repositories};
  return @unknown unless ref $repositories eq 'ARRAY';
  for my $index (0 .. $#$repositories) {
    my $repository = $repositories->[$index];
    next unless ref $repository eq 'HASH';
    my $where = __PACKAGE__.' '.$class->_entry($repository, $index);
    push @unknown, map { $where.': '.$_ } $class->_unknown($repository, $class->repository_keys);
    my $secrets = $repository->{secrets};
    next unless $dispatching && ref $secrets eq 'ARRAY';
    for my $position (0 .. $#$secrets) {
      my $secret = $secrets->[$position];
      next unless ref $secret eq 'HASH';
      my $name = $class->dispatcher_class->secret_name_valid($secret->{name}) ? $secret->{name} : '?';
      push @unknown, map { $where.', secret '.$name.' (secrets['.$position.']): '.$_ }
        $class->_unknown($secret, $class->dispatcher_class->grant_keys);
    }
  }
  return @unknown;
}

sub _unknown {
  my ( $class, $object, @known ) = @_;

  my %known = map { $_ => 1 } @known;
  return map { 'unknown key '.( /\A[A-Za-z0-9_.-]{1,64}\z/ ? $_ : '?' ) }
    sort grep { !$known{$_} } keys %$object;
}

sub interrupted_message {
  my ( $class, $report ) = @_;

  return 'simpicid: run '.$report->{run}.' interrupted: its lease expired without a completion'."\n";
}

sub unread_message {
  my ( $class, $repository, $reason ) = @_;

  # run refuses a clone URL the rule does not accept before it polls, so it
  # never gets here with one; a direct caller is not held to that.
  my $configured = $repository->{clone_url} // '';
  my $clone_url = $class->event_class->clone_url_without_credentials($configured);
  $reason =~ s/\Q$configured\E/$clone_url/g if length $configured;
  $reason =~ s/\s+/ /g;
  $reason =~ s/ \z//;
  # One line of text, whatever the remote sent: nothing of it moves the
  # terminal the journal is read on.
  $reason =~ s/[\x00-\x1f\x7f]/?/g;
  return 'simpicid: repository '.( $repository->{name} // '' ).' ('.$clone_url
    .') not polled: '.$reason."\n";
}

1;

=head1 NAME

SimpiCI::App::Eventd - implementation of the simpicid polling daemon

=head1 SYNOPSIS

  simpicid --config simpici.json
  simpicid --config simpici.json --once
  simpicid --config simpici.json --check
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

=head2 Checking the configuration

Before it polls, writes or queues anything, the daemon checks the whole
configuration, in either mode, see L</check>. It ends with the first thing
that cannot be used, in one line:

  SimpiCI::App::Eventd timeout must be a positive integer at ... line N.

C<--check> makes this check and nothing else. It prints every finding, not
only the first, one line each on standard error, and exits with 0 if the
daemon would start with the file and with 1 if it would not:

  simpicid: SimpiCI::App::Eventd interval must be a positive integer
  simpicid: SimpiCI::App::Eventd repository owner/project (repositories[0]): refs must be a list of ref names or patterns
  simpicid: SimpiCI::Dispatcher repository owner/project (repositories[0]), secret CICD_REGISTRY_PASSWORD (secrets[0]): cannot read secret file: Permission denied
  simpicid: warning: SimpiCI::App::Eventd unknown key intervall

No remote is read for it, no state is written, no lease is ended and nothing
is queued; the state root is not even created. It reads the configuration
and, in dispatcher mode, the secret files, so it says what the daemon would
find only when it runs as the account of the daemon. A configuration that
passes prints nothing.

A line with C<warning:> is no error and does not change the exit status.
There is one kind: a key that nothing reads, at the top of the
configuration, in an entry of C<repositories> or, in dispatcher mode, in a
grant. Mostly it is a setting that was misspelt and is therefore not in
effect. The daemon starts with such a file and does not mention the key;
only C<--check> does. The key is named if it is a word of letters, digits,
C<_>, C<.> and C<->, and shown as C<?> otherwise.

No finding repeats a value of the configuration: what stands in the wrong
place of it may be a token.

The file has to be readable, JSON and an object, see L<SimpiCI::Config/read>:

  SimpiCI::App::Eventd cannot read the configuration: No such file or directory
  SimpiCI::App::Eventd configuration is no JSON: the decoder stopped at character 212
  SimpiCI::App::Eventd configuration must be an object

Its top-level settings are held against L<SimpiCI::Config/SETTINGS>:
C<interval>, C<timeout>, C<ls_remote_timeout> and C<request_read_timeout>
are positive integers, C<mode> is C<local> or C<dispatcher>, C<root> and
C<runner> are nonempty strings, and C<root> is required in dispatcher mode.
Each of them is checked in both modes, also where only one mode uses it:

  SimpiCI::App::Eventd ls_remote_timeout must be a positive integer
  SimpiCI::App::Eventd mode must be "local" or "dispatcher"
  SimpiCI::App::Eventd root is required in dispatcher mode

C<repositories> has to be a list of objects, see L</check_repositories>,
each with a C<name> and a C<clone_url> that are nonempty strings, the name
without a control character, as L<SimpiCI::Event/name_rejection> has it for
the repository of an event, with C<refs> that are a list of nonempty strings
and, if it is there, a C<build_initial> that is C<true> or C<false>:

  SimpiCI::App::Eventd repositories must be a list
  SimpiCI::App::Eventd repositories[1] must be an object
  SimpiCI::App::Eventd repository owner/project (repositories[0]): repository needs name and clone_url
  SimpiCI::App::Eventd repository ? (repositories[0]): name must not contain control characters
  SimpiCI::App::Eventd repository owner/project (repositories[0]): refs must be a list of ref names or patterns
  SimpiCI::App::Eventd repository owner/project (repositories[0]): build_initial must be true or false

A name with a control character is not printed, in this message or in the
one for another mistake of its entry: the C<?> stands for it, as for a name
that is missing. An entry without C<refs>, or with a string in their place,
could not be polled in any cycle, which is why it is refused here. An empty
list is accepted and asks for every ref the repository has.

The check holds every C<clone_url> against
L<SimpiCI::Event/clone_url_rejection>, which accepts the forms listed in
L<SimpiCI::Event/CLONE URLS> and gives one of five reasons for anything
else, such as:

  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must be a URL of the scheme https, http, ssh or file, an SSH address of the form [user@]host:path or an absolute path
  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must not begin with "-"
  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git

A message names the repository, if it has a name, and its position in the
configuration, never the URL or what else stands in the entry. The credentials
of an C<https://user:token@...> URL belong in the Git configuration of the
account the daemon runs as, see C<gitcredentials(7)>; the password of an
C<ssh://user:password@...> URL is replaced by a key of that account. In
dispatcher mode the worker fetches the commit and needs its own.

The check is made once, at the start, also for what git could never read as
the address of a repository: a clone URL that begins with C<->, and one that
names a remote helper, as C<ext::...> or a scheme git does not know. Left to
the poll, the first would be reported as not polled in every cycle, and for
the second git would start the program of the helper in every cycle.

In dispatcher mode the grants of every repository follow, with the rules
and the words of L<SimpiCI::Dispatcher/problems>: a grant that cannot be
used, and one that could be used and would apply to no run.

=head2 A repository that is not polled

A repository whose refs cannot be read does not end the daemon. It writes one
line to standard error and goes on with the next repository:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: ...

The line carries the text C<git ls-remote> printed, as one line: of a long
text the beginning and the end, 1000 characters in all, with every control
character shown as C<?>. It repeats in every cycle until the repository is
readable again. The recorded tips of that repository
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

What a repository may answer is limited too: 16 MiB of refs and 1 MiB on
standard error. A query that prints more is ended at once, and its
repository is not polled in this cycle:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: ... git ls-remote printed more than 16777216 bytes on standard output

An answer that was cut off is no observation: nothing of it is compared,
recorded or built.

Nothing beyond the observation is covered: a run that cannot be
started, an unwritable queue or state root and a state that cannot be read
still end the daemon. A configuration that cannot be used does not get
this far.

=head2 Ending the daemon

In local mode, C<TERM>, C<INT> and C<HUP> during a run end the run before
they end the daemon: the process group of the executor is ended, the
containers of the run are removed, and the run is reported as C<signalled>
with the exit code 128 plus the signal. A daemon that is killed leaves a
process that ends the run in the same way, without a report. See
L<SimpiCI::Runner/Ending a run>.

While the refs of a repository are read, in either mode, the three signals
end that query before they end the daemon. git runs in a process group of
its own, so that its limit reaches the helpers it starts, and a signal for
the daemon alone would leave all of them behind: the daemon ends the group
with C<TERM> and, at most a second later, C<KILL>, and then ends by the
signal it received. Nothing is recorded for the repository. A daemon that is
killed cannot do this. Its query stays until the remote gives up, and no
limit holds for it any more, as the limit is kept by the daemon.

At any other time the signals end the daemon at once.

=head2 Exit status

C<simpicid> ends with 0 after a C<--once> in which every repository was
polled and after a C<--check> without an error. It ends with 1 after a
C<--once> in which a repository was not polled and after a C<--check> that
found an error. It ends with 64 for a call it does not understand, and with
3 when it cannot start or cannot go on: a configuration the check refuses,
a state or a queue it cannot read or write, a run it cannot start. The
reason is on standard error. L</run> croaks in that case, and the program
turns that into the 3, so that the status is never the errno a C<die>
happens to leave, which may be the 1 that means something else. A daemon
that a signal ended has the status of that signal.

The daemon does not look for containers at its start. If it is killed
together with everything it started, the containers of its run stay; the
file C<containers/E<lt>runE<gt>> below the state root names their label for
C<docker ps --filter label=...>. Logs and checkouts of local runs are kept
as they are and never removed.

=head1 METHODS

=head2 config_class

Class that reads the configuration file and has the rules of its top-level
settings, L<SimpiCI::Config>.

=head2 dispatcher_class

Class used in dispatcher mode to check the grants at the start and to end
the leases that ran out in every cycle.

=head2 event_class

Class whose rules for a name and a clone URL L</check_repositories> applies
and L</unread_message> shows a clone URL by.

=head2 poller_class

Class that reads and records the refs of a repository,
L<SimpiCI::Source::GitPoll>.

=head2 repository_keys

The keys an entry of C<repositories> can have: C<name>, C<clone_url>,
C<refs>, C<build_initial> and C<secrets>. Any other gets a warning of
L</unknown_keys>.

=head2 store

  my $store = SimpiCI::App::Eventd->store($config);

The L<SimpiCI::Store> of a decoded configuration: its C<root>, or F<./var>
without one. C<simpici> finds the recorded tips of the daemon by it.

=head2 check

  my ( $errors, $warnings ) = SimpiCI::App::Eventd->check($config);

Checks a decoded configuration as a whole and returns two array references:
everything the daemon cannot start with, and everything that is merely odd.
Each entry is one line of text without a line end, beginning with the class
that found it. The errors come in this order: the top-level settings by
L<SimpiCI::Config/setting_rejection>, the entries of C<repositories> by
L</repository_problems> and, in dispatcher mode, the grants by
L<SimpiCI::Dispatcher/findings>, without those that only repeat what was
said about the entry of a repository. The warnings are L</unknown_keys>.
A configuration that is no object has that one error.

It croaks for nothing, reads nothing but the secret files of the grants and
writes nothing. L</run> makes this check before the first cycle and croaks
with the first error; with C<--check> it hands both lists to L</report>
instead.

=head2 report

  my $status = SimpiCI::App::Eventd->report($errors, $warnings);

Prints the findings of L</check> on standard error, the errors as
C<simpicid: ...> and then the warnings as C<simpicid: warning: ...>, and
returns the exit status of C<--check>: 1 if there is an error, 0 otherwise.

=head2 check_repositories

  SimpiCI::App::Eventd->check_repositories($config);

Croaks with the first of L</repository_problems>, if there is one. C<simpici>
calls it before it reads the recorded tips of a configuration; the daemon
makes the whole L</check>.

=head2 repository_problems

  my @problems = SimpiCI::App::Eventd->repository_problems($config);

Returns what is wrong with C<repositories> in a decoded configuration,
without the name of this class in front: C<repositories> is no list, an
entry is no object, its C<name> or C<clone_url> is missing, empty or no
string, its C<name> is refused by L<SimpiCI::Event/name_rejection> or its
C<clone_url> by L<SimpiCI::Event/clone_url_rejection>, its C<refs> are no
list of nonempty strings, its C<build_initial> is neither a JSON boolean nor
1 or 0. Every mistake of an entry is returned, not only its first. A problem
gives the index of the entry, its name if it has one that can be printed and
the reason, never the clone URL or any other value of the entry: a URL with
a token may stand in the place of the object.

The grants of an entry are not looked at here. L<SimpiCI::Dispatcher/problems>
checks them, and refuses the same mistakes in C<repositories> with the same
words when C<simpici-dispatch> reads the file without the daemon.

=head2 unknown_keys

  my @warnings = SimpiCI::App::Eventd->unknown_keys($config, $dispatching);

Returns one line for every key of a decoded configuration that nothing
reads: at its top, in an entry of C<repositories> and, if the second
argument is true, in a grant. A key is named if it is a word, and is C<?>
otherwise. The values are not looked at.

=head2 run

  my $status = SimpiCI::App::Eventd->run(@arguments);

Runs the daemon with an explicit argument list and returns its process exit
status when C<--once> is used or the loop otherwise ends: 1 if a repository
was not polled, 0 otherwise. With C<--check> it returns what L</report>
returns and polls nothing. It croaks with the first error of L</check> for a
configuration the daemon cannot start with.

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
the reason repeats it, so the user part of a URL the clone URL rule refuses
is left out. L</run> refuses such a URL before it polls, so this only
matters to a direct caller. The reason is put on one line, and every control
character that is left in it is replaced by C<?>.

=head1 OPTIONS

=over 4

=item B<--config> I<file>

Required JSON configuration. See C<etc/simpici.example.json>.

=item B<--once>

Poll every configured repository once and exit instead of sleeping. A normally
completed poll returns zero even if a local build failed; inspect the run
reports for build status. The exit status is 1 if the refs of a repository
could not be read, be it that the query failed, that it ran into
C<ls_remote_timeout> or that it printed more than it may, if it returned
none while configured refs of its last poll are missed, or if it has none at
all and nothing is recorded; the other repositories are polled all the
same. In dispatcher mode the leases that ran
out are ended before the repositories are read, as in every cycle.

=item B<--check>

Check the configuration and exit, without polling: exit status 0 if the
daemon would start with it, 1 if not, with one line on standard error for
everything that is wrong, and one that begins with C<warning:> for every key
nothing reads. See L</Checking the configuration>. Run it as the account of
the daemon, which is the one that has to read the secret files.

=item B<--runner> I<file>

Override the executor path from configuration or the C<simpici-executor>
default.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
