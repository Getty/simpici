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
  my $store = SimpiCI::Store->new(root => path($config->{root} // './var'));
  my $configured_runner = $runner_script // $config->{runner};
  my $runner = SimpiCI::Runner->new(
    store   => $store,
    timeout => $config->{timeout} // 3600,
    $configured_runner ? (runner_script => path($configured_runner)) : ()
  );

  if (($config->{mode} // 'local') eq 'dispatcher') {
    $runner = SimpiCI::Queue->new(store => $store);
    # Do not poll for a configuration that no claim could be served from.
    $class->dispatcher_class->new(queue => $runner, config => $config)->validate;
  }

  my $status = 0;
  while (1) {
    for my $repository ($config->{repositories}->@*) {
      my $poller = SimpiCI::Source::GitPoll->new(
        store      => $store,
        runner     => $runner,
        repository => $repository,
        defined $config->{ls_remote_timeout}
          ? ( ls_remote_timeout => $config->{ls_remote_timeout} ) : ()
      );
      # Only the observation is survivable: a remote that is unreadable, has
      # no refs or returns none changes no state, and the next cycle reads it
      # again. Both of its queries are made in observe, for that reason. A
      # failing run or queue still ends the daemon, and so do recorded tips
      # that cannot be read: the rejection is asked for outside the eval.
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

A repository that answers without any of the configured refs while tips are
recorded for it is treated the same way, with its own reason:

  simpicid: repository owner/project (https://example/owner/project.git) not polled: remote returned no refs, keeping recorded tips: 2 in state/repositories/<id>.json

This is what a mirror gives that was set up again and is not synchronised
yet, and it must not turn its recorded tips into new ones. If the refs are
gone for good, remove the repository from the configuration or delete the
named file below the state root; the repository then counts as never read.

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

=head1 METHODS

=head2 dispatcher_class

Class used to check the grants in dispatcher mode.

=head2 event_class

Class whose clone URL rule L</check_repositories> applies and L</unread_message>
shows a clone URL by.

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
C<ls_remote_timeout>, if it returned none while tips are recorded for it, or
if it has none at all and nothing is recorded; the other repositories are
polled all the same.

=item B<--runner> I<file>

Override the executor path from configuration or the C<simpici-executor>
default.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
