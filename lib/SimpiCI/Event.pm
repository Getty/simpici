package SimpiCI::Event;
our $VERSION = '0.001';

use Moo;

# ABSTRACT: Validated normalized repository event

use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use Types::Standard qw( Enum Str );
use namespace::autoclean;

# Where an event can come from, and the one place that says so.
sub sources { qw( git-poll webhook manual ) }

has source => (
  is       => 'ro',
  isa      => Enum[ __PACKAGE__->sources ],
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
  my $rejection = $self->ref_rejection($self->ref)
    // $self->clone_url_rejection($self->clone_url);
  croak __PACKAGE__.' '.$rejection if defined $rejection;
  for my $field (qw( repository event )) {
    my $reason = $self->name_rejection($self->$field) // next;
    croak __PACKAGE__.' '.$field.' '.$reason;
  }
}

# The rule for the ref of an event: a full name below refs/, as git writes
# one. Asked by the dispatcher as well, for the exact refs of a grant.
sub ref_rejection {
  my ( $self, $ref ) = @_;

  return 'ref must start with refs/' unless $ref =~ /\Arefs\//;
  return 'ref is not canonical'
    if $ref =~ /[\x00-\x20\x7f~^:?*\[\\]/
      || $ref =~ /\.\.|@\{|\/\/|\/\.|\.lock(?:\/|$)|[.\/]$/;
  return;
}

# The rule for the two fields that are free text, the name of the repository
# and the name of the event: one line of it. A NUL would end the repository
# in the deduplication key, a line end would begin a line of its own where
# the name is logged, and none of them can stand in the event file of a job
# as it is. Like the clone URL rule it returns its reason and never the
# value.
sub name_rejection {
  my ( $self, $name ) = @_;

  return 'must not contain control characters' if $name =~ /[\x00-\x1f\x7f]/;
  return;
}

# The schemes of a clone URL, and the one place that names them. git knows
# more, and takes every scheme it does not know for the name of a program.
sub clone_url_schemes { qw( https http ssh file ) }

# The entry to the clone URL rule. It returns its reason instead of croaking,
# because a backtrace would carry the URL it was called with.
sub clone_url_rejection {
  my ( $self, $clone_url ) = @_;

  return 'clone URL must not contain whitespace or control characters'
    if $clone_url =~ /[\x00-\x20\x7f]/;
  # git reads it as an option wherever nothing ends its options.
  return 'clone URL must not begin with "-"' if $clone_url =~ /\A-/;
  return $self->_form_rejection unless $self->_form_accepted($clone_url);
  my ( $before, $user ) = $self->_user_part($clone_url);
  return unless defined $before;
  return $self->_user_part_rejection($before, $user);
}

sub clone_url_without_credentials {
  my ( $self, $clone_url ) = @_;

  my ( $before, $user, $after ) = $self->_user_part($clone_url);
  return $clone_url
    unless defined $before && defined $self->clone_url_rejection($clone_url);
  return $before.$after;
}

# The forms of a clone URL, in the order git tells them apart. What git
# takes for the name of a remote helper is none of them: "<name>::" always,
# and "<name>://" for every scheme but its own, compared as it is written,
# so that "HTTPS://" is a helper as well. A helper is a program git starts.
sub _form_accepted {
  my ( $self, $clone_url ) = @_;

  my $name = qr/[A-Za-z][A-Za-z0-9+.-]*/;
  return scalar grep { $_ eq $1 } $self->clone_url_schemes if $clone_url =~ m{\A($name)://};
  return 0 if $clone_url =~ m{\A${name}::};
  # An absolute path. A relative one would be read from the directory git
  # happens to be run in: another one for the poller than for the checkout.
  return 1 if $clone_url =~ m{\A/};
  # A host and a path, with the colon ahead of the first "/".
  return $clone_url =~ m{\A[^/:]+:} ? 1 : 0;
}

sub _form_rejection {
  my ( $self ) = @_;

  my @schemes = $self->clone_url_schemes;
  my $last = pop @schemes;
  return 'clone URL must be a URL of the scheme '.join(' or ', join(', ', @schemes) || (), $last)
    .', an SSH address of the form [user@]host:path or an absolute path';
}

# The one place for what the user part of a clone URL is: returns what stands
# before it, the user part and what follows its "@", or nothing. With a
# scheme, which git lets a "<helper>::" precede, it ends at the last "@" ahead
# of the first "/", so that neither a port nor a path is taken for it.
# Without a scheme only user:password@host:path counts; git reads the host
# "user" there, but it is a password that was written down. It is asked of
# every clone URL, of one whose form is refused as well: such a URL is shown
# without its user part too.
sub _user_part {
  my ( $self, $clone_url ) = @_;

  my $scheme = qr/[a-z][a-z0-9+.-]*/i;
  return $clone_url =~ m{\A((?:${scheme}::)?${scheme}://)([^/]*)@(.*)\z}s ? ( $1, $2, $3 ) : ()
    if $clone_url =~ m{\A(?:${scheme}::)?${scheme}://};
  return $clone_url =~ m{\A([^/:@]*:[^/@]*)@([^/:@]*:.*)\z}s ? ( '', $1, $2 ) : ();
}

# Asked only of a clone URL in one of the accepted forms.
sub _user_part_rejection {
  my ( $self, $before, $user ) = @_;

  return 'clone URL must not contain credentials; provide them through a Git'
    .' credential helper of the account that runs git'
    if $before =~ m{\Ahttps?://\z};
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
canonical, the clone URL passes L</clone_url_rejection> and neither the
repository nor the event contains a control character, see
L</name_rejection>. The source is one of C<git-poll>, C<webhook> and
C<manual>. That holds for an event of every source: one the poller makes,
the file given to C<simpici --event> and the entry of a queue that a worker
claims.

=head1 CLONE URLS

A clone URL is one of these forms and nothing else:

  https://host[:port]/path
  http://host[:port]/path
  ssh://[user@]host[:port]/path
  file:///path
  [user@]host:path
  /path

The first four are URLs with one of the schemes L</clone_url_schemes>
returns, written in lower case as git knows them. C<[user@]host:path> is the
address git reads as SSH: a host, with a colon ahead of the first C</>.
C</path> is a repository on the same machine and has to be absolute, since a
relative path is read from the directory git happens to be run in, which is
another one for the poller than for the checkout.

Only the form is looked at. Whether the host exists, the port is a number
and the path names a repository shows when git reads the URL. C<http://> is
accepted as C<https://> is and is neither encrypted nor authenticated: for a
forge inside a network that is trusted.

This is a list of what is accepted, not of what is refused, because git
takes whatever it does not know for the name of a program. A URL of the form
C<E<lt>nameE<gt>::E<lt>addressE<gt>>, and one with a scheme
C<E<lt>nameE<gt>://> that is none of git's own, names a remote helper: git
starts C<git-remote-E<lt>nameE<gt>> for it, and the helper C<ext> runs the
command the address gives. git compares a scheme as it is written, so
C<HTTPS://> and C<SSH://> are helpers as well, and so is
C<persistent-https://>, where a lone token ahead of the host would not have
been taken for credentials. Not accepted either are the transports of git
that are none of the four: C<git://>, which is neither encrypted nor
authenticated, C<git+ssh://> and C<ssh+git://>, for which there is
C<ssh://>, and C<ftp://> and C<ftps://>.

Besides the form, a clone URL contains no whitespace and no control
character, does not begin with C<->, which git reads as an option wherever
nothing ends its options, and carries nothing that authenticates: an event
takes its clone URL into the queue, the private event file and the
environment of every job.

The user part of a URL with a scheme is what stands between C<://> and the
last C<@> ahead of the first C</>; a port, an IPv6 address in brackets and a
C<:> or C<@> in the path are not taken for it. An C<http://> or C<https://>
URL has none at all, with or without a password, since a lone token is
written the same way; see C<gitcredentials(7)> for how git is given
credentials instead. The user part of an C<ssh://> or C<file://> URL is a
user name and contains no C<:>, be the password behind it empty or not, and
no C<%3A>: git decodes an C<ssh://> URL before it names the host to ssh, and
ssh takes no password from there at all. C<user:password@host:path> without
a scheme is refused as well, although git reads the host C<user> and the
path C<password@host:path> in that: what was written down is a password.
This last form is recognised by its shape, so a host followed by a path with
an C<@> and a later C<:> ahead of its first C</>, as in C<host:a@b:c>, is
refused with it; write such an address as C<ssh://host/...>.

C<git@host:path>, C<ssh://git@host/path> and C<ssh://git@host:2222/path>
are valid. Three ways to write a password down are not recognised, and the
list of forms changes nothing about them. A password that contains a C</>,
as in C<ssh://user:pass/word@host/path>: the user part ends at the first
C</>, as it does for git, which looks for a host C<user> there.
C<user:password@host/path> without a scheme and without a second C<:>, which
has the form of the host C<user> with a path, and is read by git as that.
And a password in the path or the query of a URL, which is sent to the host
as it stands. Such a clone URL is handled like any other: it stands in the
line C<simpicid> writes for a repository it could not poll, and a URL git
can read travels with every event.

=head1 METHODS

=head2 clone_url_rejection

  my $reason = SimpiCI::Event->clone_url_rejection($clone_url);

Returns why a clone URL is not accepted, or nothing if it is one of
L</CLONE URLS>. This is the rule the constructor applies, and the one
C<simpicid> applies to every configured repository before it polls. There
are five reasons, asked in this order:

  clone URL must not contain whitespace or control characters
  clone URL must not begin with "-"
  clone URL must be a URL of the scheme https, http, ssh or file, an SSH address of the form [user@]host:path or an absolute path
  clone URL must not contain credentials; provide them through a Git credential helper of the account that runs git
  clone URL must not contain a password; a user name alone is accepted, and SSH authenticates with a key of the account that runs git

A reason never contains the URL or a part of it. The third is given for
every form that is none of the accepted ones, a password in it or not. The
fourth is given for an C<http://> or C<https://> URL with a user part, the
fifth for a C<:> or C<%3A> in the user part of an C<ssh://> or C<file://>
URL and for C<user:password@host:path>.

=head2 clone_url_schemes

  my @schemes = SimpiCI::Event->clone_url_schemes;

Returns the schemes of a clone URL: C<https>, C<http>, C<ssh> and C<file>.
The one place that names them; the third reason of L</clone_url_rejection>
is made from it. A subclass that returns another list accepts other URLs,
and has to know what git does with them.

=head2 clone_url_without_credentials

  my $shown = SimpiCI::Event->clone_url_without_credentials($clone_url);

Returns a clone URL that L</clone_url_rejection> refuses without its user
part, if it has one, and any other URL as it is:
C<ssh://user:password@host/path> becomes C<ssh://host/path>,
C<persistent-https://token@host/path> becomes
C<persistent-https://host/path>, C<ssh://git@host/path> stays. It is for a
log line that names a URL which did not pass the rule.

=head2 name_rejection

  my $reason = SimpiCI::Event->name_rejection($name);

Returns why a string is not accepted as the C<repository> or the C<event>
of an event, or nothing if it is. There is one reason, and it never contains
the string:

  must not contain control characters

A control character is one below C<0x20>, a tab and a line end among them,
or C<0x7f>. Both fields are free text otherwise, a space, a quote and
characters beyond ASCII included, and may be empty. They are written into
the event file of every job and named in the lines of the operator's log;
the repository is also a part of L</deduplication_key>, where a NUL would
end it. The constructor croaks with the field ahead of the reason,

  SimpiCI::Event repository must not contain control characters
  SimpiCI::Event event must not contain control characters

and C<simpicid> applies the rule to the name of every configured repository
before it polls, see L<SimpiCI::App::Eventd/check_repositories>.

=head2 ref_rejection

  my $reason = SimpiCI::Event->ref_rejection($ref);

Returns why a string is not accepted as the C<ref> of an event, or nothing
if it is. It never contains the string:

  ref must start with refs/
  ref is not canonical

A ref is a full name below C<refs/> without what git allows in no ref name:
a space or a control character, C<~ ^ : ? * [> or a backslash, C<..>, C<@{>,
C<//>, a component that begins with a dot or ends in C<.lock>, and a dot or
a slash at its end. The constructor croaks with these words, and
L<SimpiCI::Dispatcher> holds the exact refs of a secret grant against the
same rule: a grant for a ref no event can carry would apply to no run.

=head2 sources

Returns the sources an event can have, C<git-poll>, C<webhook> and
C<manual>. The constructor accepts no other, and a secret grant can name no
other in its C<sources>.

=head2 deduplication_key

Returns a SHA-256 key derived from repository, ref, and commit.

=head2 as_hash

Returns a detached copy of the normalized event data.

=head2 as_json

Returns the event as deterministic JSON.

=cut
