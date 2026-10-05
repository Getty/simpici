package SimpiCI::Source::GitPoll;
our $VERSION = '0.001';

use Moo;

# ABSTRACT: Poll configured Git refs for SimpiCI

use SimpiCI::Event;
use Digest::SHA qw( sha256_hex );
use SimpiCI::Runner;
use SimpiCI::Store;
use Carp qw( croak );
use Fcntl qw( LOCK_EX );
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
  is        => 'ro',
  isa       => Object,
  predicate => 1,
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

has _json => (is => 'lazy');

sub _build__json { JSON::MaybeXS->new(canonical => 1) }

# The class whose stop signals a query is ended by, and that passes one on.
sub supervisor_class { 'SimpiCI::Runner' }

# What a query may print before it is given up: bytes of refs on standard
# output, bytes on standard error. And how many characters of standard error
# an error repeats.
sub stdout_limit { 16 * 1024 * 1024 }

sub stderr_limit { 1024 * 1024 }

sub message_limit { 1000 }

sub poll {
  my ( $self, $observed ) = @_;

  croak __PACKAGE__.' cannot poll without a runner' unless $self->has_runner;
  my $repository = $self->repository;
  $observed //= $self->observe;
  # From the reading of the state to its writing, one process has it: what
  # another recorded in between would be gone with the write of this one.
  my $lock = $self->_lock;
  my $recorded = $self->_state;
  my $rejection = $self->_rejection($observed, $recorded);
  croak __PACKAGE__.' '.$rejection if defined $rejection;
  my $previous = $recorded ? $recorded->{tips} : {};
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
  # it is no event, and the state never forgets a ref by itself. It only
  # says that this observation lacked it.
  my %tips = ( $previous->%*, $observed->%* );
  my $state = {
    tips   => \%tips,
    absent => [ sort grep { !exists $observed->{$_} } keys %tips ]
  };
  # A baseline is written even if it is empty, anything later only if it
  # differs from what is recorded.
  $self->store->write_json($self->_state_file, $state)
    unless $recorded && $self->_json->encode($recorded) eq $self->_json->encode($state);
  return \@reports;
}

sub rejection {
  my ( $self, $observed ) = @_;

  return $self->_rejection($observed, scalar $self->_state);
}

sub _rejection {
  my ( $self, $observed, $recorded ) = @_;

  # A reachable remote without one usable ref is merged like any other
  # observation and takes no tip away. It is refused all the same while refs
  # are missed that the filter still asks for and the last poll still saw:
  # that tells a repository which lost its refs from one without changes.
  return if $observed->%* || !$recorded;
  my %absent = map { $_ => 1 } $recorded->{absent}->@*;
  my $missed = grep { !$absent{$_} && $self->configured($_) } keys $recorded->{tips}->%*;
  return unless $missed;
  return 'remote returned no refs, configured refs seen at the last poll: '.$missed;
}

sub configured {
  my ( $self, $ref ) = @_;

  my @patterns = ( $self->repository->{refs} // [] )->@*;
  return 1 unless @patterns;
  for my $pattern (@patterns) {
    # A pattern is held against the end of the name, from its start or from
    # a slash. One that is no expression matches nothing, as for git.
    my $glob = $self->_glob($pattern);
    my $tail = eval { qr{(?:\A|/)$glob\z}s } // next;
    return 1 if $ref =~ $tail;
  }
  return 0;
}

# A pattern of git ls-remote as a regular expression: * and ? match a slash
# like any other character, [...] is a set, and a backslash takes the next
# character as it stands.
sub _glob {
  my ( $self, $pattern ) = @_;

  my $class = qr/\[:(?:alnum|alpha|blank|cntrl|digit|graph|lower|print|punct|space|upper|xdigit):\]/;
  my $glob = '';
  while ($pattern =~ m{\G(?: \\(.) | (\*+) | (\?)
      | \[ ([!^]?+) ( \]?+ (?: $class | \\. | [^\]\\] )* ) \] | (.) )}gsx) {
    my ( $escaped, $any, $one, $negated, $set, $literal ) = ( $1, $2, $3, $4, $5, $6 );
    if (defined $set) {
      $set =~ s{($class)|\\(.)|(-)|(.)}{ $1 // ( defined $2 ? quotemeta $2 : $3 // quotemeta $4 ) }gse;
      $glob .= '['.( length $negated ? '^' : '' ).$set.']';
      next;
    }
    $glob .= defined $any ? '.*' : defined $one ? '.' : quotemeta( $escaped // $literal );
  }
  return $glob;
}

sub recorded {
  my ( $self ) = @_;

  my $state = $self->_state // return;
  return {
    $state->%*,
    file  => $self->_state_file,
    bytes => -s $self->_state_path->stringify
  };
}

sub forget {
  my ( $self, $ref ) = @_;

  croak __PACKAGE__.'->forget needs the name of a ref' unless defined $ref && !ref $ref;
  # Nothing is created for a repository that has no state to take a ref from.
  return unless $self->_state_path->is_file;
  # Written by another account, the state and its lock would be files the
  # poller cannot open any more.
  croak __PACKAGE__.' the state in '.$self->_state_file.' belongs to another account'
    unless -o $self->_state_path->stringify;
  my $lock = $self->_lock;
  my $state = $self->_state // return;
  my $commit = delete $state->{tips}{$ref} // return;
  $state->{absent} = [ grep { $_ ne $ref } $state->{absent}->@* ];
  $self->store->write_json($self->_state_file, $state);
  return $commit;
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

# One lock for each repository, beside its state and never removed. It is
# held by whoever reads the state in order to write it.
sub _lock {
  my ( $self ) = @_;

  my $state_path = $self->_state_path;
  $state_path->parent->mkpath;
  my $fh = $state_path->sibling($state_path->basename('.json').'.lock')->opena_raw;
  flock($fh, LOCK_EX) or croak __PACKAGE__.' cannot lock the state: '.$!;
  return $fh;
}

sub _state {
  my ( $self ) = @_;

  my $state_path = $self->_state_path;
  return unless $state_path->is_file;
  my $state = JSON::MaybeXS->new->decode($state_path->slurp_utf8);
  croak __PACKAGE__.' invalid state in '.$self->_state_file unless ref $state eq 'HASH';
  # The form before the state said which refs the last poll lacked: the tips
  # alone, all of them taken as seen. There a name has a commit for its
  # value, so "tips" with an object is never a ref of that form.
  return { tips => $state, absent => [] } unless ref $state->{tips} eq 'HASH';
  my $absent = $state->{absent} // [];
  croak __PACKAGE__.' invalid state in '.$self->_state_file unless ref $absent eq 'ARRAY';
  return { tips => $state->{tips}, absent => $absent };
}

sub observe {
  my ( $self ) = @_;

  # Said without the value: a string in the place of the list would be
  # quoted by Perl where it is used as one.
  my $refs = $self->repository->{refs} // [];
  croak __PACKAGE__.' refs must be a list' unless ref $refs eq 'ARRAY';
  my @patterns = @$refs;
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
  my $said = $self->_said($result->{stderr});
  $said = ': '.$said if length $said;
  # An answer that was cut off is none: nothing of it is taken for refs.
  croak __PACKAGE__.' git ls-remote stopped by signal '.$result->{stopped} if defined $result->{stopped};
  croak __PACKAGE__.' git ls-remote printed more than '.$result->{exceeded}{limit}.' bytes on '
    .$result->{exceeded}{output}.$said if $result->{exceeded};
  croak __PACKAGE__.' git ls-remote timed out after '.$limit.' s'.$said if $result->{timed_out};
  croak __PACKAGE__.' git ls-remote failed'.$said if $result->{status} != 0;
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

# What a command printed on standard error, as one line of text of a length
# a log can take: of a long text the beginning and the end, where git says
# what it gave up for.
sub _said {
  my ( $self, $text ) = @_;

  $text =~ s/\s+/ /g;
  $text =~ s/\A | \z//g;
  $text =~ s/[\x00-\x1f\x7f]/?/g;
  my $limit = $self->message_limit;
  return $text if length $text <= $limit;
  my $head = int($limit / 3);
  return substr($text, 0, $head).' [...] '.substr($text, $head - $limit);
}

sub _capture {
  my ( $self, $timeout, @command ) = @_;

  my $result = $self->_capture_holding_signals($timeout, @command);
  # Passed on with the handlers of the caller in place again: the signal
  # ends this process as it would have without a query, unless the caller
  # has something to finish first.
  $self->supervisor_class->end_by($result->{stopped}) if defined $result->{stopped};
  return $result;
}

sub _capture_holding_signals {
  my ( $self, $timeout, @command ) = @_;

  # The command gets a process group of its own, so a signal that ends this
  # process does not reach it. For as long as it runs, the signals that end
  # a supervisor are therefore held here and end the command first.
  my $stopped;
  my @signals = $self->supervisor_class->stop_signals_in_effect;
  local @SIG{@signals} = ( sub { $stopped //= $_[0] } ) x @signals;
  pipe(my $stdout, my $stdout_writer) or croak __PACKAGE__.' cannot create a pipe: '.$!;
  pipe(my $stderr, my $stderr_writer) or croak __PACKAGE__.' cannot create a pipe: '.$!;
  my $pid = fork;
  croak __PACKAGE__.' cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    # Not the handlers of this process: a signal for the group that arrives
    # before the command is one must end the child, not be noted in it.
    $SIG{$_} = 'DEFAULT' for @signals;
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
  # From this side as well: a signal for the group must find one.
  setpgid($pid, $pid);
  close $stdout_writer;
  close $stderr_writer;

  # Both pipes are emptied while the command runs, and what ends the wait is
  # the process, not the end of its output: a helper may outlive it with a
  # pipe still open. Neither is read beyond its limit.
  my %captured = ( $stdout => '', $stderr => '' );
  my %limit = ( $stdout => $self->stdout_limit, $stderr => $self->stderr_limit );
  my %output = ( $stdout => 'standard output', $stderr => 'standard error' );
  my $open = IO::Select->new($stdout, $stderr);
  my $exceeded;
  my $drain = sub {
    my ( $wait ) = @_;
    return 0 if $exceeded;
    my @ready = $open->can_read($wait);
    for my $handle (@ready) {
      my $read = sysread $handle, $captured{$handle}, 65536, length $captured{$handle};
      if ($read && length $captured{$handle} > $limit{$handle}) {
        substr($captured{$handle}, $limit{$handle}) = '';
        $exceeded //= { output => $output{$handle}, limit => $limit{$handle} };
        next;
      }
      next if $read || ( !defined $read && $!{EINTR} );
      $open->remove($handle);
    }
    return scalar @ready;
  };
  my $deadline = time + $timeout;
  my $timed_out;
  while (waitpid($pid, WNOHANG) == 0) {
    if (defined $stopped || $exceeded || time >= $deadline) {
      kill 'TERM', -$pid;
      # A second for whatever the command has to put away, and not the
      # whole of it once the command is gone.
      my $grace = time + 1;
      my $reaped;
      until ($reaped = waitpid($pid, WNOHANG)) {
        last if time >= $grace;
        sleep 0.05;
      }
      kill 'KILL', -$pid;
      waitpid($pid, 0) unless $reaped;
      $timed_out = 1 unless defined $stopped || $exceeded;
      last;
    }
    $open->count ? $drain->(0.05) : sleep 0.05;
  }
  my $status = $?;
  1 while $drain->(0);
  return {
    status    => $status,
    timed_out => $timed_out,
    stopped   => $stopped,
    exceeded  => $exceeded,
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

  my $poller = SimpiCI::Source::GitPoll->new(store => $store, repository => $repository);
  my $recorded = $poller->recorded;
  my $commit = $poller->forget('refs/heads/gone');

=head1 ATTRIBUTES

=head2 runner

What an accepted change is handed to: an object with a C<run> method that
takes a L<SimpiCI::Event>, such as L<SimpiCI::Runner> or L<SimpiCI::Queue>.
Only L</poll> needs it and croaks without one; the recorded state can be read
and a ref forgotten by a poller that has none.

=head2 ls_remote_timeout

Seconds L</observe> waits for the refs of the repository, a positive integer,
60 by default. An observation that asks twice has them once, for both queries
together. It has nothing to do with the timeout of a run, which belongs to
the runner.

=head1 METHODS

=head2 stdout_limit

Bytes L</observe> reads of what C<git ls-remote> prints on standard output,
16 MiB: the refs of one query. A subclass may return another number.

=head2 stderr_limit

Bytes it reads of standard error, 1 MiB.

=head2 message_limit

Characters of standard error an error of L</observe> repeats, 1000.

=head2 supervisor_class

Class that names the signals a query is ended by and passes one on,
L<SimpiCI::Runner>: its C<stop_signals_in_effect> and its C<end_by>.

=head2 observe

  my $observed = $poller->observe;

Reads the configured remote refs once with C<git ls-remote> and returns a hash
reference of ref names to commit ids. Croaks with the text git printed when
the remote cannot be read, and with C<refs must be a list> if the C<refs> of
the repository are anything but a list or missing; without them every ref is
asked for. A remote that answers without a usable ref yields
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

What the command prints is limited as well: L</stdout_limit> bytes of refs
and L</stderr_limit> bytes on standard error. A command that prints more is
ended in the same way, at once, and the call croaks with the limit it ran
into:

  git ls-remote printed more than 16777216 bytes on standard output

Nothing of an answer that was cut off is returned. In each of these errors
the text of standard error follows as one line of at most L</message_limit>
characters, with a control character shown as C<?>; of a longer text it is
the beginning and the end, with C<[...]> in between, since git says at the
end what it gave up for.

A process group of its own is also out of reach of a signal that ends the
caller. While the command runs, the call therefore holds the signals
L<SimpiCI::Runner/stop_signals> names, those the process does not ignore.
One that arrives ends the command and its group as the limit does, and is
then passed on through L<SimpiCI::Runner/end_by>, with the handlers of the
caller in place again: a process without a handler for it ends by the
signal, and for one that has a handler the call croaks afterwards with

  git ls-remote stopped by signal TERM

A caller that is killed leaves the command behind, without a limit.

=head2 poll

  my $reports = $poller->poll;
  my $reports = $poller->poll($observed);

Compares an observation with persisted state, runs accepted changes, merges
the observation into that state, and returns an array reference of generated
reports. Without an argument it calls L</observe> itself, so an unreadable
remote croaks before anything is run or saved. An observation that
L</rejection> refuses croaks at the same point, with that reason. A caller
that has to tell an unusable observation from a failing run observes first,
asks for the rejection and only then passes the result.

An observation that is handed over is taken as what L</observe> returned.
Whether a repository has refs at all is known to L</observe> alone: an empty
hash that did not come from it is saved as the baseline of a repository
without recorded state, without a second look at the remote.

The state is the last tip of every ref that was ever observed for the
repository, not the last observation. A ref that an observation lacks keeps
its recorded tip and starts no run. Observed again, it is compared with that
tip like any other ref: on the same commit it is no event, on another commit
it is run. Only a ref that was never recorded is new, and with recorded state
it is run whatever C<build_initial> says. A poll takes no ref out of the
state, be it deleted in the repository or no longer matched by the configured
C<refs>: the state grows with every ref name the repository has had. A ref
outside the configured C<refs> is simply not observed, so its tip waits: once
the filter selects it again, it is run if it moved in between and not
otherwise. L</forget> takes one ref out, and removing the file of the state
all of them at once. See L</STATE>.

From the reading of the state to its writing the poll holds the lock of the
repository, the runs in between included. A second poll of the same
repository, from another process on the same store, waits for the first and
then compares with what that one recorded, so neither loses the other's tips
and no change is run twice. In local mode this is the length of a build. The
observation is made before the lock is asked for: a poll that had to wait
works with what the remote showed before it waited.

The state is written only if it differs from what is recorded, the first
time also when it is empty.

=head2 rejection

  my $reason = $poller->rejection($observed);

Returns why an observation must not be polled, or nothing if it may. The
one reason is an observation without refs while refs are missed:

  remote returned no refs, configured refs seen at the last poll: 2

Exit status 0 with nothing to show is what C<git ls-remote> gives for a
reachable repository that has none of the configured refs, such as a mirror
before its synchronisation.

The refusal protects nothing: L</poll> keeps the recorded tips against an
empty observation as against any other that lacks refs. It is a signal, so
that a caller can report a repository that lost all its refs at once instead
of taking it for one without changes. A refused observation changes nothing,
so the reason is given again until a ref is back or the missed ones are
forgotten.

The number counts the refs that are missed: those the last accepted
observation showed and that L</configured> still selects. A ref that was
absent before, or that the filter no longer asks for, is not missed. If none
is, the empty observation is what the filter gives and is acceptable. So is
one without recorded state: it is the baseline of a repository that has
refs, but no matching one yet; L</observe> does not return it for a
repository without any.

Reads the recorded state and croaks if it cannot be decoded.

=head2 configured

  my $selected = $poller->configured('refs/heads/main');

True if the configured C<refs> select the name, by the rule C<git ls-remote>
applies to its patterns: a pattern is held against the end of the name,
beginning at its start or after a slash, C<*> and C<?> also match a slash,
C<[...]> is a set of characters and a backslash takes the next character as
it stands. C<refs/tags/*> therefore selects every tag, and C<main> selects
C<refs/heads/main> as well as C<refs/tags/main>. Without configured refs
every name is selected. Nothing is read for the answer.

=head2 recorded

  my $recorded = $poller->recorded;

Returns what is recorded for the repository, or nothing if it was never
polled: a hash reference with the C<tips> and the C<absent> list of
L</STATE>, the path of its C<file> relative to the store root and the size of
that file in C<bytes>. Taken without the lock, since the file is replaced as
a whole. Croaks if the state cannot be decoded.

=head2 forget

  my $commit = $poller->forget($ref);

Takes one ref out of the recorded state and returns the commit that was
recorded for it, or nothing if the ref is not recorded or the repository has
no state. The name is taken as it stands, not as a pattern. It holds the
lock of L</poll> from reading the state to writing it and waits for a poll
that is running, so the poll cannot write the ref back.

A ref that is forgotten was never recorded as far as the next poll can tell.
If the remote still shows it and C<refs> selects it, it is new and run,
whatever C<build_initial> says: forgetting a ref does not make the repository
one that was never read, not even when it was the last ref of the state. A
ref the remote no longer has leaves the state and nothing else happens; if
it ever returns, it is new.

Croaks if the state file belongs to another account than the one that calls:
the file it would write, and a lock it would create, could not be opened by
the poller any more. A repository without state is left without one, and no
directory is made for it.

=head1 STATE

The state of a repository is one JSON file below the store root,

  state/repositories/<id>.json

where C<id> is the SHA-256 of name, a NUL byte and clone URL of the
repository. Another name or another clone URL is another repository with a
state of its own.

  {
    "absent": ["refs/tags/v1"],
    "tips": {
      "refs/heads/main": "6d0c...",
      "refs/tags/v1": "0b1e..."
    }
  }

C<tips> holds the last tip of every ref that was recorded and not forgotten.
C<absent> lists, in order, those of them that the last accepted observation
did not show, because they are gone from the repository or because C<refs>
did not ask for them. It is what L</rejection> counts by and what tells an
operator which entries only take up room.

A file that holds a flat hash of ref names to commits, the form before
C<absent> existed, is read as tips that were all seen, and is replaced by
the form above when the state next changes. Anything that is no JSON object
croaks with C<invalid state> and the path.

Beside it lies C<state/repositories/E<lt>idE<gt>.lock>, the empty file that
L</poll> and L</forget> lock. It is created with the first poll and never
removed; removing the state file leaves it, and it means nothing by itself.

=cut
