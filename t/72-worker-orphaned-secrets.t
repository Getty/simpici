use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use Time::HiRes qw( sleep );
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# A worker that is killed during a run cannot remove secrets/<run>/. The next
# worker on the same state removes what it finds there before anything else.

{
  package ScriptedWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has answer => (is => 'ro', required => 1);
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->answer->($request);
  }
}

umask 0077;
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'orphaned-secret-value';

sub worker_in {
  my ( $root, $answer ) = @_;
  my $store = SimpiCI::Store->new(root => $root);
  return ScriptedWorker->new(host => 'unused', store => $store, answer => $answer,
    runner => SimpiCI::Runner->new(store => $store, runner_script => $root->child('unused')));
}

sub orphan {
  my ( $root, $run ) = @_;
  my $directory = $root->child('secrets', $run);
  $directory->mkpath;
  $directory->child($_.'.env')->spew_utf8('PUBLISH_TOKEN='.$value."\n") for qw( publish deploy );
  return $directory;
}

sub attempt {
  my ( $worker ) = @_;
  my ( $response, $error );
  my $warnings = warnings { $response = eval { $worker->once }; $error = $@ };
  return ( $response, $error, join('', @$warnings) );
}

subtest 'a worker that finds no work' => sub {
  my $root = tempdir;
  my @orphans = map { orphan($root, $_) } 4, 11;
  my $worker = worker_in($root, sub { {} });
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'runs';
  ok !$_->exists, 'and removes '.$_->relative($root) for @orphans;
  is [ $root->child('secrets')->children ], [], 'nothing is left below secrets/';
  like $warned, qr/^SimpiCI::Worker removed orphaned secret files: secrets\/$_$/m,
    'the worker names secrets/'.$_.' on standard error' for 4, 11;
  unlike $warned, qr/\Q$value\E/, 'without a value';
  is [ map { $_->{operation} } $worker->requests->@* ], ['claim'], 'and then asks for work';
  ( $response, $error, $warned ) = attempt($worker);
  is $warned, '', 'a worker that finds nothing to remove says nothing';
};

subtest 'a worker that cannot reach the dispatcher' => sub {
  my $root = tempdir;
  my $orphan = orphan($root, 4);
  my ( $response, $error, $warned ) = attempt(worker_in($root, sub { croak 'no route to dispatcher' }));
  like $error, qr/no route to dispatcher/, 'fails';
  ok !$orphan->exists, 'after it removed the orphaned secret files';
};

subtest 'a worker that has a completion to retry' => sub {
  my $root = tempdir;
  my $orphan = orphan($root, 4);
  my $completion = { operation => 'finish', run => 4, token => 'unused',
    result => { state => 'success', exit_code => 0 }, log => 'done' };
  $root->child('completion.json')->spew_utf8($json->encode($completion));
  my $worker = worker_in($root, sub { { state => 'success' } });
  my ( $response, $error, $warned ) = attempt($worker);
  is $response, { state => 'success' }, 'delivers it';
  is $worker->requests, [$completion], 'unchanged';
  ok !$orphan->exists, 'and removes the secret files of that run';
  ok !$root->child('completion.json')->exists, 'the completion is not kept';
};

subtest 'what else lies below secrets/' => sub {
  my $root = tempdir;
  my $secrets = $root->child('secrets');
  $secrets->mkpath;
  $secrets->child('stray.env')->spew_utf8('PUBLISH_TOKEN='.$value."\n");
  my $kept = tempdir;
  $kept->child('unrelated')->spew_utf8('not a secret file of the worker');
  symlink "$kept", $secrets->child('7')->stringify or croak 'cannot link';
  my $locked = orphan($root, 8);
  $locked->chmod(0500);
  my ( $response, $error, $warned ) = attempt(worker_in($root, sub { {} }));
  $locked->chmod(0700) if $locked->exists;
  is $error, '', 'does not stop the worker';
  is [ $secrets->children ], [], 'a file, a link and a write-protected directory are removed';
  ok $kept->child('unrelated')->is_file, 'the link is not followed';
};

subtest 'secret files that cannot be removed' => sub {
  skip_all 'the superuser can remove them' unless $>;
  my $root = tempdir;
  my $orphan = orphan($root, 4);
  $root->child('secrets')->chmod(0500);
  my $worker = worker_in($root, sub { {} });
  my ( $response, $error, $warned ) = attempt($worker);
  $root->child('secrets')->chmod(0700);
  like $error, qr/SimpiCI::Worker cannot remove secret files: \Q$orphan\E/, 'stop the worker';
  is $worker->requests, [], 'before it asks the dispatcher for anything';
  unlike $error.$warned, qr/\Q$value\E|removed orphaned/, 'and nothing claims they were removed';
  ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'the next attempt goes through once they can be';
  ok !$orphan->exists, 'and removes them';
};

subtest 'removing by hand' => sub {
  my $root = tempdir;
  my $orphan = orphan($root, 4);
  my $worker = worker_in($root, sub { croak 'not asked' });
  my $removed;
  my $warnings = warnings { $removed = $worker->remove_orphaned_secrets };
  is $removed, 1, 'remove_orphaned_secrets returns how many entries it removed';
  ok !$orphan->exists, 'and removes them';
  is $worker->remove_orphaned_secrets, 0, 'none when there is nothing';
  is $worker->requests, [], 'without a request to the dispatcher';
};

subtest 'a worker process that is killed during a run' => sub {
  my $fixture = tempdir;
  for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
      ['config', 'user.email', 'test@example.invalid']) {
    system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
  }
  $fixture->child('tracked')->spew_utf8('exact revision');
  for my $command (['add', '.'], ['commit', '-qm', 'fixture']) {
    system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
  }
  my $commit = `git -C $fixture rev-parse HEAD`;
  chomp $commit;

  my $root = tempdir;
  my $store = SimpiCI::Store->new(root => $root->child('dispatcher'));
  my $queue = SimpiCI::Queue->new(store => $store);
  $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
    clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit));
  my $token = $root->child('token');
  $token->spew_utf8($value."\n");
  my $config = $root->child('config.json');
  $config->spew_utf8($json->encode({
    root => $store->root->stringify, timeout => 60, repositories => [{
      name => 'fixture', clone_url => "$fixture", secrets => [{
        name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
      }]
    }]
  }));
  $root->child('bin')->mkpath;
  my $ssh = $root->child('bin/ssh');
  $ssh->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
exec "$TEST_PERL" -I"$TEST_LIB" "$TEST_DISPATCH" --config "$TEST_CONFIG" --worker test-vm
SCRIPT
  $ssh->chmod(0755);
  # Reports that the job runs with its secret file, then stays until killed.
  my $executor = $root->child('executor');
  $executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$SIMPICI_SECRETS_DIR/publish.env" ]]
printf '%s\n' "$$" > "$TEST_RUNNING"
exec sleep 60
SCRIPT
  $executor->chmod(0755);
  my $running = $root->child('running');
  local $ENV{PATH} = $root->child('bin').':'.$ENV{PATH};
  local $ENV{TEST_PERL} = $^X;
  local $ENV{TEST_LIB} = path('lib')->absolute->stringify;
  local $ENV{TEST_DISPATCH} = path('bin/simpici-dispatch')->absolute->stringify;
  local $ENV{TEST_CONFIG} = "$config";
  local $ENV{TEST_RUNNING} = "$running";
  my $worker_root = $root->child('worker');
  my @program = ( $^X, '-I'.$ENV{TEST_LIB}, path('bin/simpici-worker')->absolute->stringify,
    '--dispatcher', 'test-host', '--root', "$worker_root", '--executor', "$executor", '--once' );
  my $output = $root->child('output');

  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDOUT, '>', $output->stringify or exit 97;
    open STDERR, '>&', \*STDOUT or exit 97;
    exec { $program[0] } @program or exit 98;
  }
  my $deadline = time + 30;
  sleep 0.05 until -s $running || time > $deadline || waitpid($pid, 1) != 0;
  ok -s $running, 'the job runs' or diag $output->slurp_utf8;
  my $secret_file = $worker_root->child('secrets/1/publish.env');
  is $secret_file->slurp_utf8, 'PUBLISH_TOKEN='.$value."\n", 'with its secret file';
  kill 'KILL', $pid;
  waitpid($pid, 0);
  my $job = $running->slurp_utf8;
  chomp $job;
  kill 'KILL', $job if $job =~ /\A[1-9][0-9]*\z/;
  ok $secret_file->is_file, 'the killed worker leaves the secret file behind';

  my $restarted = qx{"$program[0]" "$program[1]" "$program[2]" --dispatcher test-host --root "$worker_root" --executor "$executor" --once 2>&1};
  is $? >> 8, 0, 'the worker starts again';
  ok !$worker_root->child('secrets/1')->exists, 'and removes the secret files of the killed run';
  is [ $worker_root->child('secrets')->children ], [], 'nothing is left below secrets/';
  like $restarted, qr/^SimpiCI::Worker removed orphaned secret files: secrets\/1$/m,
    'it says so on standard error';
  unlike $restarted, qr/\Q$value\E/, 'without the value';
  is $json->decode($store->root->child('queue/1.json')->slurp_utf8)->{state}, 'running',
    'the run of the killed worker keeps its lease until it expires';
};

done_testing;
