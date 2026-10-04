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

# Why a value is none, in words that say nothing of it, or nothing. One line
# of an environment file holds a value: nothing that would end the line or
# begin another one. And redact has to tell it from its own marker.
sub secret_value_rejection {
  my ( $self, $value ) = @_;
  return 'must be one nonempty line'
    unless defined $value && !ref $value && length $value && $value !~ /[\r\n\0]/;
  return 'must not contain '.$self->redaction_marker.', the marker of a redacted value'
    if index($value, $self->redaction_marker) >= 0;
  return;
}

sub secret_value_valid {
  my ( $self, $value ) = @_;
  return defined $self->secret_value_rejection($value) ? 0 : 1;
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
#
# A marker that stands in the text is no text of the job: the worker put it
# there before the dispatcher redacts the same log again. A value that would
# be found in it, or across one of its ends, is therefore no occurrence.
# Replacing it would show in the second pass what the first one hid: with
# the value RED, "[REDACTED]" would become "[[REDACTED]ACTED]". The markers
# are found first, from the left and one after the other, which finds all of
# them because the marker does not overlap itself.
sub redact {
  my ( $self, $text, $secrets ) = @_;
  return $text unless defined $text && length $text;
  my $bytes = $text;
  utf8::encode($bytes);
  my $marker = $self->redaction_marker;
  utf8::encode($marker);
  my $marker_length = length $marker;
  my @markers;
  for (my $at = index($bytes, $marker); $at >= 0; $at = index($bytes, $marker, $at + $marker_length)) {
    push @markers, $at;
  }
  my $mask = "\0" x length $bytes;
  my $found = 0;
  for my $value ($self->secret_values($secrets)) {
    utf8::encode($value);
    my $length = length $value;
    # A value that holds the marker is one no grant carries. If one arrives
    # all the same, it is found wherever it stands rather than never.
    my $guarded = @markers && index($value, $marker) < 0;
    my ( $at, $marked, $next ) = ( -1, 0, 0 );
    while (( $at = index($bytes, $value, $at + 1) ) >= 0) {
      if ($guarded) {
        # The occurrences come from the left, so the markers that end before
        # this one are behind every later one too.
        $next++ while $next < @markers && $markers[$next] + $marker_length <= $at;
        next if $next < @markers && $markers[$next] < $at + $length;
      }
      # An occurrence may begin inside the one before it: only its rest is new.
      my $from = $at > $marked ? $at : $marked;
      $marked = $at + $length;
      substr($mask, $from, $marked - $from) = "\1" x ( $marked - $from );
      $found = 1;
    }
  }
  return $text unless $found;
  my ( $redacted, $copied ) = ( '', 0 );
  while ($mask =~ /\x01+/g) {
    $redacted .= substr($bytes, $copied, $-[0] - $copied).$marker;
    $copied = $+[0];
  }
  $redacted .= substr($bytes, $copied);
  utf8::decode($redacted);
  return $redacted;
}

# What is left of a marker that was cut in two is no marker: the next pass
# would look for values in it. A marker the cut falls into goes as a whole.
sub redacted_tail {
  my ( $self, $text, $limit ) = @_;
  my $cut = length($text) - $limit;
  return $text if $cut <= 0;
  my $marker = $self->redaction_marker;
  my $length = length $marker;
  for my $start (grep { $_ >= 0 } $cut - $length + 1 .. $cut - 1) {
    return substr($text, $start + $length) if substr($text, $start, $length) eq $marker;
  }
  return substr($text, $cut);
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

A marker that is in C<$text> already is taken for one, not for text: an
occurrence that lies in such a marker, or that reaches across one of its
ends, is no occurrence. The dispatcher redacts the log the worker has
redacted, and a value that is a piece of the marker, as C<RED> is, or that
begins with its end, as C<]bc> does, would otherwise be replaced in the
markers of the first pass and show what it is: C<[[REDACTED]ACTED]>. So

  $self->redact($self->redact($text, $secrets), $secrets)

is C<< $self->redact($text, $secrets) >> for every value
L</secret_value_valid> accepts. An occurrence directly before or behind a
marker is found like any other.

The price is a marker that a job printed itself: a value is not found where
it shares characters with that marker. For a value that is a piece of the
marker nothing is lost, the text shows no more than the marker. For any
other value the job would have to print the beginning of a marker right in
front of a value that begins with its end, which is a value printed split.

A value that contains the marker could never be found that way. No grant
carries one, see L</secret_value_rejection>; if one is passed all the same,
as from a snapshot written before that rule, it is looked for without regard
to markers.

=head2 redacted_tail

  my $tail = $self->redacted_tail($redacted, $limit);

Returns the last C<$limit> characters of a redacted text, or less: if the
cut falls into a marker, the tail begins behind that marker. What a cut
leaves of a marker is no marker for the next pass, which would look for
values in it. A text of at most C<$limit> characters is returned as it is.

=head2 secret_values

  my @values = $self->secret_values($secrets);

Returns each distinct nonempty string found in C<$secrets>, whatever its
shape: the values of a hash and the elements of a list are followed to any
depth. Undefined values, empty strings and other references are left out, so
that a claim of an unexpected shape cannot break the redaction: an empty
string as a value would match between any two characters.

=head2 redaction_marker

Returns C<[REDACTED]>, the text an occurrence is replaced by. It does not
overlap itself, which L</redact> relies on to find the markers of a text.

=head2 secret_name_valid

  croak 'invalid secret name' unless $self->secret_name_valid($name);

True for a string of the form C<CICD_E<lt>NAMEE<gt>> or
C<E<lt>NAMEE<gt>_TOKEN> in capitals, digits and underscores: the names a
grant may carry. Which of them the executor reserves for itself is a rule of
L<SimpiCI::Dispatcher/reserved_secret_names>.

=head2 secret_value_rejection

  my $reason = $self->secret_value_rejection($value);
  croak 'secret '.$reason if defined $reason;

Returns why C<$value> cannot be a secret value, or nothing if it can. The
reason is a phrase that repeats nothing of the value:

=over 4

=item C<must be one nonempty line>

It is undefined, a reference or empty, or it has a line end, a carriage
return or a NUL: it is not one line of an environment file.

=item C<must not contain [REDACTED], the marker of a redacted value>

It contains L</redaction_marker>. L</redact> could not tell such a value
from a marker and a text around it. In practice it is a line that was copied
from a published log into a secret file.

=back

A value that is only a piece of the marker, or that begins or ends with a
piece of it, is accepted: L</redact> does not look for it in a marker.

=head2 secret_value_valid

  croak 'invalid secret value' unless $self->secret_value_valid($value);

True for a value L</secret_value_rejection> has no reason against, false
otherwise.

=cut
