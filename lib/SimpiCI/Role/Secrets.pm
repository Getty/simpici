package SimpiCI::Role::Secrets;

use Moo::Role;

# ABSTRACT: What a secret may be and how its value is redacted

use namespace::autoclean;

sub redaction_marker { '[REDACTED]' }

sub secret_name_valid {
  my ( $self, $name ) = @_;
  return defined $name && !ref $name
    && $name =~ /\A(?:CICD_[A-Z0-9_]+|[A-Z][A-Z0-9_]*_TOKEN)\z/ ? 1 : 0;
}

# One line of an environment file holds it: nothing that would end the line
# or begin another one.
sub secret_value_valid {
  my ( $self, $value ) = @_;
  return defined $value && !ref $value && length $value && $value !~ /[\r\n\0]/ ? 1 : 0;
}

sub secret_values {
  my ( $self, $secrets ) = @_;
  my %seen;
  return grep { !$seen{$_}++ } $self->_secret_strings($secrets);
}

sub _secret_strings {
  my ( $self, $secrets ) = @_;
  return ref $secrets eq 'HASH' ? map { $self->_secret_strings($_) } values %$secrets
    : ref $secrets eq 'ARRAY' ? map { $self->_secret_strings($_) } @$secrets
    : defined $secrets && !ref $secrets && length $secrets ? $secrets
    : ();
}

# Every occurrence of every value is marked in the text as it arrived, and
# what is marked is replaced afterwards. Replacing one value after the other
# would leave the rest of a value whose beginning or end had already become
# a marker, in whichever order the values were taken.
#
# Text and values are searched as UTF-8 bytes. An encoded value begins and
# ends where a character does, so the occurrences are the same, but a
# position in a string of characters costs a walk through it: a log of
# megabytes with a few hundred occurrences would outlast the request.
sub redact {
  my ( $self, $text, $secrets ) = @_;
  return $text unless defined $text && length $text;
  my $bytes = $text;
  utf8::encode($bytes);
  my $mask = "\0" x length $bytes;
  my $found = 0;
  for my $value ($self->secret_values($secrets)) {
    utf8::encode($value);
    my $length = length $value;
    my ( $at, $marked ) = ( -1, 0 );
    while (( $at = index($bytes, $value, $at + 1) ) >= 0) {
      # An occurrence may begin inside the one before it: only its rest is new.
      my $from = $at > $marked ? $at : $marked;
      $marked = $at + $length;
      substr($mask, $from, $marked - $from) = "\1" x ( $marked - $from );
      $found = 1;
    }
  }
  return $text unless $found;
  my $marker = $self->redaction_marker;
  utf8::encode($marker);
  my ( $redacted, $copied ) = ( '', 0 );
  while ($mask =~ /\x01+/g) {
    $redacted .= substr($bytes, $copied, $-[0] - $copied).$marker;
    $copied = $+[0];
  }
  $redacted .= substr($bytes, $copied);
  utf8::decode($redacted);
  return $redacted;
}

1;

=head1 NAME

SimpiCI::Role::Secrets - what a secret may be and how its value is redacted

=head1 SYNOPSIS

  package SimpiCI::Worker;
  use Moo;
  with 'SimpiCI::Role::Secrets';

  my $public = $self->redact($log, $claim->{secrets});

=head1 DESCRIPTION

The rules L<SimpiCI::Dispatcher> and L<SimpiCI::Worker> share about the
secrets of a claim, so that both redact the same way and the worker writes
only what the dispatcher would have granted. No method needs an object: each
can be called on the class.

=head1 METHODS

=head2 redact

  my $redacted = $self->redact($text, $secrets);

Returns C<$text> with every occurrence of every value of L</secret_values>
replaced by L</redaction_marker>.

All occurrences are found in the text as it was passed, and only then
replaced, so the result does not depend on the order of the values. Nothing
of a value stays where two of them overlap: a value that begins another one,
a value that ends where another one begins (C<abcd> and C<cdef> in
C<abcdef>), a value that overlaps itself (C<aa> in C<aaa>). Values that
overlap or stand side by side become one marker.

Only literal occurrences are found. A value a job prints encoded, split or
otherwise changed is not recognised.

=head2 secret_values

  my @values = $self->secret_values($secrets);

Returns each distinct nonempty string found in C<$secrets>, whatever its
shape: the values of a hash and the elements of a list are followed to any
depth. Undefined values, empty strings and other references are left out, so
that a claim of an unexpected shape cannot break the redaction: an empty
string as a value would match between any two characters.

=head2 redaction_marker

Returns C<[REDACTED]>, the text an occurrence is replaced by.

=head2 secret_name_valid

  croak 'invalid secret name' unless $self->secret_name_valid($name);

True for a string of the form C<CICD_E<lt>NAMEE<gt>> or
C<E<lt>NAMEE<gt>_TOKEN> in capitals, digits and underscores: the names a
grant may carry. Which of them the executor reserves for itself is a rule of
L<SimpiCI::Dispatcher/reserved_secret_names>.

=head2 secret_value_valid

  croak 'invalid secret value' unless $self->secret_value_valid($value);

True for a nonempty string without a line end, carriage return or NUL: a
value that is one line of an environment file. False for an undefined value
and for a reference.

=cut
