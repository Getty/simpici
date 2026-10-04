package SimpiCI::App::Eventd;

use strict;
use warnings;

# ABSTRACT: Implementation of the simpicid polling daemon

use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Pod::Usage qw( pod2usage );
use SimpiCI::Dispatcher;
use SimpiCI::Runner;
use SimpiCI::Queue;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;

sub dispatcher_class { 'SimpiCI::Dispatcher' }

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
        repository => $repository
      );
      # Only the observation is survivable: a remote that is unreadable or
      # returns no refs changes no state, and the next cycle reads it again. A
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

sub unread_message {
  my ( $class, $repository, $reason ) = @_;

  # SimpiCI::Event refuses credentials in a URL, but only once a changed ref
  # is run; an unreadable remote is reported before that.
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

This is what a mirror gives before it is synchronised, and it must not turn
its recorded tips into new ones. If the refs are gone for good, remove the
repository from the configuration or delete the named file below the state
root; the empty answer then becomes the baseline. A repository without
recorded tips is not reported: its empty answer is that baseline, and refs
that appear afterwards are built.

Nothing beyond the observation is covered: a run that cannot be
started, an unwritable queue or state root, and an unusable grant still end
the daemon. C<git ls-remote> runs without a timeout, so a remote that hangs
holds up the whole cycle.

=head1 METHODS

=head2 dispatcher_class

Class used to check the grants in dispatcher mode.

=head2 run

  my $status = SimpiCI::App::Eventd->run(@arguments);

Runs the daemon with an explicit argument list and returns its process exit
status when C<--once> is used or the loop otherwise ends: 1 if a repository
was not polled, 0 otherwise.

=head2 unread_message

  warn SimpiCI::App::Eventd->unread_message($repository, $reason);

Formats the single log line for a repository that was not polled, be it that
its refs could not be read or that L<SimpiCI::Source::GitPoll/rejection>
refused what was read. Credentials in an HTTP or HTTPS clone URL are left out,
also where the reason repeats that URL.

=head1 OPTIONS

=over 4

=item B<--config> I<file>

Required JSON configuration. See C<etc/simpici.example.json>.

=item B<--once>

Poll every configured repository once and exit instead of sleeping. A normally
completed poll returns zero even if a local build failed; inspect the run
reports for build status. The exit status is 1 if the refs of a repository
could not be read, or if it returned none while tips are recorded for it; the
other repositories are polled all the same.

=item B<--runner> I<file>

Override the executor path from configuration or the C<simpici-executor>
default.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
