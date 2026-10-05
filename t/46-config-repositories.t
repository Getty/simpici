#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::Dispatcher;
use SimpiCI::Queue;
use SimpiCI::Store;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX ();

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

my $user = 'deploy-bot';
my $token = 's3cr3t-t0ken';
my $bare = 'https://'.$user.':'.$token.'@forge.invalid/owner/private.git';

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
  my ( %override ) = @_;
  return { name => 'owner/project', clone_url => '/srv/git/project.git',
    refs => ['refs/heads/main'], build_initial => JSON->true, %override };
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

# An entry of the wrong shape is refused by its position. What stands there
# may be the clone URL with its token, and must not be repeated.
sub hides_the_value {
  my ( $text, $label ) = @_;
  unlike $text, qr/\Q$token\E/, $label.' without the token';
  unlike $text, qr/\Q$user\E/, $label.' without the user name';
  unlike $text, qr/forge\.invalid/, $label.' without the rest of the value';
}

# The readable repository sits ahead of the bare URL, so a check that only
# comes with the poll shows as a run.
my $good = git_fixture('good');
local $ENV{GIT_ALLOW_PROTOCOL} = 'file';
my @repositories = ( repository(name => 'owner/good', clone_url => "$good"), $bare );
my $refusal = qr/repositories\[1\] must be an object at /;

#### A bare URL in place of a repository

for my $mode (qw( local dispatcher )) {
  my ( $died, $status, $warnings ) = once(daemon_config('bare-'.$mode, \@repositories,
    mode => $mode));
  like $died, qr/\ASimpiCI::App::Eventd $refusal/,
    'simpicid does not start with a string in place of a repository, mode '.$mode;
  hides_the_value($died // '', 'the message is');
  is [ $warnings, runs_of('bare-'.$mode) ], [ [], [] ],
    'the readable repository ahead of it is neither polled nor built';
  ok !$root->child('bare-'.$mode, 'state')->exists, 'and no observation is recorded';
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
hides_the_value($printed, 'everything it prints is');
is runs_of('process'), [], 'and it has built nothing';

#### A backtrace

{
  local $Carp::Verbose = 1;
  my ( $died ) = once(daemon_config('verbose', \@repositories));
  like $died, qr/repositories\[1\] must be an object.*\bcalled at\b/s,
    'a verbose Carp adds its backtrace';
  hides_the_value($died, 'which is');
}

#### The shapes that are refused

sub refused {
  my ( $config ) = @_;
  return dies { SimpiCI::App::Eventd->check_repositories($config) };
}

my $needs = 'repository needs name and clone_url';
for my $case (
  [ +{}, 'repositories must be a list', 'a configuration without repositories' ],
  [ { repositories => $bare }, 'repositories must be a list', 'a string in place of the list' ],
  [ { repositories => { name => 'owner/project', clone_url => $bare } },
    'repositories must be a list', 'an object in place of the list' ],
  [ { repositories => [ repository(), $bare ] }, 'repositories[1] must be an object', 'a bare URL' ],
  [ { repositories => [ [ $bare ] ] }, 'repositories[0] must be an object', 'a list as an entry' ],
  [ { repositories => [ undef ] }, 'repositories[0] must be an object', 'a null entry' ],
  [ { repositories => [ repository(), { clone_url => $bare } ] },
    'repository ? (repositories[1]): '.$needs, 'an entry without a name' ],
  [ { repositories => [ repository(name => '') ] },
    'repository  (repositories[0]): '.$needs, 'an empty name' ],
  [ { repositories => [ repository(name => { is => $bare }) ] },
    'repository ? (repositories[0]): '.$needs, 'an object as the name' ],
  [ { repositories => [ repository(name => JSON->true) ] },
    'repository ? (repositories[0]): '.$needs, 'a boolean as the name' ],
  [ { repositories => [ { name => 'owner/project', refs => [ $bare ] } ] },
    'repository owner/project (repositories[0]): '.$needs, 'an entry without a clone URL' ],
  [ { repositories => [ repository(clone_url => '') ] },
    'repository owner/project (repositories[0]): '.$needs, 'an empty clone URL' ],
  [ { repositories => [ repository(clone_url => [ $bare ]) ] },
    'repository owner/project (repositories[0]): '.$needs, 'a list as the clone URL' ],
  [ { repositories => [ repository(clone_url => { url => $bare }) ] },
    'repository owner/project (repositories[0]): '.$needs, 'an object as the clone URL' ]
) {
  my ( $config, $reason, $label ) = @$case;
  my $died = refused($config);
  like $died, qr/\ASimpiCI::App::Eventd \Q$reason\E at /, 'refuse '.$label;
  hides_the_value($died // '', 'the message is');
}

#### A name that is not one line of text

# SimpiCI::Event refuses a control character in the name of a repository.
# The daemon says so at its start, not when the repository first has
# something to build, and names the entry by its position only: the name
# would move the terminal it is printed on.
my $unprintable = 'name must not contain control characters';
for my $case (
  [ "owner/pro\tject", 'a tab' ], [ "owner/project\n", 'a line end' ],
  [ "owner/\rproject", 'a carriage return' ], [ "owner/pro\0ject", 'a NUL' ],
  [ "owner/pro\e[2Jject", 'an escape sequence' ], [ "owner/project\x7f", 'a DEL' ]
) {
  my ( $name, $label ) = @$case;
  my $died = refused({ repositories => [ repository(), repository(name => $name) ] });
  like $died, qr/\ASimpiCI::App::Eventd repository \? \(repositories\[1\]\): \Q$unprintable\E at /,
    'refuse '.$label.' in a name';
  unlike $died // '', qr/[\x00-\x09\x0b-\x1f\x7f]|ject/, 'without the name';
  my $unusable = refused({ repositories => [ { name => $name } ] });
  like $unusable, qr/\ASimpiCI::App::Eventd repository \? \(repositories\[0\]\): \Q$needs\E at /,
    'and such a name is not repeated for another mistake of its entry either';
}
is refused({ repositories => [ repository(name => "gr\x{fc}n/two words") ] }), undef,
  'a name with a space and a character beyond ASCII is accepted';

# With a repository that can be read and has a tip to build, so that a
# check that only comes with the event shows as a run.
{
  my @named = ( repository(name => 'owner/good', clone_url => "$good"),
    repository(name => "owner/go\tod", clone_url => "$good") );
  for my $mode (qw( local dispatcher )) {
    my ( $died, $status, $warnings ) = once(daemon_config('named-'.$mode, \@named, mode => $mode));
    like $died, qr/\ASimpiCI::App::Eventd repository \? \(repositories\[1\]\): \Q$unprintable\E at /,
      'simpicid does not start with a tab in the name of a repository, mode '.$mode;
    is [ $warnings, runs_of('named-'.$mode) ], [ [], [] ],
      'the repository ahead of it is neither polled nor built';
    ok !$root->child('named-'.$mode, 'queue')->exists, 'and nothing is queued';
  }
}

is refused({ repositories => [] }), undef, 'an empty list of repositories is accepted';
is refused({ repositories => [ { name => 'owner/project', clone_url => '/srv/git/project.git', refs => [] } ] }),
  undef, 'an entry with a name, a clone URL and a list of refs is accepted';

#### What is polled

# Without a list of refs every cycle would fail in the poller, with what Perl
# says about the value: the daemon says it at its start.
for my $case (
  [ sub { delete $_[0]{refs} }, 'an entry without refs' ],
  [ sub { $_[0]{refs} = 'refs/heads/'.$token }, 'a string as refs' ],
  [ sub { $_[0]{refs} = [ 'refs/heads/main', { $token => 1 } ] }, 'an object in refs' ],
  [ sub { $_[0]{build_initial} = 'not-'.$token }, 'a word as build_initial', 'build_initial must be true or false' ]
) {
  my ( $change, $label, $reason ) = @$case;
  my $entry = repository();
  $change->($entry);
  my $died = refused({ repositories => [ repository(), $entry ] });
  $reason //= 'refs must be a list of ref names or patterns';
  like $died, qr/\ASimpiCI::App::Eventd repository owner\/project \(repositories\[1\]\): \Q$reason\E at /,
    'refuse '.$label;
  hides_the_value($died // '', 'the message is');
}
{
  my @unpolled = ( repository(name => 'owner/good', clone_url => "$good"),
    { name => 'owner/refless', clone_url => "$good" } );
  for my $mode (qw( local dispatcher )) {
    my ( $died, $status, $warnings ) = once(daemon_config('refless-'.$mode, \@unpolled, mode => $mode));
    like $died, qr/\ASimpiCI::App::Eventd repository owner\/refless \(repositories\[1\]\): refs must be a list of ref names or patterns at /,
      'simpicid does not start with a repository without refs, mode '.$mode;
    is [ $warnings, runs_of('refless-'.$mode) ], [ [], [] ],
      'instead of reporting it as not polled in every cycle';
    ok !$root->child('refless-'.$mode, 'queue')->exists, 'and nothing is queued';
  }
}

#### One wording with the dispatcher

# simpici-dispatch reads the same file without the daemon in front of it. For
# the same mistake both say the same.
sub dispatcher_refusal {
  my ( $config ) = @_;
  return dies { SimpiCI::Dispatcher->new(config => $config, queue => SimpiCI::Queue->new(
    store => SimpiCI::Store->new(root => $root->child('unused'))))->validate };
}

sub words {
  my ( $message, $class ) = @_;
  return ( $message // '' ) =~ s/\A\Q$class\E //r =~ s/ at \S+ line \d+\.\n\z//r;
}

for my $config ( +{}, { repositories => $bare }, { repositories => [ repository(), $bare ] } ) {
  my $said = words(refused($config), 'SimpiCI::App::Eventd');
  like $said, qr/\Arepositories/, 'the daemon says: '.$said;
  is words(dispatcher_refusal($config), 'SimpiCI::Dispatcher'), $said, 'and so does the dispatcher';
}
my $unnamed = { repositories => [ { clone_url => '/srv/git/project.git', secrets => [
  { name => 'CICD_PACKAGE_TOKEN' } ] } ] };
is words(refused($unnamed), 'SimpiCI::App::Eventd'), 'repository ? (repositories[0]): '.$needs,
  'the daemon names an entry without a name by its position';
is words(dispatcher_refusal($unnamed), 'SimpiCI::Dispatcher'),
  'repository ? (repositories[0]), secret CICD_PACKAGE_TOKEN (secrets[0]): '.$needs,
  'and the dispatcher gives the same reason for its grant';

done_testing;
