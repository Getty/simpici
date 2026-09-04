package App::SimpiCI::Store;
use Moo;

use Carp qw( croak );
use Fcntl qw( LOCK_EX SEEK_SET );
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

has _json => (is => 'lazy');

sub _build__json {
  return JSON::MaybeXS->new(canonical => 1, convert_blessed => 1, pretty => 1);
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
  $counter->touch unless $counter->exists;
  my $fh = $counter->openrw_raw;
  flock($fh, LOCK_EX)
    or croak __PACKAGE__.'->allocate_run cannot lock '.$counter.': '.$!;
  seek($fh, 0, SEEK_SET)
    or croak __PACKAGE__.'->allocate_run cannot seek '.$counter.': '.$!;
  my $current = <$fh> // 0;
  chomp $current;
  croak __PACKAGE__.'->allocate_run invalid counter' unless $current =~ /\A\d+\z/;
  my $next = $current + 1;
  seek($fh, 0, SEEK_SET)
    or croak __PACKAGE__.'->allocate_run cannot rewind '.$counter.': '.$!;
  truncate($fh, 0)
    or croak __PACKAGE__.'->allocate_run cannot truncate '.$counter.': '.$!;
  print {$fh} $next."\n"
    or croak __PACKAGE__.'->allocate_run cannot write '.$counter.': '.$!;
  $fh->sync
    or croak __PACKAGE__.'->allocate_run cannot sync '.$counter.': '.$!;
  close $fh
    or croak __PACKAGE__.'->allocate_run cannot close '.$counter.': '.$!;
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
  rename($temporary, $target)
    or croak __PACKAGE__.'->write_json cannot publish '.$target.': '.$!;
  return $target;
}

1;
