package SimpiCI::App::Run;

use strict;
use warnings;

# ABSTRACT: Implementation of the simpici operator command

use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Pod::Usage qw( pod2usage );
use SimpiCI::App::Eventd;
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;

sub daemon_class { 'SimpiCI::App::Eventd' }

sub event_class { 'SimpiCI::Event' }

sub poller_class { 'SimpiCI::Source::GitPoll' }

sub run {
  my ( $class, @arguments ) = @_;

  my ($root, $event_path, $timeout, $runner_script, $help, $man);
  my ($config_path, $repository, $state, $forget);
  GetOptionsFromArray(
    \@arguments,
    'root=s'       => \$root,
    'event=s'      => \$event_path,
    'timeout=i'    => \$timeout,
    'runner=s'     => \$runner_script,
    'config=s'     => \$config_path,
    'repository=s' => \$repository,
    'state'        => \$state,
    'forget=s'     => \$forget,
    'help|h'       => \$help,
    'man'          => \$man
  ) or pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1);
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 1) if $help;
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 2) if $man;
  if (grep { defined } $config_path, $repository, $state, $forget) {
    # The recorded tips of the daemon, not a run: one of the two requests,
    # and nothing that belongs to an event.
    pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1,
      -message => 'The recorded tips take --config with either --state or --repository and --forget.')
      if !defined $config_path || !( $state xor defined $forget )
        || ( defined $forget && !defined $repository )
        || @arguments || grep { defined } $root, $event_path, $timeout, $runner_script;
    return $class->recorded_tips($config_path, $repository, $forget);
  }
  pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1,
    -message => 'An event JSON file is required.') unless $event_path;

  $root //= './var';
  $timeout //= 3600;
  my $data = JSON::MaybeXS->new->decode(path($event_path)->slurp_utf8);
  my $event = SimpiCI::Event->new($data->%*);
  my $report = SimpiCI::Runner->new(
    store   => SimpiCI::Store->new(root => path($root)),
    timeout => $timeout,
    $runner_script ? (runner_script => path($runner_script)) : ()
  )->run($event);
  print JSON::MaybeXS->new(canonical => 1)->encode($report)."\n";
  return $report->{state} eq 'success' || $report->{state} eq 'skipped' ? 0 : 1;
}

sub recorded_tips {
  my ( $class, $config_path, $name, $forget ) = @_;

  # What is written here is read by the daemon, with the mode it gives it.
  umask 0077;
  # Not left to die: its exit status would be the errno of the moment, which
  # may be one of those that say something here.
  my $status = eval {
    my $config = JSON::MaybeXS->new->decode(path($config_path)->slurp_utf8);
    $class->daemon_class->check_repositories($config);
    my $store = $class->daemon_class->store($config);
    # The state belongs to name and clone URL: a name that is configured with
    # two URLs is two repositories here, the same entry twice is one.
    my ( %seen, @pollers );
    for my $repository ($config->{repositories}->@*) {
      next if defined $name && $repository->{name} ne $name;
      next if $seen{ join "\0", $repository->@{qw( name clone_url )} }++;
      push @pollers, $class->poller_class->new(store => $store, repository => $repository);
    }
    if (defined $name && !@pollers) {
      print STDERR 'simpici: repository '.$name.' is not configured in '.$config_path."\n";
      return 2;
    }
    unless (defined $forget) {
      $class->show_state($_, defined $name) for @pollers;
      return 0;
    }
    my $forgotten = grep { $class->forget_ref($_, $forget) } @pollers;
    return $forgotten ? 0 : 1;
  };
  return $status if defined $status;
  ( my $reason = $@ ) =~ s/\s+/ /g;
  $reason =~ s/ \z//;
  print STDERR 'simpici: '.$reason."\n";
  return 3;
}

sub repository_label {
  my ( $class, $repository ) = @_;

  return 'repository '.$repository->{name}.' ('
    .$class->event_class->clone_url_without_credentials($repository->{clone_url}).')';
}

sub show_state {
  my ( $class, $poller, $with_refs ) = @_;

  my $label = $class->repository_label($poller->repository);
  my $recorded = $poller->recorded;
  unless ($recorded) {
    print $label.': nothing recorded'."\n";
    return;
  }
  my %absent = map { $_ => 1 } $recorded->{absent}->@*;
  my $tips = $recorded->{tips};
  print $label.': recorded refs: '.keys( $tips->%* ).', absent at the last poll: '
    .keys( %absent ).', '.$recorded->{file}.', '.$recorded->{bytes}.' bytes'."\n";
  return unless $with_refs;
  for my $ref (sort keys $tips->%*) {
    # A name is what a remote gave it: nothing of it moves the terminal.
    ( my $line = '  '.$ref.' '.$tips->{$ref}.( $absent{$ref} ? ' absent' : '' ) )
      =~ s/[\x00-\x1f\x7f]/?/g;
    print $line."\n";
  }
  return;
}

sub forget_ref {
  my ( $class, $poller, $ref ) = @_;

  my $label = $class->repository_label($poller->repository);
  my $commit = $poller->forget($ref);
  if (defined $commit) {
    print $label.': forgot '.$ref.', recorded at '.$commit."\n";
    return 1;
  }
  print STDERR 'simpici: '.$label.': '
    .( $poller->recorded ? $ref.' is not recorded' : 'nothing is recorded' )."\n";
  return 0;
}

1;

=head1 NAME

SimpiCI::App::Run - implementation of the simpici operator command

=head1 SYNOPSIS

  simpici --event event.json [--root var] [--timeout 3600]
  simpici --event event.json --runner /opt/simpici/action/run.sh
  simpici --config simpici.json --state [--repository owner/project]
  simpici --config simpici.json --repository owner/project --forget refs/heads/gone
  simpici --help

=head1 DESCRIPTION

The trusted operator command has two uses that share nothing but the
program: it runs one event, or it shows and corrects what C<simpicid> has
recorded about the refs it polls.

=head2 One run

With C<--event> it validates one normalized event, allocates a run, checks
out the exact commit detached, and invokes the shared phased container
executor. A run does not read the daemon configuration or use queue
deduplication; each invocation allocates a new run.

C<TERM>, C<INT> and C<HUP> end the run before they end the command: the
process group of the executor is ended, the containers of the run are
removed, and the report is published as C<signalled> with the exit code 128
plus the signal. No report is printed then; the command ends by the signal.
See L<SimpiCI::Runner/Ending a run>.

=head2 The recorded tips

With C<--config> it works on the state the poller keeps for each configured
repository, see L<SimpiCI::Source::GitPoll/STATE>: the last tip of every ref
it ever observed. A repository is named as the configuration names it, and
the state root is the C<root> of that configuration; neither the file of a
state nor the hash in its name has to be known. Nothing is polled and no
remote is read.

C<--state> prints one line for every configured repository, on standard
output:

  repository owner/project (https://example/owner/project.git): recorded refs: 3, absent at the last poll: 1, state/repositories/<id>.json, 277 bytes
  repository owner/other (https://example/owner/other.git): nothing recorded

The number of recorded refs and the size of the file are how the growth of a
state is seen: a poll never takes a ref out, so a filter such as
C<refs/heads/*> leaves one entry for every branch name that ever existed.
C<absent> counts the refs the last poll did not see, because they are gone
from the repository or because C<refs> no longer selects them. The path is
relative to the state root. With C<--repository> only that repository is
shown, followed by its refs and their tips, the absent ones marked:

  repository owner/project (https://example/owner/project.git): recorded refs: 3, absent at the last poll: 1, state/repositories/<id>.json, 277 bytes
    refs/heads/gone 0b1e... absent
    refs/heads/main 6d0c...
    refs/tags/v1 6d0c...

C<--forget> takes one ref out of the state of the repository named with
C<--repository> and says so on standard output:

  repository owner/project (https://example/owner/project.git): forgot refs/heads/gone, recorded at 0b1e...

The name is the full name of one ref as C<--state> prints it, not a pattern.
What follows depends on the repository, since to the next poll the ref was
never recorded:

=over 4

=item *

A ref the repository no longer has, and one C<refs> no longer selects, is out
of the state and nothing is built. This is how a state is made smaller. If
the ref ever comes back, it is new.

=item *

A ref the repository still has and C<refs> still selects is new at the next
poll and is B<built>, on the commit it is on then, with whatever its grants
give. C<build_initial> has no say in that: it decides about a repository
that was never read, and a repository with a state is not one, not even when
its last ref is forgotten. In local mode the commit is built again even if
it was built before. In dispatcher mode the queue knows a repository, ref
and commit it has accepted once and starts no second run for it.

=back

The command takes the lock the poller holds on the state of a repository, so
neither loses what the other writes. While C<simpicid> is polling that
repository it waits, in local mode until the build has ended. Run it as the
account C<simpicid> runs as: it refuses a state file that belongs to another
account, because the daemon could not read what it would write.

A name that is configured more than once, with different clone URLs, is
several repositories with a state each. C<--state> shows all of them, and
C<--forget> forgets the ref in each that has it.

The exit status says what happened:

=over 4

=item C<0>

The state was shown, or the ref was forgotten, with several repositories of
the name in at least one of them.

=item C<1>

Nothing was forgotten: the ref is not recorded, or nothing is recorded for
the repository at all. Standard error has a line for each:

  simpici: repository owner/project (https://example/owner/project.git): refs/heads/gone is not recorded
  simpici: repository owner/project (https://example/owner/project.git): nothing is recorded

=item C<2>

The configuration has no repository of that name:

  simpici: repository owner/projekt is not configured in simpici.json

=item C<3>

The request could not be served: the configuration cannot be read or is one
C<simpicid> would not start with, or the state cannot be read, locked or
written. Standard error has the reason after C<simpici:>.

=item C<64>

The options are not a request, see L</OPTIONS>.

=back

=head1 METHODS

=head2 run

  my $status = SimpiCI::App::Run->run(@arguments);

Runs the command with an explicit argument list and returns its process exit
status. Help and usage errors are handled by L<Pod::Usage>.

=head2 recorded_tips

  my $status = SimpiCI::App::Run->recorded_tips($config_path, $name, $ref);

Serves a request for the recorded tips and returns its exit status: with a
ref it forgets that ref for the repositories of the name, without one it
shows the state of that repository, or of every configured one if the name
is not defined either. Sets a umask of 077, as the daemon does for what it
writes. An error is printed and answered with 3 instead of being thrown, so
the exit status is never the errno of a C<die>.

=head2 show_state

  SimpiCI::App::Run->show_state($poller, $with_refs);

Prints the line of one repository, and its refs if asked to. Control
characters in a ref name are printed as C<?>.

=head2 forget_ref

  my $forgotten = SimpiCI::App::Run->forget_ref($poller, $ref);

Forgets the ref through L<SimpiCI::Source::GitPoll/forget>, prints the
outcome and returns whether there was something to forget.

=head2 repository_label

  my $label = SimpiCI::App::Run->repository_label($repository);

How a line names a repository: its name and its clone URL as
L<SimpiCI::Event/clone_url_without_credentials> gives it.

=head2 daemon_class

Class whose reading of the configuration is used: its
L<check|SimpiCI::App::Eventd/check_repositories> of the repositories and its
L<store|SimpiCI::App::Eventd/store>.

=head2 event_class

Class L</repository_label> shows a clone URL by.

=head2 poller_class

Class that keeps the recorded tips.

=head1 OPTIONS

A run takes C<--event> and may take C<--root>, C<--timeout> and C<--runner>.
The recorded tips take C<--config> with either C<--state> or C<--forget>,
and none of the options of a run.

=over 4

=item B<--event> I<file>

Event JSON containing C<source>, C<event>, C<repository>, C<clone_url>,
C<ref>, and a full 40- or 64-character lowercase hexadecimal C<commit>.
Required for a run.

=item B<--root> I<directory>

Private state, checkout, log, and report root. Defaults to C<./var>.

=item B<--timeout> I<seconds>

Maximum executor runtime. Defaults to 3600 seconds.

=item B<--runner> I<file>

Executor path. Defaults to C<bin/simpici-executor> in a source checkout or the
installed C<simpici-executor> found on C<PATH>. Use an absolute override path:
the runner changes into the checkout before execution.

=item B<--config> I<file>

The JSON configuration C<simpicid> polls with. It names the repositories and
the state root. Required for the recorded tips.

=item B<--state>

Show what is recorded for the configured repositories, or for the one named
with C<--repository>, its refs included.

=item B<--repository> I<name>

The C<name> of a repository in the configuration. Required with C<--forget>.

=item B<--forget> I<ref>

Take the one ref of that full name out of the recorded tips of the
repository.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
