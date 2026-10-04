use strict;
use warnings;
use Test2::V0;

use SimpiCI::Event;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );

# The executor uses the clone URL for nothing itself: it writes it into the
# event file and into the environment of every job. A native event has
# passed SimpiCI::Event; a hosted or direct caller sets CICD_CLONE_URL as it
# likes. What the executor does not pass on is a user part with credentials.

my $executor = path('bin/simpici-executor')->absolute->stringify;
my $json = JSON::MaybeXS->new;

my $user = 'deploy-bot';
my $token = 's3cr3t-t0ken';

sub workspace {
  my $root = tempdir;
  $root->child('.cicd')->mkpath;
  $root->child('bin')->mkpath;
  $root->child('tmp')->mkpath;
  $root->child('.cicd/linux+test.sh')->spew_utf8("#!/bin/sh\nexit 0\n");
  # One line per argument of each container, and the event file it is given.
  my $docker = $root->child('bin/docker');
  $docker->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 0
printf '%s\n' "$@" >> "$TEST_TRACE"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == -v && "${args[i+1]}" == *:/run/simpici/event.json:ro ]] || continue
  cat "${args[i+1]%:/run/simpici/event.json:ro}" > "$TEST_EVENT"
done
SCRIPT
  $docker->chmod(0755);
  return $root;
}

# Returns the exit code, what the executor printed, the clone URL a job has
# in its environment and the one in its event file, and everything a
# container was given, as one text.
sub execute {
  my ( %environment ) = @_;
  my $root = workspace();
  local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
  local $ENV{CICD_WORKSPACE} = "$root";
  local $ENV{RUNNER_TEMP} = $root->child('tmp')->stringify;
  local $ENV{SIMPICI_PROVIDERS} = 'example.org/provider@sha256:deadbeef';
  local $ENV{SIMPICI_CONCURRENCY} = 1;
  local $ENV{TEST_TRACE} = $root->child('trace')->stringify;
  local $ENV{TEST_EVENT} = $root->child('event')->stringify;
  delete local @ENV{qw( SIMPICI_INSTANCE CICD_CLONE_URL CICD_REPOSITORY GITHUB_REPOSITORY
    FORGEJO_REPOSITORY GITHUB_SERVER_URL FORGEJO_SERVER_URL FORGEJO_ACTIONS )};
  local @ENV{ keys %environment } = values %environment;
  my $output = qx{bash "$executor" 2>&1};
  my $status = $? >> 8;
  my $trace = $root->child('trace');
  my @given = $trace->is_file ? $trace->lines_utf8({ chomp => 1 }) : ();
  my @in_environment = map { /\ACICD_CLONE_URL=(.*)\z/s ? $1 : () } @given;
  my $event = $root->child('event');
  my $written = $event->is_file ? $event->slurp_utf8 : '';
  my $in_event = eval { $json->decode($written)->{clone_url} };
  # The event file as the executor left it, and every other file of the run.
  my @files;
  $root->child('tmp')->visit(sub { push @files, $_[0]->slurp_raw if $_[0]->is_file },
    { recurse => 1 });
  return ( $status, $output, \@in_environment, $in_event,
    join("\n", $output, @given, $written, @files) );
}

#### What SimpiCI::Event accepts

# The native runner hands the executor the clone URL of its event. None of
# these may change on the way, a user name included.
for my $clone_url (
  'https://forge.invalid/owner/project.git',
  'https://forge.invalid:8443/owner/pro@ject.git',
  'http://forge.invalid/owner/project.git',
  'ssh://git@forge.invalid/owner/project.git',
  'ssh://git@forge.invalid:2222/owner/pro:je@ct.git',
  'ssh://git@[2001:db8::1]:2222/owner/project.git',
  'ssh://@forge.invalid/owner/project.git',
  'git@forge.invalid:owner/project.git',
  'git@forge.invalid:owner/pro:ject.git',
  'forge:pro@ject.git',
  '[2001:db8::1]:owner/project.git',
  'file:///srv/git/us:er@project.git',
  '/srv/git/us:er@pro:ject.git'
) {
  is(SimpiCI::Event->clone_url_rejection($clone_url), undef, 'SimpiCI::Event accepts '.$clone_url);
  my ( $status, $output, $in_environment, $in_event ) = execute(CICD_CLONE_URL => $clone_url);
  is $status, 0, 'the executor runs with it' or diag $output;
  is $in_environment, [ $clone_url ], 'the job has it in its environment as it is';
  is $in_event, $clone_url, 'and in its event file';
  unlike $output, qr/CICD_CLONE_URL/, 'and the executor says nothing about it';
}

#### Credentials

# What a hosted workflow or a direct caller may set. The user part
# SimpiCI::Event refuses the URL for is left out, as SimpiCI::Event leaves
# it out of what it shows.
for my $clone_url (
  'https://'.$user.':'.$token.'@forge.invalid/owner/project.git',
  'https://'.$token.'@forge.invalid/owner/project.git',
  'https://x-access-token:'.$token.'@forge.invalid/owner/pro@ject.git',
  'http://'.$user.':'.$token.'@forge.invalid:3000/owner/project.git',
  'HTTPS://'.$token.'@forge.invalid/owner/project.git',
  'helper::https://'.$token.'@forge.invalid/owner/project.git',
  # Behind a scheme that is neither ssh nor file, a lone user part may be a
  # token as well.
  'persistent-https://'.$token.'@forge.invalid/owner/project.git',
  'ftp://'.$token.'@forge.invalid/owner/project.git',
  'helper::ssh://'.$token.'@forge.invalid/owner/project.git',
  'SSH://'.$token.'@forge.invalid/owner/project.git',
  'ssh://'.$user.':'.$token.'@forge.invalid/owner/project.git',
  'ssh://'.$user.':'.$token.'@forge.invalid:2222/owner/pro:je@ct.git',
  'ssh://'.$user.':to@ken'.$token.'@forge.invalid/owner/project.git',
  'ssh://'.$user.'%3A'.$token.'@forge.invalid/owner/project.git',
  'ssh://'.$user.'%3a'.$token.'@forge.invalid/owner/project.git',
  'ssh://:'.$token.'@[2001:db8::1]:2222/owner/project.git',
  'ftp://'.$user.':'.$token.'@forge.invalid/owner/project.git',
  $user.':'.$token.'@forge.invalid:owner/project.git'
) {
  my $shown = SimpiCI::Event->clone_url_without_credentials($clone_url);
  unlike $shown, qr/\Q$token\E/, 'SimpiCI::Event shows '.$clone_url.' without its token';
  my ( $status, $output, $in_environment, $in_event, $everything ) =
    execute(CICD_CLONE_URL => $clone_url);
  is $status, 0, 'the executor runs with it' or diag $output;
  is $in_environment, [ $shown ], 'the job gets the same in its environment';
  is $in_event, $shown, 'and in its event file';
  unlike $everything, qr/\Q$token\E/,
    'the token is in nothing the executor printed, wrote or gave a container';
  like $output, qr/^SimpiCI: CICD_CLONE_URL carried credentials; its user part is not passed on to the jobs$/m,
    'and the executor says that it left something out';
  unlike $output, qr/\Q$user\E|forge\.invalid/, 'without the URL';
}

#### The hosted default

{
  my ( $status, $output, $in_environment, $in_event ) = execute(
    FORGEJO_SERVER_URL => 'https://forge.invalid', FORGEJO_REPOSITORY => 'owner/project');
  is [ $status, $in_environment, $in_event ],
    [ 0, [ 'https://forge.invalid/owner/project.git' ], 'https://forge.invalid/owner/project.git' ],
    'without CICD_CLONE_URL the clone URL is made of server and repository';
  ( $status, $output, $in_environment, $in_event, my $everything ) = execute(
    GITHUB_SERVER_URL => 'https://'.$user.':'.$token.'@forge.invalid',
    GITHUB_REPOSITORY => 'owner/project');
  is [ $status, $in_environment, $in_event ],
    [ 0, [ 'https://forge.invalid/owner/project.git' ], 'https://forge.invalid/owner/project.git' ],
    'and credentials in the server URL are left out of it as well';
  unlike $everything, qr/\Q$token\E/, 'so that the token reaches no job';
}

done_testing;
