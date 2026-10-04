package SimpiCI::Source::GitPoll;

use Moo;

# ABSTRACT: Poll configured Git refs for SimpiCI

use SimpiCI::Event;
use Digest::SHA qw( sha256_hex );
use SimpiCI::Runner;
use SimpiCI::Store;
use Carp qw( croak );
use IO::Select;
use JSON::MaybeXS;
use Path::Tiny qw( path );
use POSIX qw( WNOHANG setpgid );
use Time::HiRes qw( sleep time );
use Types::Common::Numeric qw( PositiveInt );
use Types::Standard qw( HashRef InstanceOf Object );
use namespace::autoclean;

has store => (
  is       => 'ro',
  isa      => InstanceOf['SimpiCI::Store'],
  required => 1,
);

has runner => (
  is       => 'ro',
  isa      => Object,
  required => 1,
);

has repository => (
  is       => 'ro',
  isa      => HashRef,
  required => 1,
);

has ls_remote_timeout => (
  is      => 'ro',
  isa     => PositiveInt,
  default => sub { 60 },
);

sub poll {
  my ( $self, $observed ) = @_;

  my $repository = $self->repository;
  my $recorded = $self->_recorded;
  $observed //= $self->observe;
  my $rejection = $self->rejection($observed);
  croak __PACKAGE__.' '.$rejection if defined $rejection;
  my $previous = $recorded // {};
  my @reports;

  for my $ref (sort keys $observed->%*) {
    my $commit = $observed->{$ref};
    my $old = $previous->{$ref};
    next if defined $old && $old eq $commit;
    next unless defined $old || $recorded || $repository->{build_initial};
    push @reports, $self->runner->run(SimpiCI::Event->new(
      source     => 'git-poll',
      event      => 'push',
      repository => $repository->{name},
      clone_url  => $repository->{clone_url},
      ref        => $ref,
      commit     => $commit
    ));
  }
  # A ref the remote no longer shows keeps its last tip: back on that commit
  # it is no event, and the state never forgets a ref by itself.
  $self->store->write_json($self->_state_file, { $previous->%*, $observed->%* });
  return \@reports;
}

sub rejection {
  my ( $self, $observed ) = @_;

  # A reachable remote without one usable ref says nothing about the recorded
  # tips. Merged, it would leave them as they are too; refused, it is told
  # apart from a poll that found nothing new.
  return if $observed->%*;
  my $recorded = keys( ( $self->_recorded // {} )->%* );
  return unless $recorded;
  return 'remote returned no refs, keeping recorded tips: '.$recorded.' in '
    .$self->_state_file;
}

sub _state_file {
  my ( $self ) = @_;

  my $repository = $self->repository;
  return 'state/repositories/'
    .sha256_hex(join "\0", $repository->{name}, $repository->{clone_url}).'.json';
}

sub _state_path {
  my ( $self ) = @_;

  return $self->store->root->child($self->_state_file);
}

sub _recorded {
  my ( $self ) = @_;

  my $state_path = $self->_state_path;
  return unless $state_path->is_file;
  return JSON::MaybeXS->new->decode($state_path->slurp_utf8);
}

sub observe {
  my ( $self ) = @_;

  my @patterns = $self->repository->{refs}->@*;
  my $deadline = time + $self->ls_remote_timeout;
  my $observed = $self->_ls_remote($deadline, @patterns);
  # No match and no baseline: only the whole repository tells a filter that
  # matches nothing from a repository that is not filled yet. Of the state
  # only its existence is asked here; reading it is left to the rejection.
  return $observed if $observed->%* || $self->_state_path->is_file;
  my $whole = @patterns ? $self->_ls_remote($deadline) : $observed;
  croak __PACKAGE__.' repository has no refs yet'
    unless grep { m{\Arefs/} } keys $whole->%*;
  return $observed;
}

sub _ls_remote {
  my ( $self, $deadline, @patterns ) = @_;

  my $limit = $self->ls_remote_timeout;
  my $result = $self->_capture($deadline - time,
    'git', 'ls-remote', '--', $self->repository->{clone_url}, @patterns);
  croak __PACKAGE__.' git ls-remote timed out after '.$limit.' s'
    .( length $result->{stderr} ? ': '.$result->{stderr} : '' ) if $result->{timed_out};
  croak __PACKAGE__.' git ls-remote failed: '.$result->{stderr} if $result->{status} != 0;
  my %observed;
  for my $line (split /\n/, $result->{stdout}) {
    my ( $commit, $ref ) = split /\s+/, $line, 2;
    next unless defined $ref && $commit =~ /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/;
    if ($ref =~ s/\^\{\}\z//) {
      $observed{$ref} = $commit;
    } else {
      $observed{$ref} //= $commit;
    }
  }
  return \%observed;
}

sub _capture {
  my ( $self, $timeout, @command ) = @_;

  pipe(my $stdout, my $stdout_writer) or croak __PACKAGE__.' cannot create a pipe: '.$!;
  pipe(my $stderr, my $stderr_writer) or croak __PACKAGE__.' cannot create a pipe: '.$!;
  my $pid = fork;
  croak __PACKAGE__.' cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    # A process group of its own, as SimpiCI::Runner gives a run: the limit
    # has to reach the helpers git starts, not only git.
    setpgid(0, 0);
    open STDIN, '<', '/dev/null' or POSIX::_exit(126);
    open STDOUT, '>&', $stdout_writer or POSIX::_exit(126);
    open STDERR, '>&', $stderr_writer or POSIX::_exit(126);
    { no warnings 'exec'; exec { $command[0] } @command; }
    print STDERR 'cannot execute '.$command[0].': '.$!."\n";
    POSIX::_exit(126);
  }
  close $stdout_writer;
  close $stderr_writer;

  # Both pipes are emptied while the command runs, and what ends the wait is
  # the process, not the end of its output: a helper may outlive it with a
  # pipe still open.
  my %captured = ( $stdout => '', $stderr => '' );
  my $open = IO::Select->new($stdout, $stderr);
  my $drain = sub {
    my ( $wait ) = @_;
    my @ready = $open->can_read($wait);
    for my $handle (@ready) {
      my $read = sysread $handle, $captured{$handle}, 65536, length $captured{$handle};
      next if $read || ( !defined $read && $!{EINTR} );
      $open->remove($handle);
    }
    return scalar @ready;
  };
  my $deadline = time + $timeout;
  my $timed_out;
  while (waitpid($pid, WNOHANG) == 0) {
    if (time >= $deadline) {
      kill 'TERM', -$pid;
      sleep 1;
      kill 'KILL', -$pid;
      waitpid($pid, 0);
      $timed_out = 1;
      last;
    }
    $open->count ? $drain->(0.05) : sleep 0.05;
  }
  my $status = $?;
  1 while $drain->(0);
  return {
    status    => $status,
    timed_out => $timed_out,
    stdout    => $captured{$stdout},
    stderr    => $captured{$stderr}
  };
}

1;

=head1 NAME

SimpiCI::Source::GitPoll - poll configured Git refs for SimpiCI

=head1 SYNOPSIS

  my $reports = SimpiCI::Source::GitPoll->new(
    store      => $store,
    runner     => $runner,
    repository => {
      name          => 'owner/project',
      clone_url     => 'https://example/owner/project.git',
      refs          => ['refs/heads/main'],
      build_initial => 1
    }
  )->poll;

=head1 ATTRIBUTES

=head2 ls_remote_timeout

Seconds L</observe> waits for the refs of the repository, a positive integer,
60 by default. An observation that asks twice has them once, for both queries
together. It has nothing to do with the timeout of a run, which belongs to
the runner.

=head1 METHODS

=head2 observe

  my $observed = $poller->observe;

Reads the configured remote refs once with C<git ls-remote> and returns a hash
reference of ref names to commit ids. Croaks with the text git printed when
the remote cannot be read. A remote that answers without a usable ref yields
an empty hash; whether that is acceptable is for L</rejection> to say. Nothing
is persisted.

An empty answer does not say whether the configured refs are missing or the
repository has not been filled yet, as a mirror before its first
synchronisation. While no state is recorded for the repository, C<git
ls-remote> is therefore run a second time, without patterns, and the call
croaks if that shows no name below C<refs/> either:

  repository has no refs yet

Nothing is recorded for such a repository, so its refs are a first
observation when they arrive and C<build_initial> decides about them. Saved
as an empty baseline, the answer would make each of them new instead, tags
that were never built included. C<HEAD> alone, a commit without a branch, is
not a ref of the repository; any name below C<refs/> is one, also outside
branches and tags. A repository that has refs, but none of the configured
ones, yields the empty hash as before and gets its baseline.

The second query is made only for an empty answer without recorded state. Of
that state only the existence of its file is asked here, never its content.
A repository without configured refs is asked for everything by the first
query, which then answers both questions.

The observation gets L</ls_remote_timeout> seconds, connecting and
authenticating included, and its second query what the first has left of
them. After that the process group of the command receives C<TERM> and, a
second later, C<KILL>, and the call croaks with the limit and whatever git
had printed:

  git ls-remote timed out after 60 s

git runs in a process group of its own, so the transport and credential
helpers it starts end with it; a helper that leaves the group is not reached,
but is not waited for either. Standard input is F</dev/null>, and a prompt on
the controlling terminal is not answered: it stops the helper until the limit
ends it.

=head2 poll

  my $reports = $poller->poll;
  my $reports = $poller->poll($observed);

Compares an observation with persisted state, runs accepted changes, merges
the observation into that state, and returns an array reference of generated
reports. Without an
argument it calls L</observe> itself, so an unreadable remote croaks before
anything is run or saved. An observation that L</rejection> refuses croaks at
the same point, with that reason. A caller that has to tell an unusable
observation from a failing run observes first, asks for the rejection and
only then passes the result.

An observation that is handed over is taken as what L</observe> returned.
Whether a repository has refs at all is known to L</observe> alone: an empty
hash that did not come from it is saved as the baseline of a repository
without recorded state, without a second look at the remote.

The state is the last tip of every ref that was ever observed for the
repository, not the last observation. A ref that an observation lacks keeps
its recorded tip and starts no run. Observed again, it is compared with that
tip like any other ref: on the same commit it is no event, on another commit
it is run. Only a ref that was never recorded is new, and with recorded state
it is run whatever C<build_initial> says. Nothing takes a ref out of the
state, be it deleted in the repository or no longer matched by the configured
C<refs>: the state grows with every ref name the repository has had, and
removing its file, see L</rejection>, forgets all of them at once.

=head2 rejection

  my $reason = $poller->rejection($observed);

Returns why an observation must not be polled, or nothing if it may. The one
reason is an observation without refs while tips are recorded:

  remote returned no refs, keeping recorded tips: 2 in state/repositories/<id>.json

Exit status 0 with nothing to show is what C<git ls-remote> gives for a
reachable repository that has none of the configured refs, such as a mirror
before its synchronisation. L</poll> would keep the recorded tips against it
as against any observation that lacks refs; it is refused so that a caller
can report a repository that shows none of them instead of taking it for one
without changes. The number counts every recorded tip, those of refs that are
gone or no longer configured included. Without recorded
tips the same observation is acceptable: it is the baseline of a repository
that has refs, but no matching one yet; L</observe> does not return it for a
repository without any. The path is relative to the store root. Removing that
file is how an operator accepts that the refs are gone for good: the
repository then counts as never read, and its next observation is a first
one. Reads the recorded tips and croaks if they cannot be decoded.

=cut
