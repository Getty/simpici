#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

for my $program (qw( simpici simpicid )) {
  my $output = qx{$^X -Ilib bin/$program --help 2>&1};
  is $?, 0, $program.' --help exits successfully';
  like $output, qr/^Usage:/m, $program.' --help contains usage';

  $output = qx{$^X -Ilib bin/$program --man 2>&1};
  is $?, 0, $program.' --man exits successfully';
  like $output, qr/container (?:phases|executor)/i,
    $program.' manual describes the shared executor';
}

like scalar qx{$^X -Ilib bin/simpicid --help 2>&1}, qr/^\s+--check\b/m, 'simpicid --help lists --check';

done_testing;
