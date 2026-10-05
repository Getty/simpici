package SimpiCI::Config;
our $VERSION = '0.001';

use strict;
use warnings;

# ABSTRACT: Reading a configuration file and the rules of its settings

use JSON::MaybeXS;
use Path::Tiny qw( path );

# The settings at the top of a configuration, in the order they are checked
# and reported, each with the kind of value it takes. "repositories" is the
# one key that is no setting: its entries have rules of their own.
sub setting_kinds {
  return (
    mode                 => 'mode',
    root                 => 'text',
    interval             => 'seconds',
    timeout              => 'seconds',
    ls_remote_timeout    => 'seconds',
    request_read_timeout => 'seconds',
    runner               => 'text'
  );
}

sub setting_names {
  my ( $class ) = @_;

  my @kinds = $class->setting_kinds;
  return @kinds[ grep { $_ % 2 == 0 } 0 .. $#kinds ];
}

sub modes { qw( local dispatcher ) }

# The mode of a configuration, or nothing if what it says is none.
sub mode {
  my ( $class, $config ) = @_;

  my $mode = $config->{mode} // 'local';
  return if ref $mode;
  return ( grep { $_ eq $mode } $class->modes )[0];
}

sub positive_integer {
  my ( $class, $value ) = @_;

  return defined $value && !ref $value && $value =~ /\A[1-9][0-9]*\z/ ? 1 : 0;
}

# Why a setting cannot be used, or nothing. Like the rules of SimpiCI::Event
# it gives its reason and never the value: what stands in the wrong place of
# a configuration may be a token.
sub setting_rejection {
  my ( $class, $config, $name ) = @_;

  my %kind = $class->setting_kinds;
  my $kind = $kind{$name} // return $name.' is no setting';
  my $value = $config->{$name};
  unless (defined $value) {
    # simpicid would take ./var, and simpici-dispatch, which has no such
    # default, another directory or none.
    return 'root is required in dispatcher mode'
      if $name eq 'root' && ( $class->mode($config) // '' ) eq 'dispatcher';
    return;
  }
  return $kind eq 'seconds' ? ( $class->positive_integer($value) ? () : $name.' must be a positive integer' )
    : $kind eq 'mode' ? ( defined $class->mode($config) ? ()
      : 'mode must be '.join(' or ', map { '"'.$_.'"' } $class->modes) )
    : ( !ref $value && length $value ? () : $name.' must be a nonempty string' );
}

# Returns the decoded configuration, or nothing and the reason. The reason
# repeats nothing of the file: the decoder would quote the text around the
# place it stopped at.
sub read {
  my ( $class, $file ) = @_;

  my $text = eval { path($file)->slurp_utf8 };
  unless (defined $text) {
    my $error = $@;
    return ( undef, 'cannot read the configuration: '
      .( ref $error eq 'Path::Tiny::Error' ? $error->{err} : 'it is no text in UTF-8' ) );
  }
  my $config;
  unless (eval { $config = JSON::MaybeXS->new(allow_nonref => 1)->decode($text); 1 }) {
    my ( $offset ) = $@ =~ /\bcharacter offset ([0-9]+)/;
    return ( undef, 'configuration is no JSON'
      .( defined $offset ? ': the decoder stopped at character '.$offset : '' ) );
  }
  return ( undef, 'configuration must be an object' ) unless ref $config eq 'HASH';
  return $config;
}

1;

=head1 NAME

SimpiCI::Config - reading a configuration file and the rules of its settings

=head1 SYNOPSIS

  my ( $config, $reason ) = SimpiCI::Config->read('/etc/simpici/dispatcher.json');
  my $rejection = SimpiCI::Config->setting_rejection($config, 'timeout');

=head1 DESCRIPTION

The one place for how a configuration file is read and for what its
top-level settings may hold. C<simpicid>, C<simpici> and C<simpici-dispatch>
read the same file independently of each other; they read it through this
class, and whoever uses a setting asks here whether it can be used, so that
the daemon, its C<--check> and the worker endpoint cannot disagree about it.

No reason this class gives repeats a value of the configuration. A value in
the wrong place may be a credential, and the reason of C<simpici-dispatch>
travels to a log.

The entries of C<repositories> are checked by
L<SimpiCI::App::Eventd/check_repositories> and their secret grants by
L<SimpiCI::Dispatcher/problems>; L<SimpiCI::App::Eventd/check> puts the
three together.

=head1 SETTINGS

=over 4

=item C<mode>

C<local> or C<dispatcher>, written exactly so. Without it the mode is
C<local>.

=item C<root>

The state root, a nonempty string. C<simpicid> takes F<./var> without it; in
dispatcher mode it is required, because C<simpici-dispatch> has no default
and would look for the queue elsewhere.

=item C<interval>, C<timeout>, C<ls_remote_timeout>, C<request_read_timeout>

Seconds, each a positive integer: the pause between two polling cycles (60
without the setting), the limit of the executor of one run (3600), of
reading the refs of one repository (60) and of reading one request of a
worker (30). A JSON C<null> counts as a setting that is not there.

=item C<runner>

The path of the executor, a nonempty string. Whether there is an executable
file at that path is not asked: only a run finds that out.

=back

=head1 METHODS

=head2 read

  my ( $config, $reason ) = SimpiCI::Config->read($file);

Reads and decodes a configuration file. Returns the decoded object, or
nothing and one of these reasons:

  cannot read the configuration: No such file or directory
  configuration is no JSON: the decoder stopped at character 212
  configuration must be an object

It does not croak for a file that cannot be used, and the reason holds no
text of the file.

=head2 setting_kinds

Returns the names of the top-level settings, each followed by the kind of
value it takes, in the order they are checked in. C<repositories> is not
among them.

=head2 setting_names

Returns the names alone, in the same order.

=head2 setting_rejection

  my $reason = SimpiCI::Config->setting_rejection($config, $name);

Returns why the setting of that name cannot be used, or nothing if it can or
is not there:

  timeout must be a positive integer
  mode must be "local" or "dispatcher"
  root must be a nonempty string
  root is required in dispatcher mode

=head2 modes

Returns the two modes, C<local> and C<dispatcher>.

=head2 mode

  my $mode = SimpiCI::Config->mode($config);

Returns the mode of a decoded configuration, C<local> without the setting,
or nothing if the setting names none of L</modes>.

=head2 positive_integer

  my $usable = SimpiCI::Config->positive_integer($value);

True for a number or a string of decimal digits that does not begin with 0,
and for nothing else: not for 0, a fraction, a boolean or a list.

=cut
