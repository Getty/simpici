#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::Config;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;
use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );

# simpicid --check reads a configuration and says everything that is wrong
# with it, without polling: no remote is asked, no state is written and no
# queue is touched. It is the check the daemon makes when it starts, so what
# passes here starts, and what the daemon refuses is found here.

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $token = $root->child('package-token');
$token->spew_utf8("check-secret-value\n");
my $missing = $root->child('no-such-token');

# What stands in a wrong place may be a credential. No finding repeats it.
my $leak = 's3cr3t-t0ken';

sub repository {
  my ( %override ) = @_;
  return { name => 'owner/project', clone_url => '/srv/git/project.git',
    refs => ['refs/heads/main'], build_initial => JSON->true, %override };
}

sub grant {
  my ( %override ) = @_;
  return { name => 'CICD_PACKAGE_TOKEN', file => "$token", refs => ['refs/tags/*'],
    events => ['push'], phases => ['publish'], %override };
}

sub config_file {
  my ( $name, $content ) = @_;
  my $file = $root->child($name.'.json');
  $file->spew_utf8(ref $content ? $json->encode($content) : $content);
  return $file;
}

# A git that says it was started. Nothing here may start it.
my $bin = $root->child('bin');
$bin->mkpath;
my $started = $root->child('git-was-started');
$bin->child('git')->spew_utf8("#!/bin/sh\necho started >> '$started'\nexit 1\n");
$bin->child('git')->chmod(0755);
my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);

# bin/simpicid as a process: exit status, standard output, standard error.
# The git it finds is the one above, unless a case needs a remote that is
# read.
our $with_git = 0;
sub simpicid {
  my ( @arguments ) = @_;
  my %file = map { $_ => $root->child('process.'.$_) } qw( stdout stderr );
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    $ENV{PATH} = $bin.':'.$ENV{PATH} unless $with_git;
    open STDIN, '<', '/dev/null' or POSIX::_exit(97);
    open STDOUT, '>', $file{stdout}->stringify or POSIX::_exit(97);
    open STDERR, '>', $file{stderr}->stringify or POSIX::_exit(97);
    exec $^X, '-I'.path('lib')->absolute, path('bin/simpicid')->absolute->stringify, @arguments
      or POSIX::_exit(98);
  }
  # A check that went on into the daemon would poll for ever: it fails this
  # test instead of holding it up.
  my $deadline = time + 60;
  until (waitpid($pid, WNOHANG) == $pid) {
    if (time > $deadline) {
      kill 'KILL', $pid;
      waitpid($pid, 0);
      return ( 'no end within 60 s', $file{stdout}->slurp_utf8, $file{stderr}->slurp_utf8 );
    }
    sleep 0.02;
  }
  my $status = $?;
  return ( $status & 127 ? 'signal '.( $status & 127 ) : $status >> 8,
    $file{stdout}->slurp_utf8, $file{stderr}->slurp_utf8 );
}

sub check_process {
  my ( $config, @arguments ) = @_;
  return simpicid('--check', '--config', "$config", @arguments);
}

# Everything below a directory: path, mode, size, time of the last change.
sub tree {
  my ( $directory ) = @_;
  return {} unless $directory->exists;
  my %entry;
  $directory->visit(sub {
    my @stat = stat $_[0]->stringify;
    $entry{ $_[0]->relative($directory) } = join ' ', @stat[ 2, 7, 9 ];
  }, { recurse => 1 });
  return \%entry;
}

sub errors { [ ( SimpiCI::App::Eventd->check($_[0]) )[0]->@* ] }
sub warned { [ ( SimpiCI::App::Eventd->check($_[0]) )[1]->@* ] }

#### A configuration that can be used

for my $mode (qw( local dispatcher )) {
  my $state = $root->child('usable-'.$mode);
  my $config = config_file('usable-'.$mode, {
    mode => $mode, root => "$state", interval => 60, timeout => 900, ls_remote_timeout => 30,
    request_read_timeout => 30, runner => "$runner_script",
    repositories => [ repository(), repository(name => 'owner/tags', refs => [],
      build_initial => JSON->false, secrets => [ grant() ]) ]
  });
  is [ check_process($config) ], [ 0, '', '' ],
    'simpicid --check accepts a usable configuration without a word, mode '.$mode;
  ok !$state->exists, 'and does not create the state root';
  ok !$started->exists, 'and starts no git';
  is [ SimpiCI::App::Eventd->check($json->decode($config->slurp_utf8)) ], [ [], [] ],
    'the check itself finds nothing';
}

for my $example (qw( etc/simpici.example.json deploy/dispatcher/dispatcher.example.json
    etc/simpici.dispatcher.example.json )) {
  my $config = $json->decode(path($example)->slurp_utf8);
  $_->{file} = "$token" for map { ( $_->{secrets} // [] )->@* } $config->{repositories}->@*;
  is [ SimpiCI::App::Eventd->check($config) ], [ [], [] ], $example.' passes with its secret files in place';
}
{
  # As it stands in the repository, its secret file is not on this machine.
  my ( $status, $stdout, $stderr ) = check_process(path('etc/simpici.dispatcher.example.json'));
  is [ $status, $stdout ], [ 1, '' ], 'without them simpicid --check exits with 1 and prints nothing on standard output';
  is $stderr, 'simpicid: SimpiCI::Dispatcher repository Getty/simpici (repositories[0]), secret '
    .'CICD_REGISTRY_PASSWORD (secrets[0]): cannot read secret file: No such file or directory'."\n",
    'and one line on standard error that names the grant and the reason';
}

#### Nothing is polled and nothing is written

{
  # A state root that has a queue with a lease that ran out, a recorded tip
  # and a secret snapshot: the daemon would end the lease and remove the
  # snapshot at the start of a cycle.
  my $state = $root->child('existing');
  my $store = SimpiCI::Store->new(root => $state);
  my $queue = SimpiCI::Queue->new(store => $store, lease_seconds => 1);
  $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'owner/project',
    clone_url => '/srv/git/project.git', ref => 'refs/heads/main', commit => 'a' x 40));
  my $record = $queue->claim('vm');
  $record->{expires} = time - 60;
  $store->write_json('queue/1.json', $record);
  $store->write_json('claims/1.json', {});
  my $before = tree($state);
  my $config = config_file('existing', { mode => 'dispatcher', root => "$state",
    repositories => [ repository(clone_url => 'ssh://forge.invalid/owner/project.git',
      secrets => [ grant() ]) ] });
  is [ check_process($config) ], [ 0, '', '' ], 'simpicid --check passes on a state root that is in use';
  is tree($state), $before, 'and leaves every file of it as it was: no lease is ended, no snapshot removed';
  is $json->decode($state->child('queue/1.json')->slurp_utf8)->{state}, 'running',
    'the run whose lease ran out is still running';
  ok !$started->exists, 'no remote is read';
  is [ check_process($config, '--once') ], [ 0, '', '' ], 'with --once beside it, --check still only checks';
  is tree($state), $before, 'and still writes nothing';
}

#### Every finding in one run

{
  my $state = $root->child('many');
  my $config = config_file('many', {
    mode => 'dispatcher', root => "$state", interval => 0, timeout => 'soon',
    ls_remote_timeout => 1.5, request_read_timeout => [ 30 ], runner => '', intervall => 60,
    repositories => [
      'https://deploy:'.$leak.'@forge.invalid/owner/bare.git',
      { name => 'owner/a', clone_url => 'ext::'.$leak, refs => 'refs/heads/'.$leak },
      { name => 'owner/b', clone_url => '/srv/git/b.git', build_initial => 'no-'.$leak, ref => [],
        secrets => [ grant(name => 'CICD_ONE', file => "$missing"),
          grant(name => 'CICD_TWO', refs => []), grant(name => 'CICD_THREE', phase => 'publish') ] }
    ]
  });
  my ( $status, $stdout, $stderr ) = check_process($config);
  is [ $status, $stdout ], [ 1, '' ], 'a configuration with many mistakes fails the check';
  my $e = 'simpicid: SimpiCI::App::Eventd ';
  my $d = 'simpicid: SimpiCI::Dispatcher ';
  is [ split /\n/, $stderr ], [
    $e.'interval must be a positive integer',
    $e.'timeout must be a positive integer',
    $e.'ls_remote_timeout must be a positive integer',
    $e.'request_read_timeout must be a positive integer',
    $e.'runner must be a nonempty string',
    $e.'repositories[0] must be an object',
    $e.'repository owner/a (repositories[1]): clone URL must be a URL of the scheme https, http, ssh or file, '
      .'an SSH address of the form [user@]host:path or an absolute path',
    $e.'repository owner/a (repositories[1]): refs must be a list of ref names or patterns',
    $e.'repository owner/b (repositories[2]): refs must be a list of ref names or patterns',
    $e.'repository owner/b (repositories[2]): build_initial must be true or false',
    $d.'repository owner/b (repositories[2]), secret CICD_ONE (secrets[0]): cannot read secret file: '
      .'No such file or directory',
    $d.'repository owner/b (repositories[2]), secret CICD_TWO (secrets[1]): refs must name at least one '
      .'ref or pattern: the grant would apply to no run',
    'simpicid: warning: SimpiCI::App::Eventd unknown key intervall',
    'simpicid: warning: SimpiCI::App::Eventd repository owner/b (repositories[2]): unknown key ref',
    'simpicid: warning: SimpiCI::App::Eventd repository owner/b (repositories[2]), secret CICD_THREE '
      .'(secrets[2]): unknown key phase'
  ], 'and every one of them has its line on standard error, the errors first';
  unlike $stderr, qr/\Q$leak\E|forge\.invalid|\Q$missing\E/, 'no line repeats a value or the path of a secret file';
  unlike $stderr, qr/ at \S+ line \d+/, 'or says where in the installation it was found';
  ok !$state->exists, 'nothing is written';
}

#### Unknown keys

{
  my $state = $root->child('unknown');
  my %config = ( root => "$state", comment => 'poll '.$leak, "odd\e[2Jkey" => 1,
    repositories => [ repository(clone_url => path('lib')->absolute->stringify, branch => 'main') ] );
  my ( $status, $stdout, $stderr ) = check_process(config_file('unknown', \%config));
  is [ $status, $stdout ], [ 0, '' ], 'a key the configuration does not know is no error of the check';
  is [ sort split /\n/, $stderr ], [
    'simpicid: warning: SimpiCI::App::Eventd repository owner/project (repositories[0]): unknown key branch',
    'simpicid: warning: SimpiCI::App::Eventd unknown key ?',
    'simpicid: warning: SimpiCI::App::Eventd unknown key comment'
  ], 'it gets a warning that names the key, if the key is a word, and never its value';
  # The daemon goes on with such a configuration, as it always did, and says
  # nothing: what it reads there is a repository that is no repository.
  my ( $daemon, undef, $said ) = simpicid('--config', config_file('unknown', \%config)->stringify, '--once');
  is $daemon, 1, 'the daemon starts with it and polls';
  unlike $said, qr/unknown key/, 'without the warning';
  ok $started->exists, 'git was started for the repository';
  $started->remove;
}

#### The file

{
  my ( $status, $stdout, $stderr ) = check_process($root->child('no-such-file.json'));
  is [ $status, $stdout, $stderr ],
    [ 1, '', 'simpicid: SimpiCI::App::Eventd cannot read the configuration: No such file or directory'."\n" ],
    'a file that is not there fails the check with one line';
  ( $status, $stdout, $stderr ) = check_process(config_file('broken',
    '{ "root": "/srv/simpici", "token": "'.$leak.'", '));
  is [ $status, $stdout ], [ 1, '' ], 'so does a file that is no JSON';
  like $stderr, qr/\Asimpicid: SimpiCI::App::Eventd configuration is no JSON: the decoder stopped at character [0-9]+\n\z/,
    'with the place the decoder stopped at';
  unlike $stderr, qr/\Q$leak\E|srv/, 'and nothing of its text';
  for my $case ( [ '[]', 'a list' ], [ '"'.$leak.'"', 'a string' ], [ 'null', 'null' ], [ '17', 'a number' ] ) {
    my ( $text, $label ) = @$case;
    is [ check_process(config_file('top', $text)) ],
      [ 1, '', 'simpicid: SimpiCI::App::Eventd configuration must be an object'."\n" ],
      $label.' in place of the configuration is refused without its value';
  }
  ( $status, $stdout, $stderr ) = simpicid('--check');
  is $status, 64, 'simpicid --check without a configuration is a mistake of the call, exit status 64';
  like $stderr, qr/A configuration file is required/, 'and says what is missing';
}

#### The settings

my @no_seconds = ( [ 0, 'zero' ], [ -1, 'a negative number' ], [ 1.5, 'a fraction' ],
  [ $leak, 'a word' ], [ '', 'an empty string' ], [ [ 30 ], 'a list' ], [ { $leak => 1 }, 'an object' ],
  [ JSON->true, 'true' ], [ '30s', 'a number with a unit' ], [ '030', 'a number with a leading zero' ] );
for my $setting (qw( interval timeout ls_remote_timeout request_read_timeout )) {
  for my $case (@no_seconds) {
    my ( $value, $label ) = @$case;
    for my $mode (qw( local dispatcher )) {
      is errors({ mode => $mode, root => '/srv/simpici', $setting => $value, repositories => [] }),
        [ 'SimpiCI::App::Eventd '.$setting.' must be a positive integer' ],
        $label.' as '.$setting.' is refused in '.$mode.' mode, without the value';
    }
  }
  for my $value (1, 60, '60', undef) {
    is errors({ $setting => $value, repositories => [] }), [],
      ( $value // 'null' ).' as '.$setting.' is accepted';
  }
}
for my $case ( [ 'remote', 'another word' ], [ 'Dispatcher', 'another spelling' ], [ '', 'an empty string' ],
    [ [ 'dispatcher' ], 'a list' ], [ JSON->true, 'true' ], [ 1, 'a number' ] ) {
  my ( $value, $label ) = @$case;
  is errors({ root => '/srv/simpici', mode => $value, repositories => [ repository(secrets => 'none') ] }),
    [ 'SimpiCI::App::Eventd mode must be "local" or "dispatcher"' ],
    $label.' as mode is refused, and the grants of neither mode are looked at';
}
for my $case ( [ '', 'an empty string' ], [ [ '/srv' ], 'a list' ], [ {}, 'an object' ], [ JSON->false, 'false' ] ) {
  my ( $value, $label ) = @$case;
  is errors({ root => $value, repositories => [] }), [ 'SimpiCI::App::Eventd root must be a nonempty string' ],
    $label.' as root is refused';
  is errors({ runner => $value, repositories => [] }), [ 'SimpiCI::App::Eventd runner must be a nonempty string' ],
    $label.' as runner is refused';
}
is errors({ mode => 'dispatcher', repositories => [] }), [ 'SimpiCI::App::Eventd root is required in dispatcher mode' ],
  'a dispatcher without a root is refused: simpici-dispatch has no default for it';
is errors({ repositories => [] }), [], 'in local mode the root has its default';
is errors($_), [ 'SimpiCI::App::Eventd configuration must be an object' ], 'what is no object is no configuration'
  for [], $leak, undef, 17;
is [ SimpiCI::Config->setting_names ],
  [qw( mode root interval timeout ls_remote_timeout request_read_timeout runner )],
  'these are the settings, in the order they are reported';

#### The entries of repositories

for my $case (
  [ { refs => undef }, 'no refs' ], [ { refs => 'refs/heads/'.$leak }, 'a string as refs' ],
  [ { refs => { $leak => 1 } }, 'an object as refs' ], [ { refs => [ 'refs/heads/main', [ $leak ] ] }, 'a list in refs' ],
  [ { refs => [ '' ] }, 'an empty string in refs' ], [ { refs => [ undef ] }, 'null in refs' ],
  [ { refs => [ JSON->true ] }, 'true in refs' ]
) {
  my ( $override, $label ) = @$case;
  my %entry = repository()->%*;
  delete $entry{refs};
  is errors({ repositories => [ repository(), { %entry, %$override } ] }),
    [ 'SimpiCI::App::Eventd repository owner/project (repositories[1]): refs must be a list of ref names or patterns' ],
    $label.' is refused where the daemon starts, not in every cycle';
}
is errors({ repositories => [ repository(refs => []) ] }), [], 'an empty list of refs polls every ref and is accepted';
for my $case ( [ 'no-'.$leak, 'a word' ], [ 'false', 'the word false' ], [ 2, 'another number' ],
    [ [], 'a list' ], [ {}, 'an object' ] ) {
  my ( $value, $label ) = @$case;
  is errors({ repositories => [ repository(build_initial => $value) ] }),
    [ 'SimpiCI::App::Eventd repository owner/project (repositories[0]): build_initial must be true or false' ],
    $label.' as build_initial is refused';
}
is errors({ repositories => [ repository(build_initial => $_) ] }), [], 'build_initial takes '.$_
  for JSON->true, JSON->false, 1, 0;
{
  my %entry = repository()->%*;
  delete $entry{build_initial};
  is errors({ repositories => [ \%entry ] }), [], 'and may be left out';
}
is errors({ repositories => [ repository(name => "owner/\tproject", clone_url => 'ext::'.$leak, refs => 7,
    build_initial => 'x') ] }), [ map { 'SimpiCI::App::Eventd repository ? (repositories[0]): '.$_ }
      'name must not contain control characters',
      'clone URL must be a URL of the scheme https, http, ssh or file, an SSH address of the form '
        .'[user@]host:path or an absolute path',
      'refs must be a list of ref names or patterns', 'build_initial must be true or false' ],
  'every mistake of one entry is found, not only its first';

#### Grants

for my $mode (qw( local dispatcher )) {
  my $config = { mode => $mode, root => '/srv/simpici', repositories => [ repository(),
    repository(name => 'owner/other', secrets => [ grant(file => "$missing"), grant(name => 'lower') ]) ] };
  is errors($config), $mode eq 'local' ? [] : [
    'SimpiCI::Dispatcher repository owner/other (repositories[1]), secret CICD_PACKAGE_TOKEN (secrets[0]): '
      .'cannot read secret file: No such file or directory',
    'SimpiCI::Dispatcher repository owner/other (repositories[1]), secret ? (secrets[1]): invalid secret name'
  ], $mode eq 'local' ? 'local mode does not evaluate grants' : 'dispatcher mode finds every unusable grant';
}
SKIP: {
  skip 'the superuser reads every file', 1 unless $>;
  my $unreadable = $root->child('unreadable-token');
  $unreadable->spew_utf8("value\n");
  $unreadable->chmod(0000);
  is errors({ mode => 'dispatcher', root => '/srv/simpici',
    repositories => [ repository(secrets => [ grant(file => "$unreadable") ]) ] }),
    [ 'SimpiCI::Dispatcher repository owner/project (repositories[0]), secret CICD_PACKAGE_TOKEN (secrets[0]): '
      .'cannot read secret file: Permission denied' ],
    'a secret file the account cannot read is found by the check of that account';
}
# What the daemon reports about an entry is not said a second time for
# each of its grants.
is errors({ mode => 'dispatcher', root => '/srv/simpici', repositories => [ $leak,
    { name => 'owner/urlless', refs => [], secrets => [ grant() ] } ] }),
  [ 'SimpiCI::App::Eventd repositories[0] must be an object',
    'SimpiCI::App::Eventd repository owner/urlless (repositories[1]): repository needs name and clone_url' ],
  'a mistake of an entry is reported once, not again for its grants';

#### The daemon makes this check when it starts

my $good = $root->child('good');
{
  delete local $ENV{GIT_DIR};
  system('git', 'init', '-q', '-b', 'main', "$good") == 0 or croak 'git init failed';
  system('git', '-C', "$good", '-c', 'user.name=SimpiCI Test', '-c', 'user.email=test@example.invalid',
    'commit', '-q', '--allow-empty', '-m', 'fixture') == 0 or croak 'git commit failed';
}

my $case_number = 0;
for my $case (
  [ { timeout => $leak }, 'a timeout that is a word' ],
  [ { timeout => 1.5 }, 'a timeout that is a fraction' ],
  [ { interval => 0 }, 'an interval of zero' ],
  [ { ls_remote_timeout => [ 1 ] }, 'a list as ls_remote_timeout' ],
  [ { request_read_timeout => 'no' }, 'a word as request_read_timeout' ],
  [ { mode => 'remote' }, 'another mode' ],
  [ { runner => [] }, 'a list as runner' ],
  [ { repositories => [ repository(name => 'owner/good', clone_url => "$good"),
      { name => 'owner/refless', clone_url => "$good" } ] }, 'a repository without refs' ],
  [ { repositories => [ repository(name => 'owner/good', clone_url => "$good"),
      repository(clone_url => "$good", refs => 'refs/heads/'.$leak) ] }, 'refs that are a string' ],
  [ { repositories => [ repository(name => 'owner/good', clone_url => "$good"),
      repository(clone_url => "$good", build_initial => 'yes') ] }, 'build_initial that is a word' ]
) {
  my ( $override, $label ) = @$case;
  for my $mode (qw( local dispatcher )) {
    my $state = $root->child('start-'.++$case_number);
    my %config = ( mode => $mode, root => "$state",
      repositories => [ repository(name => 'owner/good', clone_url => "$good") ], %$override );
    my $file = config_file('start', \%config);
    my $found = errors($json->decode($file->slurp_utf8));
    is scalar(@$found), 1, 'the check has one finding for '.$label;
    my ( $status, $warnings );
    my $died = dies {
      $warnings = warnings {
        $status = SimpiCI::App::Eventd->run('--config', "$file", '--once', '--runner', "$runner_script");
      };
    };
    like $died, qr/\A\Q$found->[0]\E at \S+ line \d+\.\n\z/,
      'simpicid does not start with it and says the same, in '.( $config{mode} // 'local' ).' mode';
    unlike $died // '', qr/\Q$leak\E/, 'without the value';
    is [ $warnings // [], $state->exists ? 1 : 0 ], [ [], 0 ],
      'and has neither polled nor built the repository ahead of the mistake';
  }
}
{
  my $state = $root->child('start-process');
  my ( $status, $stdout, $stderr ) = simpicid('--config', config_file('start-process',
    { root => "$state", timeout => $leak, repositories => [ repository(clone_url => "$good") ] })->stringify,
    '--once', '--runner', "$runner_script");
  is $status, 3, 'bin/simpicid exits with the status 3, not with the errno of the moment';
  like $stderr, qr/\ASimpiCI::App::Eventd timeout must be a positive integer at \S+ line \d+\.\n\z/,
    'with the finding as its one line';
  ok !$state->exists && !$started->exists, 'before it has read a repository';

  # The same status for what ends the daemon later: here, recorded tips
  # that cannot be read. A die would leave the errno of the moment, which
  # may be the 1 that --once and --check mean something by.
  my $entry = repository(clone_url => "$good");
  my $broken = $root->child('broken-state');
  $broken->child('state', 'repositories',
    sha256_hex(join "\0", $entry->@{qw( name clone_url )}).'.json')->touchpath->spew_utf8('{"tips":');
  {
    local $with_git = 1;
    ( $status, $stdout, $stderr ) = simpicid('--config', config_file('broken-state',
      { root => "$broken", repositories => [ $entry ] })->stringify, '--once', '--runner', "$runner_script");
  }
  is $status, 3, 'a daemon that ends over a state it cannot read exits with 3 as well';
  like $stderr, qr/\S/, 'and says why';
}

#### The manual

{
  my $help = qx{"$^X" -Ilib bin/simpicid --help 2>&1};
  like $help, qr/--check/, 'simpicid --help names --check';
}

done_testing;
