package SimpiCI::Source::GitPoll;

use Moo;

# ABSTRACT: Poll configured Git refs for SimpiCI

use SimpiCI::Event;
use Digest::SHA qw( sha256_hex );
use SimpiCI::Runner;
use SimpiCI::Store;
use Carp qw( croak );
use IPC::Open3 qw( open3 );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Symbol qw( gensym );
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
  $self->store->write_json($self->_state_file, $observed);
  return \@reports;
}

sub rejection {
  my ( $self, $observed ) = @_;

  # A reachable remote without one usable ref says nothing about the recorded
  # tips: saved, it would make every one of them new once they are back.
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

sub _recorded {
  my ( $self ) = @_;

  my $state_path = $self->store->root->child($self->_state_file);
  return unless $state_path->is_file;
  return JSON::MaybeXS->new->decode($state_path->slurp_utf8);
}

sub observe {
  my ( $self ) = @_;

  my $repository = $self->repository;
  my @refs = $repository->{refs}->@*;
  my $stderr = gensym;
  my $pid = open3(undef, my $stdout, $stderr,
    'git', 'ls-remote', '--', $repository->{clone_url}, @refs);
  my $output = do { local $/; <$stdout> // '' };
  my $error = do { local $/; <$stderr> // '' };
  waitpid($pid, 0);
  croak __PACKAGE__.' git ls-remote failed: '.$error if $? != 0;
  my %observed;
  for my $line (split /\n/, $output) {
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

=head1 METHODS

=head2 observe

  my $observed = $poller->observe;

Reads the configured remote refs once with C<git ls-remote> and returns a hash
reference of ref names to commit ids. Croaks with the text git printed when
the remote cannot be read. A remote that answers without a usable ref yields
an empty hash; whether that is acceptable is for L</rejection> to say. Nothing
is persisted, and the call has no timeout of its own.

=head2 poll

  my $reports = $poller->poll;
  my $reports = $poller->poll($observed);

Compares an observation with persisted state, runs accepted changes, saves the
observation, and returns an array reference of generated reports. Without an
argument it calls L</observe> itself, so an unreadable remote croaks before
anything is run or saved. An observation that L</rejection> refuses croaks at
the same point, with that reason. A caller that has to tell an unusable
observation from a failing run observes first, asks for the rejection and
only then passes the result.

=head2 rejection

  my $reason = $poller->rejection($observed);

Returns why an observation must not replace the recorded tips, or nothing if
it may. The one reason is an observation without refs while tips are
recorded:

  remote returned no refs, keeping recorded tips: 2 in state/repositories/<id>.json

Exit status 0 with nothing to show is what C<git ls-remote> gives for a
reachable repository that has none of the configured refs, such as a mirror
before its synchronisation. Saved, it would turn every recorded tip into a
new one on its return, tags that were never built included. Without recorded
tips the same observation is acceptable: it is the baseline of a repository
that has no matching ref yet. The path is relative to the store root; removing
that file is how an operator accepts that the refs are gone for good. Reads
the recorded tips and croaks if they cannot be decoded.

=cut
