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
  # In either mode and before anything is polled: the event of the first
  # changed ref would refuse the URL too, but with the daemon long running.
  $class->check_clone_urls($config);
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

sub check_clone_urls {
  my ( $class, $config ) = @_;

  # Only the rule of the event is applied. Any other shape is left to the
  # poll, which reports it as before.
  my $repositories = $config->{repositories};
  return unless ref $repositories eq 'ARRAY';
  for my $index (0 .. $#$repositories) {
    my $repository = $repositories->[$index];
    next unless ref $repository eq 'HASH';
    my $clone_url = $repository->{clone_url};
    next unless defined $clone_url && !ref $clone_url;
    my $reason = $class->event_class->clone_url_rejection($clone_url) // next;
    my $name = $repository->{name};
    croak __PACKAGE__.' repository '.( defined $name && !ref $name ? $name : '?' )
      .' (repositories['.$index.']): '.$reason;
  }
  return;
}

sub unread_message {
  my ( $class, $repository, $reason ) = @_;

  # run refuses credentials in an HTTP(S) URL before it polls, so it never
  # gets here with them; a direct caller is not held to that.
  my $configured = $repository->{clone_url} // '';
  ( my $clone_url = $configured ) =~ s{\A(https?://)[^/]*@}{$1}i;
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

In either mode the daemon first holds the C<clone_url> of every configured
repository against L<SimpiCI::Event/clone_url_rejection> and exits before it
polls if one is refused:

  SimpiCI::App::Eventd repository owner/project (repositories[0]): clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git

The message names the repository and its position in the configuration, never
the URL. The credentials of an C<https://user:token@...> URL belong in the Git
configuration of the account the daemon runs as, see C<gitcredentials(7)>; in
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
started, an unwritable queue or state root, a refused clone URL and an
unusable grant still end the daemon.

=head1 METHODS

=head2 dispatcher_class

Class used to check the grants in dispatcher mode.

=head2 event_class

Class whose clone URL rule L</check_clone_urls> applies.

=head2 check_clone_urls

  SimpiCI::App::Eventd->check_clone_urls($config);

Croaks for the first repository of a decoded configuration whose C<clone_url>
is refused by L<SimpiCI::Event/clone_url_rejection>, with the name of the
repository, its index and the reason, but without the URL. L</run> calls it
before it polls. It applies that one rule and is no validation of the
configuration: a repository without a clone URL, or an entry of any other
unexpected shape, passes and shows when it is polled.

=head2 run

  my $status = SimpiCI::App::Eventd->run(@arguments);

Runs the daemon with an explicit argument list and returns its process exit
status when C<--once> is used or the loop otherwise ends: 1 if a repository
was not polled, 0 otherwise.

=head2 unread_message

  warn SimpiCI::App::Eventd->unread_message($repository, $reason);

Formats the single log line for a repository that was not polled, be it that
its refs could not be read, that it has none yet or that
L<SimpiCI::Source::GitPoll/rejection> refused what was read. Credentials in
an HTTP or HTTPS clone URL are left out, also where the reason repeats that
URL. L</run> refuses such a URL before it
polls, so this only matters to a direct caller.

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
