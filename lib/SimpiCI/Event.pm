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

# The entry to the clone URL rule. It returns its reason instead of croaking,
# because a backtrace would carry the URL it was called with.
sub clone_url_rejection {
  my ( $self, $clone_url ) = @_;

  return 'clone URL must not contain whitespace or control characters'
    if $clone_url =~ /[\x00-\x20\x7f]/;
  my ( $before, $user ) = $self->_user_part($clone_url);
  return unless defined $before;
  return $self->_user_part_rejection($before, $user);
}

sub clone_url_without_credentials {
  my ( $self, $clone_url ) = @_;

  my ( $before, $user, $after ) = $self->_user_part($clone_url);
  return $clone_url
    unless defined $before && defined $self->_user_part_rejection($before, $user);
  return $before.$after;
}

# The one place for what the user part of a clone URL is: returns what stands
# before it, the user part and what follows its "@", or nothing. With a
# scheme, which git lets a "<helper>::" precede, it ends at the last "@" ahead
# of the first "/", so that neither a port nor a path is taken for it.
# Without a scheme only user:password@host:path counts; git reads the host
# "user" there, but it is a password that was written down.
sub _user_part {
  my ( $self, $clone_url ) = @_;

  my $scheme = qr/[a-z][a-z0-9+.-]*/i;
  return $clone_url =~ m{\A((?:${scheme}::)?${scheme}://)([^/]*)@(.*)\z}s ? ( $1, $2, $3 ) : ()
    if $clone_url =~ m{\A(?:${scheme}::)?${scheme}://};
  return $clone_url =~ m{\A([^/:@]*:[^/@]*)@([^/:@]*:.*)\z}s ? ( '', $1, $2 ) : ();
}

sub _user_part_rejection {
  my ( $self, $before, $user ) = @_;

  return 'clone URL must not contain credentials; provide them through a Git'
    .' credential helper of the account that runs git'
    if $before =~ m{(?:\A|::)https?://\z}i;
  # git decodes an ssh:// URL before it names the host to ssh, so an encoded
  # colon is a colon there.
  return 'clone URL must not contain a password; a user name alone is accepted,'
    .' and SSH authenticates with a key of the account that runs git'
    if $user =~ /:|%3a/i;
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
repository before it polls. There are three reasons:

  clone URL must not contain whitespace or control characters
  clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git
  clone URL must not contain a password; a user name alone is accepted, and SSH authenticates with a key of the account that runs git

An event carries its clone URL into the queue, the private event file and the
job environment, so nothing that authenticates may stand in it. A reason never
contains the URL or a part of it.

The user part of a URL with a scheme is what stands between C<://> and the
last C<@> ahead of the first C</>; a port, an IPv6 address in brackets and a
C<:> or C<@> in the path are not taken for it. The scheme may follow the
C<E<lt>helperE<gt>::> by which git names a remote helper.

The second reason is given for C<http://> and C<https://> with any user part,
with or without a password, since a lone token is written the same way. See
C<gitcredentials(7)> for how git is given credentials instead.

The third is given for every other scheme, such as C<ssh://>, C<git+ssh://>,
C<ftp://> and C<ftps://>, if the user part contains a C<:>, be the password
behind it empty or not, or a C<%3A>: git decodes an C<ssh://> URL before it
names the host to ssh, and ssh takes no password from there at all. It is
also given for C<user:password@host:path> without a scheme, although git
reads the host C<user> and the path C<password@host:path> in that: what was
written down is a password. This last form is recognised by its shape, so a
host followed by a path with an C<@> and a later C<:> ahead of its first
C</>, as in C<host:a@b:c>, is refused with it; write such an address as
C<ssh://host/...>.

C<git@host:path>, C<ssh://git@host/path> and C<ssh://git@host:2222/path>
stay valid. A password that contains a C</> is not recognised in either form,
and neither is one in a path or a query, nor C<user:password@host/path>
without a scheme and without a second C<:>, which has the shape of a host
with a path.

=head2 clone_url_without_credentials

  my $shown = SimpiCI::Event->clone_url_without_credentials($clone_url);

Returns the clone URL without the user part L</clone_url_rejection> refuses
it for, and any other URL as it is: C<ssh://user:password@host/path> becomes
C<ssh://host/path>, C<ssh://git@host/path> stays. It is for a log line that
names a URL which did not pass the rule.

=head2 deduplication_key

Returns a SHA-256 key derived from repository, ref, and commit.

=head2 as_hash

Returns a detached copy of the normalized event data.

=head2 as_json

Returns the event as deterministic JSON.

=cut
