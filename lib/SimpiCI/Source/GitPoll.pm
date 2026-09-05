package SimpiCI::Source::GitPoll;

use Moo;

# ABSTRACT: Poll configured Git refs for SimpiCI

use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;
use Carp qw( croak );
use IPC::Open3 qw( open3 );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Symbol qw( gensym );
use Types::Standard qw( HashRef InstanceOf );
use namespace::autoclean;

has store => (
  is       => 'ro',
  isa      => InstanceOf['SimpiCI::Store'],
  required => 1,
);

has runner => (
  is       => 'ro',
  isa      => InstanceOf['SimpiCI::Runner'],
  required => 1,
);

has repository => (
  is       => 'ro',
  isa      => HashRef,
  required => 1,
);

sub poll {
  my ( $self ) = @_;

  my $repository = $self->repository;
  my $state_path = $self->store->root->child(
    'state', 'repositories', $repository->{name}.'.json'
  );
  my $previous = $state_path->is_file
    ? JSON::MaybeXS->new->decode($state_path->slurp_utf8) : {};
  my $observed = $self->_ls_remote;
  my @reports;

  for my $ref (sort keys $observed->%*) {
    my $commit = $observed->{$ref};
    my $old = $previous->{$ref};
    next if defined $old && $old eq $commit;
    next unless defined $old || $repository->{build_initial};
    push @reports, $self->runner->run(SimpiCI::Event->new(
      source     => 'git-poll',
      event      => 'push',
      repository => $repository->{name},
      clone_url  => $repository->{clone_url},
      ref        => $ref,
      commit     => $commit
    ));
  }
  $self->store->write_json(
    'state/repositories/'.$repository->{name}.'.json', $observed
  );
  return \@reports;
}

sub _ls_remote {
  my ( $self ) = @_;

  my $repository = $self->repository;
  my @refs = $repository->{refs}->@*;
  my $stderr = gensym;
  my $pid = open3(undef, my $stdout, $stderr,
    'git', 'ls-remote', $repository->{clone_url}, @refs);
  my $output = do { local $/; <$stdout> // '' };
  my $error = do { local $/; <$stderr> // '' };
  waitpid($pid, 0);
  croak __PACKAGE__.' git ls-remote failed: '.$error if $? != 0;
  my %observed;
  for my $line (split /\n/, $output) {
    my ( $commit, $ref ) = split /\s+/, $line, 2;
    next unless defined $ref && $commit =~ /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/;
    $observed{$ref} = $commit;
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

=head2 poll

Reads the configured remote refs once, compares them with persisted state,
runs accepted changes, saves the new observation, and returns an array reference
of generated reports.

=cut
