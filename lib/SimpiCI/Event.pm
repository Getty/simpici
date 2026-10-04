package SimpiCI::Event;

use Moo;

# ABSTRACT: Validated normalized repository event

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
  croak __PACKAGE__.' ref is not canonical'
    if $self->ref =~ /[\x00-\x20\x7f~^:?*\[\\]/
      || $self->ref =~ /\.\.|@\{|\/\/|\/\.|\.lock(?:\/|$)|[.\/]$/;
  my $rejection = $self->clone_url_rejection($self->clone_url);
  croak __PACKAGE__.' '.$rejection if defined $rejection;
  croak __PACKAGE__.' repository must not contain NUL'
    if $self->repository =~ /\0/;
}

# The one place for the clone URL rule. It returns its reason instead of
# croaking, because a backtrace would carry the URL it was called with.
sub clone_url_rejection {
  my ( $self, $clone_url ) = @_;

  return 'clone URL must not contain whitespace or control characters'
    if $clone_url =~ /[\x00-\x20\x7f]/;
  return 'clone URL must not contain credentials; provide them through a Git'
    .' credential helper of the account that runs git'
    if $clone_url =~ m{\Ahttps?://[^/]*@}i;
  return;
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

=head1 NAME

SimpiCI::Event - validated normalized repository event

=head1 SYNOPSIS

  my $event = SimpiCI::Event->new(
    source     => 'manual',
    event      => 'push',
    repository => 'owner/project',
    clone_url  => 'https://example/owner/project.git',
    ref        => 'refs/heads/main',
    commit     => $full_object_id
  );

=head1 DESCRIPTION

Construction croaks unless the commit is a full object id, the ref is
canonical and the clone URL passes L</clone_url_rejection>.

=head1 METHODS

=head2 clone_url_rejection

  my $reason = SimpiCI::Event->clone_url_rejection($clone_url);

Returns why a clone URL is not accepted, or nothing if it is. This is the rule
the constructor applies, and the one C<simpicid> applies to every configured
repository before it polls. There are two reasons:

  clone URL must not contain whitespace or control characters
  clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git

The second is given for an C<http://> or C<https://> URL with a user part
before the host, with or without a password: an event carries its clone URL
into the queue, the private event file and the job environment. See
C<gitcredentials(7)> for how git is given credentials instead. No other form
is judged: C<git@host:path> and C<ssh://git@host/path> stay valid. A reason
never contains the URL or a part of it.

=head2 deduplication_key

Returns a SHA-256 key derived from repository, ref, and commit.

=head2 as_hash

Returns a detached copy of the normalized event data.

=head2 as_json

Returns the event as deterministic JSON.

=cut
