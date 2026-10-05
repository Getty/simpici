#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( path );

# What is loaded and checked here is read from the tree, so that a module or
# a program that is added is not one this test forgot.

my $lib = path('lib');
my @modules;
$lib->visit(
  sub { push @modules, $_[0] if $_[0]->is_file && $_[0]->basename =~ /\.pm\z/ },
  { recurse => 1 }
);
@modules = sort { "$a" cmp "$b" } @modules;
ok scalar(@modules) >= 11, 'the modules below lib/ are found' or diag scalar @modules;

my %version;
for my $file (@modules) {
  ( my $module = $file->relative($lib)->stringify ) =~ s{/}{::}g;
  $module =~ s/\.pm\z//;
  # In a process of its own: a module that only loads because another one
  # was loaded before it would pass in this one.
  my $output = qx{"$^X" -Ilib -e "require $module; print q(loaded)" 2>&1};
  is [ $? >> 8, $output ], [ 0, 'loaded' ], 'loaded '.$module;
  my $content = $file->slurp_utf8;
  my @packages = $content =~ /^package\s+([\w:]+)/mg;
  is \@packages, [ $module ], $module.' is the one package of its file';
  my @versions = $content =~ /^our \$VERSION = '([0-9]+\.[0-9]+)';$/mg;
  is scalar(@versions), 1, $module.' carries its own $VERSION';
  $version{ $versions[0] // 'none' }{$module} = 1;
}

my @programs = sort { "$a" cmp "$b" } grep { $_->is_file } path('bin')->children;
ok scalar(@programs) >= 5, 'the programs in bin/ are found' or diag scalar @programs;
for my $program (@programs) {
  my ( $first ) = $program->lines_utf8({ count => 1 });
  ok -x $program->stringify, $program.' is executable';
  if ($first =~ /\A#!.*\bperl\b/) {
    my $output = qx{"$^X" -Ilib -c "$program" 2>&1};
    is $? >> 8, 0, $program.' compiles' or diag $output;
    my @versions = $program->slurp_utf8 =~ /^our \$VERSION = '([0-9]+\.[0-9]+)';$/mg;
    is scalar(@versions), 1, $program.' carries its own $VERSION';
    $version{ $versions[0] // 'none' }{ $program->basename } = 1;
  } elsif ($first =~ /\A#!.*\bbash\b/) {
    my $output = qx{bash -n "$program" 2>&1};
    is $? >> 8, 0, $program.' is read by bash without a syntax error' or diag $output;
    # The version plugins of the release read Perl. A version in a shell
    # program would be one that no release moves.
    unlike $program->slurp_utf8, qr/^\s*(?:our\s+)?\$?VERSION\s*=/m,
      $program.' carries no version of its own';
  } else {
    fail $program.' is a Perl or a Bash program';
  }
}

is [ keys %version ], [ ( keys %version )[0] ], 'modules and programs carry one and the same version'
  or diag join ', ', map { $_.': '.join(' ', sort keys $version{$_}->%*) } sort keys %version;

done_testing;
