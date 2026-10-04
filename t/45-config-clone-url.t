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
  'https://forge.invalid:8443/owner/project.git',
  'https://forge.invalid/owner/pro@ject.git',
  'http://forge.invalid/owner/project.git',
  'git@forge.invalid:owner/project.git',
  'ssh://git@forge.invalid/owner/project.git',
  'ssh://forge.invalid/owner/project.git',
  'ssh://git@forge.invalid:2222/owner/project.git',
  'ssh://forge.invalid:2222/owner/pro:je@ct.git',
  'ssh://git@forge.invalid/owner/pro:je@ct.git',
  'ssh://git@[2001:db8::1]:2222/owner/project.git',
  'ssh://[2001:db8::1]:2222/owner/project.git',
  'ssh://@forge.invalid/owner/project.git',
  'forge.invalid:owner/project.git',
  'forge.invalid:owner/pro@ject.git',
  'forge:pro@ject.git',
  'git@forge.invalid:owner/pro:ject.git',
  'git@forge.invalid:/srv/git/project.git',
  'git@[2001:db8::1]:owner/project.git',
  '[2001:db8::1]:owner/project.git',
  'file:///srv/git/project.git',
  'file:///srv/git/us:er@project.git',
  '/srv/git/us:er@pro:ject.git',
  '/srv/git/ext::project.git',
  '/srv/git/project.git'
) {
  is [ scalar SimpiCI::Event->clone_url_rejection($clone_url), configuration_error($clone_url), event_error($clone_url) ],
    [ undef, undef, undef ], 'accepted by the rule, the configuration and the event: '.$clone_url;
  is(SimpiCI::Event->clone_url_without_credentials($clone_url), $clone_url, 'and shown as it is');
}

# Each case: the URL, what the reason says, a name for it, and whether what
# is shown of the URL is the URL, because it has no user part to leave out.
my $credentials = 'must not contain credentials';
my $password = 'must not contain a password';
my $unprintable = 'must not contain whitespace or control characters';
my $dash = 'must not begin with "-"';
my $form = 'must be a URL of the scheme https, http, ssh or file,';
my %reasons;
for my $case (
  [ $private, $credentials, 'user and token' ],
  [ 'https://'.$token.'@forge.invalid/owner/project.git', $credentials, 'a lone token' ],
  [ 'http://'.$user.':'.$token.'@forge.invalid/owner/project.git', $credentials, 'plain HTTP' ],
  [ 'http://'.$token.'@forge.invalid/owner/project.git', $credentials, 'a lone token over plain HTTP' ],
  [ 'https://@forge.invalid/owner/project.git', $credentials, 'an empty user part over HTTPS' ],
  [ $keyed, $password, 'a password over ssh' ],
  [ 'ssh://'.$user.':'.$token.'@forge.invalid:2222/owner/project.git', $password, 'a password ahead of a port' ],
  [ 'ssh://'.$user.':'.$token.'@[2001:db8::1]:2222/owner/project.git', $password, 'a password ahead of an IPv6 host' ],
  [ 'ssh://'.$user.':@forge.invalid/owner/project.git', $password, 'an empty password' ],
  [ 'ssh://:'.$token.'@forge.invalid/owner/project.git', $password, 'a password without a user' ],
  [ 'ssh://'.$user.':to@ken@forge.invalid/owner/project.git', $password, 'a password with an @' ],
  [ 'ssh://'.$user.'%3A'.$token.'@forge.invalid/owner/project.git', $password, 'a percent-encoded colon' ],
  [ 'ssh://'.$user.'%3a'.$token.'@forge.invalid/owner/project.git', $password, 'a lower-case percent-encoded colon' ],
  [ 'file://'.$user.':'.$token.'@forge.invalid/srv/git/project.git', $password, 'a password in a file URL' ],
  [ $user.':'.$token.'@forge.invalid:owner/project.git', $password, 'user:password@host:path without a scheme' ],
  [ $user.':@forge.invalid:/srv/git/project.git', $password, 'that form with an empty password' ],
  [ 'https://forge.invalid/owner/pro ject.git', $unprintable, 'a space', 'as it is' ],
  [ "https://forge.invalid/owner/project.git\n", $unprintable, 'a newline', 'as it is' ],
  [ "https://forge.invalid/owner/\tproject.git", $unprintable, 'a tab', 'as it is' ],
  [ "https://forge.invalid/owner/project.git\x7f", $unprintable, 'a DEL', 'as it is' ],
  [ "https://forge.invalid/owner/project.git\0", $unprintable, 'a NUL', 'as it is' ],
  # What git would take for an option, at any of its commands.
  [ '--upload-pack=/srv/git/program', $dash, 'an option of git', 'as it is' ],
  [ '--tags', $dash, 'an option without a value', 'as it is' ],
  [ '-oProxyCommand=program:owner/project.git', $dash, 'an option of ssh in the place of a host', 'as it is' ],
  [ '-/srv/git/project.git', $dash, 'a path that begins with a dash', 'as it is' ],
  # A scheme git knows, but that is none of the four.
  [ 'git://forge.invalid/owner/project.git', $form, 'the git scheme', 'as it is' ],
  [ 'git://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'the git scheme with a password' ],
  [ 'git+ssh://git@forge.invalid/owner/project.git', $form, 'a scheme with a plus' ],
  [ 'ssh+git://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'the other one, with a password' ],
  [ 'ftp://anonymous@forge.invalid/owner/project.git', $form, 'FTP' ],
  [ 'ftp://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'FTP with a password' ],
  [ 'ftps://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'FTPS with a password' ],
  [ 'rsync://forge.invalid/owner/project.git', $form, 'rsync', 'as it is' ],
  # A scheme git does not know is the name of a program: git-remote-<scheme>.
  [ 'persistent-https://'.$token.'@forge.invalid/owner/project.git', $form, 'a lone token behind an HTTPS helper' ],
  [ 'persistent-https://forge.invalid/owner/project.git', $form, 'an HTTPS helper', 'as it is' ],
  [ 'HTTPS://forge.invalid/owner/project.git', $form, 'an upper-case scheme', 'as it is' ],
  [ 'HTTPS://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'an upper-case scheme with a token' ],
  [ 'Https://forge.invalid/owner/project.git', $form, 'a mixed-case scheme', 'as it is' ],
  [ 'SSH://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'an upper-case ssh scheme with a password' ],
  [ 'svn://forge.invalid/owner/project', $form, 'a scheme of another tool', 'as it is' ],
  # So is what stands ahead of "::".
  [ 'ext::program', $form, 'the helper that runs a command', 'as it is' ],
  [ 'ext::/srv/git/program', $form, 'that helper with a path', 'as it is' ],
  [ 'fd::17', $form, 'the helper that reads a descriptor', 'as it is' ],
  [ 'helper::https://forge.invalid/owner/project.git', $form, 'HTTPS behind a remote helper', 'as it is' ],
  [ 'helper::https://'.$token.'@forge.invalid/owner/project.git', $form, 'HTTPS with a token behind a remote helper' ],
  [ 'helper::ssh://'.$user.':'.$token.'@forge.invalid/owner/project.git', $form, 'ssh with a password behind a remote helper' ],
  [ 'helper::/srv/git/project.git', $form, 'a path behind a remote helper', 'as it is' ],
  [ 'https::forge.invalid/owner/project.git', $form, 'an accepted scheme as a remote helper', 'as it is' ],
  # A path that is not absolute is read from wherever git happens to run.
  [ 'srv/git/project.git', $form, 'a relative path', 'as it is' ],
  [ './srv/git/project.git', $form, 'a path below the working directory', 'as it is' ],
  [ '../srv/git/project.git', $form, 'a path above it', 'as it is' ],
  [ './us:er@pro:ject.git', $form, 'such a path with a colon', 'as it is' ],
  [ 'project.git', $form, 'a bare name', 'as it is' ],
  [ 'https//forge.invalid/owner/project.git', $form, 'a scheme without its colon', 'as it is' ],
  [ ':owner/project.git', $form, 'a path behind no host', 'as it is' ]
) {
  my ( $clone_url, $kind, $label, $as_it_is ) = @$case;
  my $reason = SimpiCI::Event->clone_url_rejection($clone_url);
  like $reason, qr/\Aclone URL \Q$kind\E/, 'the rule rejects '.$label;
  $reasons{ $reason // '' } = 1;
  my $refused = configuration_error($clone_url);
  like $refused, qr/\ASimpiCI::App::Eventd repository owner\/project \(repositories\[0\]\): \Q$reason\E at /,
    'the configuration is refused for that reason';
  my $unbuilt = event_error($clone_url);
  like $unbuilt, qr/\ASimpiCI::Event \Q$reason\E at /, 'and so is the event';
  is scalar( grep { index($_ // '', $clone_url) >= 0 || /forge\.invalid|srv\/git/ } $reason, $refused, $unbuilt ), 0,
    'none of them repeats the URL';
  my $shown = SimpiCI::Event->clone_url_without_credentials($clone_url);
  if ($as_it_is) {
    is $shown, $clone_url, 'and it has no user part to leave out';
  } else {
    is scalar( grep { index($shown, $_) >= 0 } $user, $token, 'ken@', '@' ), 0,
      'and it is shown without its user part';
  }
}
is(SimpiCI::Event->clone_url_without_credentials($keyed), 'ssh://forge.invalid/owner/keyed.git',
  'what is shown is the rest of the URL');
is(SimpiCI::Event->clone_url_without_credentials($user.':'.$token.'@forge.invalid:owner/project.git'),
  'forge.invalid:owner/project.git', 'also without a scheme');
is(SimpiCI::Event->clone_url_without_credentials('persistent-https://'.$token.'@forge.invalid/owner/project.git'),
  'persistent-https://forge.invalid/owner/project.git', 'and of a URL that is refused for its scheme');

# The schemes are named in one place, and the reason is made from it.
is [ SimpiCI::Event->can('clone_url_schemes') ? SimpiCI::Event->clone_url_schemes : () ],
  [qw( https http ssh file )], 'the accepted schemes';
is scalar( keys %reasons ), 5, 'the rule has five reasons';

#### The reasons in the documentation

# As a reader finds them: where the rule is described, each reason in full,
# as a line of its own in the manual and so not merely because the code of
# the module has it, and behind the repository in the operations guide.
{
  my %document = (
    'the manual of SimpiCI::Event' => [ path($INC{'SimpiCI/Event.pm'}), "\n  %s\n" ],
    'the operations guide'         => [ path('deploy/README.md'), "(repositories[0]): %s\n" ]
  );
  for my $name (sort keys %document) {
    my ( $file, $markup ) = $document{$name}->@*;
    next unless $file->is_file;
    my $text = $file->slurp_utf8;
    ok index($text, sprintf $markup, $_) >= 0, $name.' gives the reason: '.$_
      for grep { length } sort keys %reasons;
  }
}

#### A clone URL that git would not read as the address of a repository

# Readable through nothing: the daemon has to refuse these before it polls.
# A daemon that polls them gives the first to git as it stands, and git
# starts the program the second and the third name.
{
  my $started = $root->child('helper-started');
  my $programs = $root->child('programs');
  $programs->mkpath;
  my $helper = $programs->child('git-remote-simpicitest');
  $helper->spew_utf8("#!/bin/sh\necho started >> '".$started."'\nexit 1\n");
  $helper->chmod(0755);
  local $ENV{PATH} = $programs.':'.$ENV{PATH};
  # With the default of git for what a helper is allowed.
  delete local $ENV{GIT_ALLOW_PROTOCOL};
  for my $case (
    [ 'dash', '--upload-pack='.$helper, $dash ],
    [ 'helper', 'simpicitest::'.$good, $form ],
    [ 'scheme', 'simpicitest://forge.invalid/owner/project.git', $form ]
  ) {
    my ( $name, $clone_url, $kind ) = @$case;
    my @odd = ( repository('owner/good', $good), repository('owner/odd', $clone_url) );
    for my $mode (qw( local dispatcher )) {
      my $state = $name.'-'.$mode;
      ( $died, $status, $warnings ) = once(daemon_config($state, \@odd, mode => $mode));
      like $died, qr/\ASimpiCI::App::Eventd repository owner\/odd \(repositories\[1\]\): clone URL \Q$kind\E/,
        'simpicid does not start with '.$clone_url.', mode '.$mode;
      is $warnings, [], 'instead of reporting it as not polled in every cycle';
      is runs_of($state), [], 'the readable repository ahead of it is not built';
      ok !$root->child($state, 'queue')->exists, 'and nothing is queued';
    }
  }
  ok !$started->exists, 'git started no program a clone URL names';
}

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
