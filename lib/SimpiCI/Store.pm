package SimpiCI::Store;
our $VERSION = '0.001';

use Moo;

# ABSTRACT: Private filesystem persistence for SimpiCI

use Carp qw( croak );
use Fcntl qw( LOCK_EX );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Types::Standard qw( InstanceOf );
use namespace::autoclean;

has root => (
  is       => 'ro',
  isa      => InstanceOf['Path::Tiny'],
  coerce   => 1,
  required => 1,
);

has instance => (is => 'lazy', init_arg => undef);

has _json => (is => 'lazy');

sub _build__json {
  return JSON::MaybeXS->new(canonical => 1, convert_blessed => 1, pretty => 1);
}

# Written once and never replaced. It is linked into place, not renamed: of
# several processes that find none, one gets the name and the others read
# what it wrote.
sub _build_instance {
  my ( $self ) = @_;

  my $file = $self->root->child('instance');
  unless ($file->exists) {
    $self->root->mkpath;
    my $random = path('/dev/urandom')->openr_raw;
    my $bytes;
    read($random, $bytes, 16) == 16 or croak __PACKAGE__.' cannot read entropy';
    my $temporary = $file->sibling('.instance.tmp.'.$$);
    $temporary->spew_utf8(unpack('H*', $bytes)."\n");
    my $linked = link($temporary->stringify, $file->stringify) || $!{EEXIST};
    my $reason = $!;
    $temporary->remove;
    croak __PACKAGE__.' cannot write the instance to '.$file.': '.$reason unless $linked;
  }
  # Not replaced when it is not one either: the containers that carry the
  # instance it held could not be found again.
  my $instance = $file->slurp_utf8;
  croak __PACKAGE__.' invalid instance in '.$file unless $instance =~ /\A[0-9a-f]{32}\n?\z/;
  chomp $instance;
  return $instance;
}

sub prepare {
  my ( $self ) = @_;

  $self->root->child($_)->mkpath for qw( work runs public public/runs );
  return $self;
}

sub allocate_run {
  my ( $self ) = @_;

  $self->prepare;
  my $counter = $self->root->child('counter');
  my $fh = $self->root->child('counter.lock')->opena_raw;
  flock($fh, LOCK_EX)
    or croak __PACKAGE__.'->allocate_run cannot lock counter: '.$!;
  my $current = $counter->is_file ? $counter->slurp_utf8 : 0;
  chomp $current;
  croak __PACKAGE__.'->allocate_run invalid counter' unless $current =~ /\A\d+\z/;
  my $next = $current + 1;
  my $temporary = $counter->sibling('.counter.tmp.'.$$);
  my $output = $temporary->openw_raw;
  print {$output} $next."\n" or croak __PACKAGE__.' cannot write counter: '.$!;
  $output->sync or croak __PACKAGE__.' cannot sync counter: '.$!;
  close $output or croak __PACKAGE__.' cannot close counter: '.$!;
  $temporary->move($counter);
  return $next;
}

sub write_json {
  my ( $self, $relative, $value ) = @_;

  croak __PACKAGE__.'->write_json path escapes root'
    if path($relative)->is_absolute || grep { $_ eq '..' } split m{/+}, $relative;
  my $target = $self->root->child($relative);
  croak __PACKAGE__.'->write_json path escapes root'
    unless $target->absolute =~ /^\Q@{[$self->root->absolute]}\E(?:\/|\z)/;
  $target->parent->mkpath;
  my $temporary = $target->sibling('.'.$target->basename.'.tmp.'.$$);
  $temporary->spew_utf8($self->_json->encode($value));
  unless (rename($temporary, $target)) {
    # What could not be published is not left beside its target either.
    my $reason = $!;
    $temporary->remove;
    croak __PACKAGE__.'->write_json cannot publish '.$target.': '.$reason;
  }
  return $target;
}

1;

=head1 NAME

SimpiCI::Store - private filesystem persistence for SimpiCI

=head1 METHODS

=head2 instance

  my $instance = $store->instance;

Returns what tells this store from every other one: 32 hexadecimal digits,
made from random bytes when the store is asked for the first time and kept
as the file C<instance> below the root. L<SimpiCI::Runner> labels the
containers of its runs with it, so that only the containers of this store
are ever removed for it.

The file is written once and never changed. Croaks with C<invalid instance>
and the path if it holds anything else; it is not replaced then, because
containers that carry the instance it held would not be found again. A copy
of a root is the same instance: remove the file from a copy that is to run
beside the original on one container daemon.

=head2 prepare

Creates the required work, run, and public-report directories and returns the
store.

=head2 allocate_run

Atomically allocates and returns the next monotonically increasing run number.

=head2 write_json

  my $path = $store->write_json($relative_path, $value);

Publishes deterministic JSON atomically below the store root. Absolute paths
and parent-directory traversal are rejected. The value is written to a
temporary file beside the target and renamed; if that fails, C<write_json>
croaks with C<cannot publish> and the target, and the temporary file is
removed. A process that is killed in between leaves it, as
C<.E<lt>nameE<gt>.tmp.E<lt>pidE<gt>>.

=cut
