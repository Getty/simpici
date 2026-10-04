#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::Event;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX ();

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

my $user = 'deploy-bot';
my $token = 's3cr3t-t0ken';
my $private = 'https://'.$user.':'.$token.'@forge.invalid/owner/private.git';
my $keyed = 'ssh://'.$user.':'.$token.'@forge.invalid/owner/keyed.git';

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name);
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
    '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty',
    '-m', 'fixture') == 0 or croak 'git commit failed';
  return $fixture;
}

sub repository {
  my ( $name, $clone_url ) = @_;
  return { name => $name, clone_url => "$clone_url", refs => ['refs/heads/main'],
    build_initial => JSON->true };
}

sub daemon_config {
  my ( $state, $repositories, %top ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, interval => 1, %top,
    repositories => $repositories
  }));
  return $file;
}

sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { $json->decode($_->slurp_utf8)->{repository} }
    grep { $_->basename =~ /\A[1-9][0-9]*\.json\z/ } $directory->children ];
}

my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);

sub once {
  my ( $config ) = @_;
  my ( $status, $warnings );
  my $died = dies {
    $warnings = warnings {
      $status = SimpiCI::App::Eventd->run('--config', "$config", '--once',
        '--runner', "$runner_script");
    };
  };
  return ( $died, $status, $warnings // [] );
}

# No part of the clone URL may reach an operator's log or a worker.
sub hides_the_url {
  my ( $text, $label ) = @_;
  unlike $text, qr/\Q$token\E/, $label.' without the token';
  unlike $text, qr/\Q$user\E/, $label.' without the user name';
  unlike $text, qr/forge\.invalid/, $label.' without the rest of the URL';
}

# The private repository is readable and has a tip to build: git reads the
# fixture in place of the URL, without a network. A daemon that polls it gets
# as far as building the event. The readable repository sits ahead of it, so a
# check that only comes with the poll shows as a run.
my $good = git_fixture('good');
my $mapped = git_fixture('private');
local $ENV{GIT_ALLOW_PROTOCOL}  = 'file';
local $ENV{GIT_CONFIG_COUNT}    = 2;
local $ENV{GIT_CONFIG_KEY_0}    = 'url.'.$mapped.'.insteadOf';
local $ENV{GIT_CONFIG_VALUE_0}  = $private;
local $ENV{GIT_CONFIG_KEY_1}    = 'url.'.$mapped.'.insteadOf';
local $ENV{GIT_CONFIG_VALUE_1}  = $keyed;
my @repositories = ( repository('owner/good', $good), repository('owner/private', $private) );
my $refusal = qr/repository owner\/private \(repositories\[1\]\): clone URL must not contain credentials/;

#### Local mode

my ( $died, $status, $warnings ) = once(daemon_config('local', \@repositories));
like $died, qr/\ASimpiCI::App::Eventd $refusal/,
  'simpicid does not start with credentials in a clone URL and names the repository';
like $died, qr/credential helper/, 'and where the credentials belong';
hides_the_url($died, 'the message is');
is $warnings, [], 'nothing is reported as not polled';
is runs_of('local'), [], 'the readable repository ahead of it is not built';
ok !$root->child('local', 'state')->exists, 'and no observation is recorded';

#### Dispatcher mode

( $died, $status, $warnings ) = once(daemon_config('dispatcher', \@repositories,
  mode => 'dispatcher'));
like $died, qr/\ASimpiCI::App::Eventd $refusal/, 'dispatcher mode refuses the same way';
hides_the_url($died, 'its message is');
is [ $warnings, runs_of('dispatcher') ], [ [], [] ], 'and queues nothing';

#### A password in a URL of another scheme

# The same arrangement with ssh://user:password@host: readable through the
# fixture, so a daemon that lets it pass builds it and writes the URL down.
sub files_with_the_token {
  my ( $state ) = @_;
  my @found;
  my $directory = $root->child($state);
  return \@found unless $directory->is_dir;
  $directory->visit(sub {
    my ( $file ) = @_;
    push @found, $file->relative($directory)->stringify
      if $file->is_file && $file->slurp_raw =~ /\Q$token\E/;
  }, { recurse => 1 });
  return [ sort @found ];
}

my @keyed = ( repository('owner/good', $good), repository('owner/keyed', $keyed) );
my $keyed_refusal = qr/repository owner\/keyed \(repositories\[1\]\): clone URL must not contain a password/;
for my $mode (qw( local dispatcher )) {
  ( $died, $status, $warnings ) = once(daemon_config('keyed-'.$mode, \@keyed, mode => $mode));
  like $died, qr/\ASimpiCI::App::Eventd $keyed_refusal/,
    'simpicid does not start with a password in an ssh:// clone URL, mode '.$mode;
  like $died, qr/SSH authenticates with a key/, 'and says what the account is given instead';
  hides_the_url($died // '', 'the message is');
  is [ $warnings, runs_of('keyed-'.$mode) ], [ [], [] ], 'nothing is polled, built or queued';
  is files_with_the_token('keyed-'.$mode), [], 'and the password is in no file of the state root';
}

#### The process

my $output = $root->child('process.log');
my $pid = fork;
croak 'fork failed' unless defined $pid;
unless ($pid) {
  open STDOUT, '>', $output->stringify or POSIX::_exit(97);
  open STDERR, '>&', \*STDOUT or POSIX::_exit(97);
  exec $^X, '-I'.path('lib')->absolute, path('bin/simpicid')->absolute->stringify,
    '--config', daemon_config('process', \@repositories)->stringify, '--once',
    '--runner', "$runner_script" or POSIX::_exit(98);
}
waitpid($pid, 0);
my $exit = $?;
my $printed = $output->slurp_utf8;
isnt $exit, 0, 'bin/simpicid exits nonzero';
like $printed, qr/\ASimpiCI::App::Eventd $refusal/, 'with the refusal on standard error';
hides_the_url($printed, 'everything it prints is');
is runs_of('process'), [], 'and it has built nothing';

#### A backtrace

{
  local $Carp::Verbose = 1;
  ( $died ) = once(daemon_config('verbose', \@repositories));
  like $died, qr/$refusal.*\bcalled at\b/s, 'a verbose Carp adds its backtrace';
  hides_the_url($died, 'which is');
}

#### One rule for the event and the configuration

sub configuration_error {
  my ( $clone_url ) = @_;
  return dies { SimpiCI::App::Eventd->check_repositories(
    { repositories => [ repository('owner/project', $clone_url) ] }) };
}

sub event_error {
  my ( $clone_url ) = @_;
  return dies { SimpiCI::Event->new(source => 'git-poll', event => 'push',
    repository => 'owner/project', clone_url => $clone_url,
    ref => 'refs/heads/main', commit => 'a' x 40) };
}

for my $clone_url (
  'https://forge.invalid/owner/project.git',
  'https://forge.invalid/owner/pro@ject.git',
  'git@forge.invalid:owner/project.git',
  'ssh://git@forge.invalid/owner/project.git',
  'ssh://git@forge.invalid:2222/owner/project.git',
  'ssh://forge.invalid:2222/owner/pro:je@ct.git',
  'ssh://git@forge.invalid/owner/pro:je@ct.git',
  'ssh://git@[2001:db8::1]:2222/owner/project.git',
  'ssh://[2001:db8::1]:2222/owner/project.git',
  'ssh://@forge.invalid/owner/project.git',
  'git+ssh://git@forge.invalid/owner/project.git',
  'git://forge.invalid/owner/project.git',
  'ftp://anonymous@forge.invalid/owner/project.git',
  'forge.invalid:owner/pro@ject.git',
  'forge:pro@ject.git',
  'git@forge.invalid:owner/pro:ject.git',
  'git@[2001:db8::1]:owner/project.git',
  '[2001:db8::1]:owner/project.git',
  'file:///srv/git/us:er@project.git',
  '/srv/git/us:er@pro:ject.git',
  './us:er@pro:ject.git',
  '/srv/git/project.git'
) {
  is [ scalar SimpiCI::Event->clone_url_rejection($clone_url), configuration_error($clone_url), event_error($clone_url) ],
    [ undef, undef, undef ], 'accepted by the rule, the configuration and the event: '.$clone_url;
  is(SimpiCI::Event->clone_url_without_credentials($clone_url), $clone_url, 'and shown as it is');
}

for my $case (
  [ $private, qr/credentials/, 'user and token' ],
  [ 'https://'.$token.'@forge.invalid/owner/project.git', qr/credentials/, 'a lone token' ],
  [ 'http://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/credentials/, 'plain HTTP' ],
  [ 'HTTPS://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/credentials/, 'an upper-case scheme' ],
  [ 'https://@forge.invalid/owner/project.git', qr/credentials/, 'an empty user part over HTTPS' ],
  [ 'helper::https://'.$token.'@forge.invalid/owner/project.git', qr/credentials/, 'HTTPS behind a remote helper' ],
  [ $keyed, qr/a password/, 'a password over ssh' ],
  [ 'ssh://'.$user.':'.$token.'@forge.invalid:2222/owner/project.git', qr/a password/, 'a password ahead of a port' ],
  [ 'ssh://'.$user.':'.$token.'@[2001:db8::1]:2222/owner/project.git', qr/a password/, 'a password ahead of an IPv6 host' ],
  [ 'ssh://'.$user.':@forge.invalid/owner/project.git', qr/a password/, 'an empty password' ],
  [ 'ssh://:'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'a password without a user' ],
  [ 'ssh://'.$user.':to@ken@forge.invalid/owner/project.git', qr/a password/, 'a password with an @' ],
  [ 'ssh://'.$user.'%3A'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'a percent-encoded colon' ],
  [ 'ssh://'.$user.'%3a'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'a lower-case percent-encoded colon' ],
  [ 'SSH://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'an upper-case ssh scheme' ],
  [ 'git+ssh://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'a scheme with a plus' ],
  [ 'git://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'the git scheme' ],
  [ 'ftp://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'FTP' ],
  [ 'ftps://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'FTPS' ],
  [ 'helper::ssh://'.$user.':'.$token.'@forge.invalid/owner/project.git', qr/a password/, 'ssh behind a remote helper' ],
  [ $user.':'.$token.'@forge.invalid:owner/project.git', qr/a password/, 'user:password@host:path without a scheme' ],
  [ $user.':@forge.invalid:/srv/git/project.git', qr/a password/, 'that form with an empty password' ],
  [ 'https://forge.invalid/owner/pro ject.git', qr/whitespace or control characters/, 'a space' ],
  [ "https://forge.invalid/owner/project.git\n", qr/whitespace or control characters/, 'a newline' ],
  [ "https://forge.invalid/owner/\tproject.git", qr/whitespace or control characters/, 'a tab' ],
  [ "https://forge.invalid/owner/project.git\x7f", qr/whitespace or control characters/, 'a DEL' ],
  [ "https://forge.invalid/owner/project.git\0", qr/whitespace or control characters/, 'a NUL' ]
) {
  my ( $clone_url, $kind, $label ) = @$case;
  my $reason = SimpiCI::Event->clone_url_rejection($clone_url);
  like $reason, qr/\Aclone URL must not contain $kind/, 'the rule rejects '.$label;
  my $refused = configuration_error($clone_url);
  like $refused, qr/\ASimpiCI::App::Eventd repository owner\/project \(repositories\[0\]\): \Q$reason\E at /,
    'the configuration is refused for that reason';
  my $unbuilt = event_error($clone_url);
  like $unbuilt, qr/\ASimpiCI::Event \Q$reason\E at /, 'and so is the event';
  is scalar( grep { index($_, $clone_url) >= 0 || /forge\.invalid/ } $reason, $refused, $unbuilt ), 0,
    'none of them repeats the URL';
  my $shown = SimpiCI::Event->clone_url_without_credentials($clone_url);
  is scalar( grep { index($shown, $_) >= 0 } $user, $token, 'ken@', '@' ), 0,
    'and it is shown without its user part' unless $label =~ /\Aa (?:space|newline|tab|DEL|NUL)\z/;
}
is(SimpiCI::Event->clone_url_without_credentials($keyed), 'ssh://forge.invalid/owner/keyed.git',
  'what is shown is the rest of the URL');
is(SimpiCI::Event->clone_url_without_credentials($user.':'.$token.'@forge.invalid:owner/project.git'),
  'forge.invalid:owner/project.git', 'also without a scheme');

#### The example configurations

# The shapes the check refuses are in t/46-config-repositories.t.
for my $example (qw(
  etc/simpici.example.json etc/simpici.dispatcher.example.json
  deploy/dispatcher/dispatcher.example.json
)) {
  ok lives { SimpiCI::App::Eventd->check_repositories($json->decode(path($example)->slurp_utf8)) },
    'the example configuration passes: '.$example;
}

done_testing;
