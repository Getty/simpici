package App::SimpiCI::Event;
use Moo;

use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use Types::Standard qw( Enum Str );
use namespace::autoclean;

has source => (
  is       => 'ro',
  isa      => Enum[qw( git-poll webhook manual )],
  required => 1,
);

has event => (
  is       => 'ro',
  isa      => Str,
  required => 1,
);

for my $attribute (qw( repository clone_url ref commit )) {
  has $attribute => (
    is       => 'ro',
    isa      => Str,
    required => 1,
  );
}

has payload => (
  is      => 'ro',
  default => sub { {} },
);

sub BUILD {
  my ( $self ) = @_;

  croak __PACKAGE__.' commit must be a full hexadecimal object id'
    unless $self->commit =~ /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/;
  croak __PACKAGE__.' ref must start with refs/'
    unless $self->ref =~ /\Arefs\//;
  croak __PACKAGE__.' repository must not contain NUL'
    if $self->repository =~ /\0/;
}

sub deduplication_key {
  my ( $self ) = @_;

  return sha256_hex(join "\0", map { $self->$_ }
    qw( repository ref commit ));
}

sub as_hash {
  my ( $self ) = @_;

  return {
    source     => $self->source,
    event      => $self->event,
    repository => $self->repository,
    clone_url  => $self->clone_url,
    ref        => $self->ref,
    commit     => $self->commit,
    payload    => { $self->payload->%* },
  };
}

sub as_json {
  my ( $self ) = @_;

  return JSON::MaybeXS->new(canonical => 1, convert_blessed => 1)
    ->encode($self->as_hash);
}

1;
