#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use App::SimpiCI::Event;
use App::SimpiCI::Runner;
use App::SimpiCI::Store;
use File::Temp qw( tempdir );
use JSON::MaybeXS;
use Path::Tiny qw( path );

my $fixture = path(tempdir(CLEANUP => 1));
system('git', 'init', '-q', '-b', 'main', $fixture->stringify) == 0
  or die 'git init failed';
$fixture->child('.cicd')->mkpath;
$fixture->child('.cicd', 'linux+self+cicd.sh')->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
printf 'built %s at %s\n' "$CICD_REPOSITORY" "$CICD_COMMIT"
SCRIPT
chmod 0755, $fixture->child('.cicd', 'linux+self+cicd.sh');
system('git', '-C', $fixture->stringify, 'add', '.cicd') == 0
  or die 'git add failed';
{
  local $ENV{GIT_AUTHOR_NAME} = 'SimpiCI Test';
  local $ENV{GIT_AUTHOR_EMAIL} = 'test@example.invalid';
  local $ENV{GIT_COMMITTER_NAME} = 'SimpiCI Test';
  local $ENV{GIT_COMMITTER_EMAIL} = 'test@example.invalid';
  system('git', '-C', $fixture->stringify, 'commit', '-q', '-m', 'fixture') == 0
    or die 'git commit failed';
}
chomp(my $commit = qx(git -C @{[$fixture->stringify]} rev-parse HEAD));

my $root = path(tempdir(CLEANUP => 1));
my $event = App::SimpiCI::Event->new(
  source     => 'manual',
  event      => 'push',
  repository => 'simpici-fixture',
  clone_url  => $fixture->stringify,
  ref        => 'refs/heads/main',
  commit     => $commit,
  platform   => 'linux',
  feature    => 'self'
);
my $report = App::SimpiCI::Runner->new(
  store   => App::SimpiCI::Store->new(root => $root),
  timeout => 30
)->run($event);

is $report->{state}, 'success', 'runs checked-out repository script';
like $root->child('public', 'runs', '1.log')->slurp_utf8,
  qr/built simpici-fixture at \Q$commit\E/,
  'captures script output with invocation environment';
ok $root->child('work', '1', '.git')->is_dir, 'creates isolated checkout';
is(
  JSON::MaybeXS->new->decode(
    $root->child('public', 'runs', '1.json')->slurp_utf8
  )->{commit},
  $commit,
  'publishes requested exact commit'
);

done_testing;
