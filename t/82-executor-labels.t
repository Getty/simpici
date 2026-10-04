use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( path tempdir );

# Every container the executor starts for a supervised run carries the label
# of the instance and of the run, so that the supervisor finds it again. A
# run that nobody supervises, as in a hosted workflow, gets none.

my $instance = '0123456789abcdef0123456789abcdef';
my $executor = path('bin/simpici-executor')->absolute->stringify;

sub workspace {
  my $root = tempdir;
  $root->child('.cicd')->mkpath;
  $root->child('bin')->mkpath;
  $root->child('tmp')->mkpath;
  $root->child('.cicd/linux+'.$_.'.sh')->spew_utf8("#!/bin/sh\nexit 0\n") for qw( test publish );
  # One line per container: what it was started with. A provider writes no job.
  my $docker = $root->child('bin/docker');
  $docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
printf '%s\n' "$*" >> "$TEST_TRACE"
SCRIPT
  $docker->chmod(0755);
  return $root;
}

sub execute {
  my ( $root, %environment ) = @_;
  local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
  local $ENV{CICD_WORKSPACE} = "$root";
  local $ENV{RUNNER_TEMP} = $root->child('tmp')->stringify;
  local $ENV{SIMPICI_PROVIDERS} = 'example.org/provider@sha256:deadbeef';
  local $ENV{SIMPICI_CONCURRENCY} = 1;
  local $ENV{TEST_TRACE} = $root->child('trace')->stringify;
  delete local @ENV{qw( SIMPICI_INSTANCE CICD_RUN_NUMBER GITHUB_RUN_NUMBER FORGEJO_RUN_NUMBER )};
  local @ENV{ keys %environment } = values %environment;
  my $output = qx{bash "$executor" 2>&1};
  my $trace = $root->child('trace');
  return ( $? >> 8, $output, $trace->is_file ? [ $trace->lines_utf8({ chomp => 1 }) ] : [] );
}

subtest 'a run of an instance' => sub {
  my ( $status, $output, $started ) =
    execute(workspace(), SIMPICI_INSTANCE => $instance, CICD_RUN_NUMBER => 7);
  is $status, 0, 'runs' or diag $output;
  is scalar @$started, 3, 'a provider and two jobs are started';
  for my $container (@$started) {
    my ( $name ) = $container =~ m{(example\.org/provider|CICD_PHASE=\w+)};
    like $container, qr/ --label simpici\.instance=\Q$instance\E /,
      $name.' carries the label of the instance';
    like $container, qr/ --label simpici\.run=\Q$instance\E\.7 /, $name.' and that of the run';
  }
};

subtest 'a run without an instance' => sub {
  my ( $status, $output, $started ) = execute(workspace(), CICD_RUN_NUMBER => 7);
  is $status, 0, 'runs' or diag $output;
  is scalar @$started, 3, 'a provider and two jobs are started';
  is [ grep { /--label|simpici\.(?:instance|run)/ } @$started ], [], 'without a label';
};

subtest 'an instance that is not one' => sub {
  for my $value ('x', 'a b', ('a' x 32).' --privileged', ('A' x 32), ('a' x 33)) {
    my ( $status, $output, $started ) =
      execute(workspace(), SIMPICI_INSTANCE => $value, CICD_RUN_NUMBER => 7);
    is $status, 64, 'is refused: '.$value;
    like $output, qr/^SimpiCI: invalid SIMPICI_INSTANCE$/m, 'with a reason';
    is $started, [], 'before a container is started';
  }
};

subtest 'an instance without a run number' => sub {
  my ( $status, $output, $started ) =
    execute(workspace(), SIMPICI_INSTANCE => $instance, CICD_RUN_NUMBER => '7; true');
  is $status, 64, 'is refused';
  like $output, qr/^SimpiCI: SIMPICI_INSTANCE needs a decimal CICD_RUN_NUMBER$/m, 'with a reason';
  is $started, [], 'before a container is started';
};

done_testing;
