use strict;
use warnings;
use Test2::V0;

use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );

# The executor writes six values into the event file every provider and job
# reads. A hosted or direct caller sets them as it likes. A value the file
# cannot hold as a string ends the run before anything is started, instead
# of leaving a file that is no JSON.

my $executor = path('bin/simpici-executor')->absolute->stringify;
my $json = JSON::MaybeXS->new;

sub workspace {
  my $root = tempdir;
  $root->child('.cicd')->mkpath;
  $root->child('bin')->mkpath;
  $root->child('tmp')->mkpath;
  $root->child('.cicd/linux+test.sh')->spew_utf8("#!/bin/sh\nexit 0\n");
  # One line for each container that is started, a provider or a job.
  my $docker = $root->child('bin/docker');
  $docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
printf 'started\n' >> "$TEST_TRACE"
SCRIPT
  $docker->chmod(0755);
  return $root;
}

# Returns the exit code, what the executor printed, how many containers it
# started and the event files it left, as text.
sub execute {
  my ( %environment ) = @_;
  my $root = workspace();
  local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
  local $ENV{CICD_WORKSPACE} = "$root";
  local $ENV{RUNNER_TEMP} = $root->child('tmp')->stringify;
  local $ENV{SIMPICI_PROVIDERS} = 'example.org/provider@sha256:deadbeef';
  local $ENV{SIMPICI_CONCURRENCY} = 1;
  local $ENV{TEST_TRACE} = $root->child('trace')->stringify;
  delete local @ENV{ grep { /\A(?:CICD|GITHUB|FORGEJO)_/ } keys %ENV };
  local $ENV{CICD_WORKSPACE} = "$root";
  local @ENV{ keys %environment } = values %environment;
  my $output = qx{bash "$executor" 2>&1};
  my $status = $? >> 8;
  my $trace = $root->child('trace');
  my @events;
  $root->child('tmp')->visit(sub {
    push @events, $_[0]->slurp_utf8 if $_[0]->is_file && $_[0]->basename eq 'event.json';
  }, { recurse => 1 });
  return ( $status, $output, $trace->is_file ? scalar $trace->lines_utf8 : 0, \@events );
}

my %fine = (
  CICD_SOURCE     => 'manual',
  CICD_EVENT      => 'push',
  CICD_REPOSITORY => 'owner/project',
  CICD_CLONE_URL  => 'https://forge.invalid/owner/project.git',
  CICD_REF        => 'refs/heads/main',
  CICD_COMMIT     => 'a' x 40
);
my %field = (
  CICD_SOURCE => 'source', CICD_EVENT => 'event', CICD_REPOSITORY => 'repository',
  CICD_CLONE_URL => 'clone_url', CICD_REF => 'ref', CICD_COMMIT => 'commit'
);

#### Values the file holds

{
  my ( $status, $output, $started, $events ) = execute(%fine);
  is $status, 0, 'the executor runs with six plain values' or diag $output;
  is $started, 2, 'and starts the provider and the job';
  is [ map { $json->decode($_) } @$events ],
    [ { map { $field{$_} => $fine{$_} } keys %fine } ], 'the event file has them';
  # What a JSON string must escape, and what it may hold as it is.
  my %odd = ( %fine, CICD_REPOSITORY => 'owner/pro"ject\\one', CICD_REF => "refs/heads/gr\xc3\xbcn" );
  ( $status, $output, $started, $events ) = execute(%odd);
  is $status, 0, 'a quote, a backslash and UTF-8 are no reason to give up' or diag $output;
  my $event = $json->decode($events->[0]);
  is $event->{repository}, 'owner/pro"ject\\one', 'the first two are escaped';
  is $event->{ref}, "refs/heads/gr\x{fc}n", 'and a character of several bytes stays whole';
}

#### A value the file cannot hold

my $marker = 'S3cr3tMarker';
for my $variable (sort keys %fine) {
  for my $case (
    [ 'a line end', $fine{$variable}."\n".$marker ],
    [ 'a line end as its last character', $marker."\n" ],
    [ 'a carriage return', $marker."\r".$fine{$variable} ],
    [ 'a tab', $marker."\t".$fine{$variable} ]
  ) {
    my ( $label, $value ) = @$case;
    my ( $status, $output, $started, $events ) = execute(%fine, $variable => $value);
    is $status, 65, $variable.' with '.$label.' ends the executor with 65';
    is $started, 0, 'no provider and no job is started';
    is [ grep { !eval { $json->decode($_); 1 } } @$events ], [],
      'no event file is left that is no JSON';
    like $output, qr/\ASimpiCI: event field \Q$field{$variable}\E must not contain a line end or another control character\n\z/,
      'standard error names the field';
    unlike $output, qr/\Q$marker\E/, 'and not the value';
  }
}

# The same value from where a hosted runner puts it.
{
  my ( $status, $output, $started, $events ) =
    execute(GITHUB_REF => "refs/heads/main\n".$marker, GITHUB_SHA => 'a' x 40);
  is [ $status, $started, $events ], [ 65, 0, [] ], 'a ref of the hosted context is held to the same';
  like $output, qr/\ASimpiCI: event field ref must not contain a line end or another control character\n\z/,
    'and named as the field it becomes';
}

done_testing;
