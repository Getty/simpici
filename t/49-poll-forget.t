#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::App::Eventd;
use SimpiCI::App::Run;
use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep time );

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);

sub git {
  my ( $fixture, @command ) = @_;
  system('git', '-C', "$fixture", '-c', 'user.name=SimpiCI Test',
    '-c', 'user.email=test@example.invalid', @command) == 0
    or croak 'git '.$command[0].' failed';
}

# An empty commit on the branch, and its id.
sub commit {
  my ( $fixture, $message ) = @_;
  git($fixture, 'commit', '-q', '--allow-empty', '-m', $message);
  my $id = qx{git -C "$fixture" rev-parse HEAD};
  chomp $id;
  croak 'git rev-parse failed' unless $id =~ /\A[0-9a-f]{40,64}\z/;
  return $id;
}

sub git_fixture {
  my ( $name ) = @_;
  my $fixture = $root->child($name.'.git');
  system('git', 'init', '-q', '-b', 'main', "$fixture") == 0 or croak 'git init failed';
  return $fixture;
}

sub repository {
  my ( $name, $fixture ) = @_;
  return { name => 'owner/'.$name, clone_url => "$fixture",
    refs => ['refs/heads/*', 'refs/tags/*'], build_initial => JSON->false };
}

# A configuration with a state root of its name.
sub configure {
  my ( $state, $repositories, %top ) = @_;
  my $config = $root->child($state.'.json');
  $config->spew_utf8($json->encode({
    root => $root->child($state)->stringify, %top, repositories => $repositories
  }));
  return $config;
}

sub state_file {
  my ( $state, $repository ) = @_;
  return $root->child($state, 'state', 'repositories',
    sha256_hex(join "\0", $repository->@{qw( name clone_url )}).'.json');
}

# Ref and commit of every run in a state root, in run order. The queue of the
# dispatcher mode projects what it accepted to the same place.
sub runs_of {
  my ( $state ) = @_;
  my $directory = $root->child($state, 'public', 'runs');
  return [] unless $directory->is_dir;
  return [ map { join ' ', $json->decode($_->slurp_utf8)->@{qw( ref commit )} }
    sort { $a->basename('.json') <=> $b->basename('.json') }
    grep { $_->basename =~ /\A[1-9][0-9]*\.json\z/ } $directory->children ];
}

my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8("#!/bin/sh\nexit 0\n");
$runner_script->chmod(0755);

# One polling cycle in this process: what it returned, what it warned, and
# what it died of.
sub once {
  my ( $config ) = @_;
  my ( $status, $warnings );
  my $died = dies {
    $warnings = warnings {
      $status = SimpiCI::App::Eventd->run('--config', "$config", '--once',
        '--runner', "$runner_script");
    };
  };
  return [ $died, $status, $warnings // [] ];
}

my $quiet = [ undef, 0, [] ];

# A program of the checkout as a process of its own, its two outputs in
# files beside each other.
my %running;
my $spawned = 0;
sub spawn {
  my ( $program, @arguments ) = @_;
  my $output = $root->child('process.'.++$spawned);
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDOUT, '>', $output.'.out' or POSIX::_exit(97);
    open STDERR, '>', $output.'.err' or POSIX::_exit(97);
    exec $^X, '-I'.path('lib')->absolute, path('bin', $program)->absolute->stringify, @arguments
      or POSIX::_exit(98);
  }
  $running{$pid} = $output;
  return $pid;
}

# Exit status and both outputs of a process once it has ended, or nothing if
# it is still running after the seconds given.
sub ended {
  my ( $pid, $seconds ) = @_;
  my $deadline = time + $seconds;
  while (waitpid($pid, WNOHANG) == 0) {
    return if time >= $deadline;
    sleep 0.05;
  }
  my $exit = $? >> 8;
  my $output = delete $running{$pid};
  return [ $exit, path($output.'.out')->slurp_utf8, path($output.'.err')->slurp_utf8 ];
}

END {
  for my $pid (keys %running) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
  }
}

# A request for the recorded tips in this process: what it returned and what
# it printed on either output.
sub simpici {
  my @arguments = @_;
  my ( $printed, $complained ) = ( '', '' );
  my $status = do {
    local ( *STDOUT, *STDERR );
    open STDOUT, '>', \$printed or croak 'cannot capture standard output';
    open STDERR, '>', \$complained or croak 'cannot capture standard error';
    SimpiCI::App::Run->run(@arguments);
  };
  return [ $status, $printed, $complained ];
}

# The same from the program, for what only a process shows.
sub program { ended(spawn('simpici', @_), 30) // croak 'simpici did not end' }

sub wait_for {
  my ( $file ) = @_;
  my $deadline = time + 30;
  until ($file->exists) {
    croak $file.' did not appear' if time > $deadline;
    sleep 0.05;
  }
}

# An executor that says when its run has started and ends when it is told to.
sub held_runner {
  my ( $name ) = @_;
  my ( $script, $started, $release ) = map { $root->child($name.'.'.$_) } qw( sh started release );
  $script->spew_utf8("#!/bin/sh\n: > '$started'\nwhile [ ! -e '$release' ]; do sleep 0.1; done\nexit 0\n");
  $script->chmod(0755);
  return ( $script, $started, $release );
}

my $id = qr/[0-9a-f]{64}/;

#### One ref is forgotten, by the names the configuration has

for my $mode (qw( local dispatcher )) {
  my $fixture = git_fixture($mode);
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'old');
  my $repository = repository($mode, $fixture);
  my $config = configure($mode, [ $repository ], mode => $mode);
  my $state = state_file($mode, $repository);
  my $recorded = sub { $json->decode($state->slurp_utf8) };
  my $named = 'repository owner/'.$mode.' ('.$fixture.')';
  my @forget = ( '--config', "$config", '--repository', 'owner/'.$mode, '--forget' );

  #### Nothing is recorded yet

  is simpici('--config', "$config", '--state'), [ 0, $named.": nothing recorded\n", '' ],
    $mode.': a repository that was never polled is shown without a state';
  is simpici(@forget, 'refs/tags/old'), [ 1, '', 'simpici: '.$named.": nothing is recorded\n" ],
    $mode.': and has nothing to forget';
  ok !$root->child($mode, 'state')->exists, $mode.': asking leaves no state behind';

  #### What is recorded

  is once($config), $quiet, $mode.': the baseline cycle is quiet';
  is runs_of($mode), [], $mode.': and builds neither the branch nor the tag';
  my $summary = qr/\Q$named\E: recorded refs: 2, absent at the last poll: 0, state\/repositories\/$id\.json, [1-9][0-9]* bytes\n/;
  my $shown = simpici('--config', "$config", '--state');
  like $shown->[1], qr/\A$summary\z/, $mode.': the state of a repository is one line';
  is [ $shown->@[ 0, 2 ] ], [ 0, '' ], $mode.': on standard output, with the exit status 0';
  like $shown->[1], qr/, \Q@{[ $state->relative($root->child($mode)) ]}\E, @{[ -s "$state" ]} bytes$/,
    $mode.': naming the file and its size';
  is simpici('--config', "$config", '--state', '--repository', 'owner/'.$mode)->[1],
    $shown->[1].'  refs/heads/main '.$first."\n".'  refs/tags/old '.$first."\n",
    $mode.': with the repository named, its refs and their tips follow';

  #### What cannot be forgotten

  my $before = $state->slurp_utf8;
  is simpici('--config', "$config", '--repository', 'owner/nowhere', '--forget', 'refs/tags/old'),
    [ 2, '', 'simpici: repository owner/nowhere is not configured in '.$config."\n" ],
    $mode.': a repository the configuration does not have is refused with the exit status 2';
  is simpici('--config', "$config", '--state', '--repository', 'owner/nowhere')->[0], 2,
    $mode.': also when its state is asked for';
  is simpici(@forget, 'refs/tags/never'),
    [ 1, '', 'simpici: '.$named.": refs/tags/never is not recorded\n" ],
    $mode.': a ref that is not recorded is reported with the exit status 1';
  is simpici(@forget, 'refs/tags/*')->[0], 1, $mode.': a pattern is a name that is not recorded';
  is $state->slurp_utf8, $before, $mode.': none of them changes the state';

  #### A ref the repository still has

  is simpici(@forget, 'refs/tags/old'),
    [ 0, $named.': forgot refs/tags/old, recorded at '.$first."\n", '' ],
    $mode.': a recorded ref is forgotten with the exit status 0';
  is $recorded->(), { tips => { 'refs/heads/main' => $first }, absent => [] },
    $mode.': it is out of the state, the other ref is not';
  is simpici(@forget, 'refs/tags/old')->[0], 1, $mode.': and cannot be forgotten twice';

  is once($config), $quiet, $mode.': the next cycle is quiet';
  is runs_of($mode), ['refs/tags/old '.$first],
    $mode.': and builds the forgotten ref as a new one, whatever build_initial says';
  is $recorded->()->{tips}{'refs/tags/old'}, $first, $mode.': which is recorded again';
  once($config);
  is scalar(runs_of($mode)->@*), 1, $mode.': and not built a second time';

  # The same commit again: the local runner builds it, the queue has it.
  simpici(@forget, 'refs/tags/old');
  once($config);
  is scalar(runs_of($mode)->@*), $mode eq 'local' ? 2 : 1,
    $mode.': forgotten again on the same commit, it is '
      .( $mode eq 'local' ? 'built again' : 'the run the queue already has' );
  my $built = scalar(runs_of($mode)->@*);

  #### A ref the repository no longer has

  git($fixture, 'branch', 'short');
  once($config);
  is runs_of($mode)->[-1], 'refs/heads/short '.$first, $mode.': a short-lived branch is built';
  git($fixture, 'update-ref', '-d', 'refs/heads/short');
  is once($config), $quiet, $mode.': the cycle after its end is quiet';
  $shown = simpici('--config', "$config", '--state', '--repository', 'owner/'.$mode);
  like $shown->[1], qr/: recorded refs: 3, absent at the last poll: 1, /,
    $mode.': the state still has it, as absent';
  like $shown->[1], qr/^  refs\/heads\/short \Q$first\E absent$/m, $mode.': which its line says';
  is simpici(@forget, 'refs/heads/short')->[0], 0, $mode.': it is forgotten like any other';
  is once($config), $quiet, $mode.': the next cycle is quiet';
  is scalar(runs_of($mode)->@*), $built + 1, $mode.': and builds nothing for it';
  is [ sort keys $recorded->()->{tips}->%* ], ['refs/heads/main', 'refs/tags/old'],
    $mode.': the state is smaller by the one ref';

  #### Every ref

  simpici(@forget, $_) for 'refs/heads/main', 'refs/tags/old';
  is $recorded->(), { tips => {}, absent => [] },
    $mode.': a state without refs stays a state';
  is once($config), $quiet, $mode.': the cycle over it is quiet';
  is scalar(grep { $_ eq 'refs/heads/main '.$first } runs_of($mode)->@*), 1,
    $mode.': the branch that was only ever a baseline is built now';
  is [ sort keys $recorded->()->{tips}->%* ], ['refs/heads/main', 'refs/tags/old'],
    $mode.': and both refs are recorded again';
}

#### One name, two clone URLs

{
  my $fixture = git_fixture('twice');
  my $first = commit($fixture, 'first');
  my @repositories = ( repository('twice', $fixture), repository('twice', $fixture.'/.') );
  my $config = configure('twice', \@repositories);
  my @named = map { 'repository owner/twice ('.$_->{clone_url}.')' } @repositories;
  once($config);
  is simpici('--config', "$config", '--state', '--repository', 'owner/twice')->[1],
    join('', map {
      my $file = state_file('twice', $repositories[$_]);
      $named[$_].': recorded refs: 1, absent at the last poll: 0, state/repositories/'
        .$file->basename.', '.( -s "$file" ).' bytes'."\n".'  refs/heads/main '.$first."\n"
    } 0, 1),
    'a name that is configured twice shows the state of either entry';
  state_file('twice', $repositories[1])->remove;
  is simpici('--config', "$config", '--repository', 'owner/twice', '--forget', 'refs/heads/main'),
    [ 0, $named[0].': forgot refs/heads/main, recorded at '.$first."\n",
      'simpici: '.$named[1].": nothing is recorded\n" ],
    'and a ref is forgotten for every entry that has it: 0 if one had';
}

#### The program

{
  my $fixture = git_fixture('program');
  my $first = commit($fixture, 'first');
  my $repository = repository('program', $fixture);
  my $config = configure('program', [ $repository ]);
  my $named = 'repository owner/program ('.$fixture.')';
  once($config);
  my @forget = ( '--config', "$config", '--repository', 'owner/program', '--forget' );
  # Started with the umask of an operator, not with the one of this test.
  my $private = umask 0022;
  my $forgotten = program(@forget, 'refs/heads/main');
  umask $private;
  is $forgotten, [ 0, $named.': forgot refs/heads/main, recorded at '.$first."\n", '' ],
    'bin/simpici forgets a ref, says so on standard output and exits with 0';
  is program(@forget, 'refs/heads/main'),
    [ 1, '', 'simpici: '.$named.": refs/heads/main is not recorded\n" ],
    'exits with 1 and a line on standard error for a ref that is not recorded';
  is program('--config', "$config", '--repository', 'owner/other', '--forget', 'refs/heads/main'),
    [ 2, '', 'simpici: repository owner/other is not configured in '.$config."\n" ],
    'and with 2 for a repository that is not configured';
  is [ stat state_file('program', $repository)->stringify ]->[2] & 07777, 0600,
    'the state it wrote is private';
  like program('--config', "$config", '--state')->[1],
    qr/\A\Q$named\E: recorded refs: 0, absent at the last poll: 0, /, 'it shows the state too';
}

#### What is not a request

{
  my $fixture = git_fixture('usage');
  my $config = configure('usage', [ repository('usage', $fixture) ]);
  for my $case (
    [ 'forget without a configuration', '--repository', 'owner/usage', '--forget', 'refs/heads/main' ],
    [ 'forget without a repository', '--config', "$config", '--forget', 'refs/heads/main' ],
    [ 'a repository without a request', '--config', "$config", '--repository', 'owner/usage' ],
    [ 'a configuration alone', '--config', "$config" ],
    [ 'state and forget together', '--config', "$config", '--state', '--repository', 'owner/usage',
      '--forget', 'refs/heads/main' ],
    [ 'an event with a state request', '--event', "$config", '--config', "$config", '--state' ],
    [ 'an argument that is no option', '--config', "$config", '--state', 'owner/usage' ]
  ) {
    my ( $what, @arguments ) = @$case;
    my $outcome = program(@arguments);
    is $outcome->[0], 64, $what.' is a usage error';
    like $outcome->[2], qr/^Usage:/m, 'answered with the usage';
  }
  ok !$root->child('usage')->exists, 'none of them touches the state root';

  # Not the exit status of a die: that is the errno of the moment, which may
  # be 1 or 2.
  my $outcome = program('--config', $root->child('missing.json')->stringify, '--state');
  is $outcome->[0], 3, 'a configuration that cannot be read ends with the exit status 3';
  like $outcome->[2], qr/\Asimpici: .*missing\.json/, 'and a message that names it';
  my $refused = configure('refused', [ { name => 'owner/refused',
    clone_url => 'https://user:token@example.invalid/owner/refused.git' } ]);
  $outcome = program('--config', "$refused", '--repository', 'owner/refused', '--forget', 'refs/heads/main');
  is $outcome->[0], 3, 'so does one the daemon would not start with';
  like $outcome->[2], qr/\Asimpici: SimpiCI::App::Eventd repository owner\/refused \(repositories\[0\]\): clone URL must not contain credentials/,
    'for the reason the daemon gives';
  unlike $outcome->[2], qr/token/, 'without the value';
  my $broken = repository('broken', $fixture);
  state_file('broken', $broken)->touchpath->spew_utf8('{"tips":');
  $outcome = program('--config', configure('broken', [ $broken ])->stringify, '--state');
  is $outcome->[0], 3, 'and a state that cannot be read';
}

#### Two daemons on one state root

{
  my $fixture = git_fixture('shared');
  my $first = commit($fixture, 'first');
  my $repository = repository('shared', $fixture);
  my $config = configure('shared', [ $repository ]);
  my $state = state_file('shared', $repository);
  is once($config), $quiet, 'the baseline cycle is quiet';

  # The first daemon is held in the build of the branch. The tag appears
  # while it is: the second daemon sees both changes, the first only one.
  my $second = commit($fixture, 'second');
  my ( $held, $started, $release ) = held_runner('shared');
  my $one = spawn('simpicid', '--config', "$config", '--once', '--runner', "$held");
  wait_for($started);
  git($fixture, 'tag', 'v1');
  my $two = spawn('simpicid', '--config', "$config", '--once', '--runner', "$runner_script");
  my $early = ended($two, 2);
  ok !$early, 'a second daemon waits while the first polls the repository';
  $release->touch;
  is ended($one, 30), [ 0, '', '' ], 'the first daemon ends quietly';
  is $early // ended($two, 30), [ 0, '', '' ], 'and then the second';
  is runs_of('shared'), ['refs/heads/main '.$second, 'refs/tags/v1 '.$second],
    'the branch is built once, by the first, and the tag by the second';
  is $json->decode($state->slurp_utf8)->{tips},
    { 'refs/heads/main' => $second, 'refs/tags/v1' => $second },
    'the state has what either daemon recorded';
  is once($config), $quiet, 'the next cycle is quiet';
  is scalar(runs_of('shared')->@*), 2, 'and builds nothing a second time';
}

#### A ref is forgotten while its repository is polled

{
  my $fixture = git_fixture('busy');
  my $first = commit($fixture, 'first');
  git($fixture, 'tag', 'old');
  my $repository = repository('busy', $fixture);
  my $config = configure('busy', [ $repository ]);
  my $state = state_file('busy', $repository);
  once($config);

  my $second = commit($fixture, 'second');
  my ( $held, $started, $release ) = held_runner('busy');
  my $daemon = spawn('simpicid', '--config', "$config", '--once', '--runner', "$held");
  wait_for($started);
  my $forget = spawn('simpici', '--config', "$config", '--repository', 'owner/busy',
    '--forget', 'refs/tags/old');
  my $early = ended($forget, 2);
  ok !$early, 'forgetting waits for the poll of the repository';
  $release->touch;
  is ended($daemon, 30), [ 0, '', '' ], 'the daemon ends quietly';
  is +( $early // ended($forget, 30) )->[0], 0, 'and then the ref is forgotten';
  is $json->decode($state->slurp_utf8)->{tips}, { 'refs/heads/main' => $second },
    'the poll that was running has not written it back';
}

done_testing;
