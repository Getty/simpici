use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# What a job prints is in the log of its run, in the files the executor
# keeps and in what the job writes: a secret value among it. The worker keeps
# the redacted log in the completion and nothing else of a run, whether it
# lived to its end or finds what a killed worker left.

{
  package ScriptedWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has answer => (is => 'rw', required => 1);
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->answer->($request);
  }
}

umask 0077;
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'run-files-secret-value';

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

# Outside every worker root: the executor stands for the real one and prints
# the secret, keeps a raw job log and an artifact with it below RUNNER_TEMP,
# as the real one does, and says where that was.
my $tools = tempdir;
my $executor = $tools->child('executor');
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
cat "$SIMPICI_SECRETS_DIR/publish.env"
temporary="$(mktemp -d "$RUNNER_TEMP/simpici.XXXXXXXX")"
mkdir -p "$temporary/artifacts/publish/job"
cp "$SIMPICI_SECRETS_DIR/publish.env" "$temporary/log.publish.job"
cp "$SIMPICI_SECRETS_DIR/publish.env" "$temporary/artifacts/publish/job/kept-by-the-job"
chmod 0500 "$temporary/artifacts/publish/job"
printf '%s\n' "$RUNNER_TEMP" > "$TEST_SEEN_TEMP"
[[ -f "$CICD_WORKSPACE/tracked" ]]
exit "${TEST_EXIT:-0}"
SCRIPT
$executor->chmod(0755);
# A run whose executor fails asks docker for its containers. There are none.
$tools->child('bin')->mkpath;
$tools->child('bin/docker')->spew_utf8("#!/bin/sh\nexit 0\n");
$tools->child('bin/docker')->chmod(0755);
local $ENV{PATH} = $tools->child('bin').':'.$ENV{PATH};
my $seen_temp = $tools->child('seen-temp');
local $ENV{TEST_SEEN_TEMP} = "$seen_temp";

sub claim {
  my ( $run, %change ) = @_;
  return {
    run => $run, token => 'token-of-run-'.$run, timeout => 30,
    secrets => { publish => { PUBLISH_TOKEN => $value }, deploy => {} },
    event => { source => 'git-poll', event => 'push', repository => 'fixture',
      clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit },
    %change
  };
}

sub worker_in {
  my ( $root, $answer ) = @_;
  my $store = SimpiCI::Store->new(root => $root);
  return ScriptedWorker->new(host => 'unused', store => $store, answer => $answer,
    runner => SimpiCI::Runner->new(store => $store, runner_script => $executor));
}

sub attempt {
  my ( $worker ) = @_;
  my ( $response, $error );
  my $warnings = warnings { $response = eval { $worker->once }; $error = $@ };
  return ( $response, $error, join('', @$warnings) );
}

# Every file below the root that holds the value, links not followed.
sub files_with_value {
  my ( $root ) = @_;
  my @found;
  $root->visit(sub {
    my ( $path ) = @_;
    return if -l $path->stringify || !-f $path->stringify;
    push @found, $path->relative($root)->stringify if $path->slurp_raw =~ /\Q$value\E/;
  }, { recurse => 1, follow_symlinks => 0 });
  return [ sort @found ];
}

sub entries { [ sort map { $_->basename } $_[0]->children ] }

subtest 'a run that is delivered' => sub {
  my $root = tempdir;
  my $worker = worker_in($root, sub {
    $_[0]->{operation} eq 'claim' ? claim(7) : { state => 'success' } });
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'runs';
  is $response, { state => 'success' }, 'and is delivered';
  is $seen_temp->slurp_utf8, $root->absolute->child('tmp', 7)."\n",
    'the executor is given a temporary directory of the run, tmp/7';
  my $finish = $worker->requests->[-1];
  like $finish->{log}, qr/^PUBLISH_TOKEN=\[REDACTED\]$/m, 'the delivered log is redacted';
  ok !$root->child('public/runs/7.log')->exists, 'the log of the run is not kept';
  ok !$root->child($_)->exists, $_.' is removed' for qw( work/7 tmp/7 runs/7 secrets/7 );
  is entries($root->child($_)), [], 'nothing is left below '.$_ for qw( work tmp runs );
  is $json->decode($root->child('public/runs/7.json')->slurp_utf8)->{state}, 'success',
    'the report of the run is kept';
  is files_with_value($root), [], 'no file below the root holds the value';
  is $warned, '', 'and nothing is said about it';
};

subtest 'a run that cannot be delivered' => sub {
  my $root = tempdir;
  my $worker = worker_in($root, sub {
    $_[0]->{operation} eq 'claim' ? claim(7) : croak 'no route to dispatcher' });
  my ( $response, $error ) = attempt($worker);
  like $error, qr/no route to dispatcher/, 'fails';
  like $json->decode($root->child('completion.json')->slurp_utf8)->{log},
    qr/^PUBLISH_TOKEN=\[REDACTED\]$/m, 'its completion waits, with the redacted log';
  ok !$root->child('public/runs/7.log')->exists, 'the log of the run does not wait with it';
  ok !$root->child($_)->exists, $_.' is removed' for qw( work/7 tmp/7 runs/7 secrets/7 );
  is files_with_value($root), [], 'no file below the root holds the value';
};

subtest 'a run that fails' => sub {
  my $root = tempdir;
  local $ENV{TEST_EXIT} = 3;
  my $worker = worker_in($root, sub {
    $_[0]->{operation} eq 'claim' ? claim(7) : { state => 'failed' } });
  my ( $response, $error ) = attempt($worker);
  is $worker->requests->[-1]->{result}, { state => 'failed', exit_code => 3 }, 'is reported';
  ok !$root->child($_)->exists, $_.' is removed'
    for qw( public/runs/7.log work/7 tmp/7 runs/7 secrets/7 );
  is files_with_value($root), [], 'no file below the root holds the value';
};

subtest 'a claim that is not executed' => sub {
  my $root = tempdir;
  my $worker = worker_in($root, sub {
    $_[0]->{operation} eq 'claim' ? claim(7, event => { source => 'git-poll', event => 'push',
      repository => 'fixture', clone_url => "$fixture", ref => 'not-a-ref', commit => $commit })
      : { state => 'failed' } });
  my ( $response, $error ) = attempt($worker);
  is $worker->requests->[-1]->{result}, { state => 'failed', exit_code => 125 }, 'is reported';
  ok !$root->child($_)->exists, $_.' is not left behind'
    for qw( public/runs/7.log work/7 tmp/7 runs/7 secrets/7 );
};

subtest 'a completion that cannot be saved' => sub {
  my $root = tempdir;
  my $worker = worker_in($root, sub { claim(7) });
  # The run is made and reported as usual; only its completion is not written.
  my $write = SimpiCI::Store->can('write_json');
  no warnings 'redefine';
  local *SimpiCI::Store::write_json = sub {
    croak 'SimpiCI::Store->write_json cannot publish' if $_[1] eq 'completion.json';
    goto &$write;
  };
  my ( $response, $error ) = attempt($worker);
  like $error, qr/SimpiCI::Worker cannot save the completion of run 7/, 'ends the cycle';
  ok !$root->child('completion.json')->exists, 'nothing waits to be delivered';
  ok !$root->child($_)->exists, $_.' is removed all the same'
    for qw( public/runs/7.log work/7 tmp/7 runs/7 secrets/7 );
  is files_with_value($root), [], 'no file below the root holds the value';
};

# What a worker leaves that is killed during run 4, and what a version left
# that removed nothing: the temporary files of all runs side by side.
sub leftovers {
  my ( $root ) = @_;
  my %file = (
    'public/runs/4.log'                         => 'PUBLISH_TOKEN='.$value."\n",
    'public/runs/3.log'                         => "an earlier run\n",
    'work/4/tracked'                            => 'exact revision',
    'work/4/.git/config'                        => '[core]',
    'tmp/4/simpici.aB3dE6gH/log.publish.job'    => 'PUBLISH_TOKEN='.$value."\n",
    'tmp/simpici.Zz9yX8wV/artifacts/publish/job/kept' => 'PUBLISH_TOKEN='.$value."\n",
    'runs/4/event.json'                         => '{}',
    'public/runs/3.json'                        => '{"run":3,"state":"success"}',
    'public/runs/index.json'                    => '{"latest":4,"runs":[4]}',
    'rejected/2.json'                           => '{"run":2}',
    'counter'                                   => "4\n",
    '.completion.json.tmp.4242'                 => '{"log":"PUBLISH_TOKEN=[REDACTED]"}',
    '.other.json.tmp.4242'                      => '{}'
  );
  for my $name (keys %file) {
    $root->child($name)->parent->mkpath;
    $root->child($name)->spew_utf8($file{$name});
  }
  $root->child('work/4/.git')->chmod(0500);
  return;
}

my @removed = qw( public/runs/3.log public/runs/4.log .completion.json.tmp.4242 runs/4 tmp/4
  tmp/simpici.Zz9yX8wV work/4 );
my @kept = qw( public/runs/3.json public/runs/index.json rejected/2.json counter .other.json.tmp.4242 );

subtest 'a worker that finds no work' => sub {
  my $root = tempdir;
  leftovers($root);
  my $worker = worker_in($root, sub { {} });
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'runs';
  ok !$root->child($_)->exists, 'and removes '.$_ for @removed;
  ok $root->child($_)->is_file, 'it keeps '.$_ for @kept;
  is files_with_value($root), [], 'no file below the root holds the value';
  is $warned, join('', map { 'SimpiCI::Worker removed orphaned run files: '.$_."\n" } @removed),
    'each entry is named on standard error, and no value';
  is [ map { $_->{operation} } $worker->requests->@* ], ['claim'], 'and then it asks for work';
  ( $response, $error, $warned ) = attempt($worker);
  is $warned, '', 'a worker that finds nothing to remove says nothing';
};

subtest 'a worker that cannot reach the dispatcher' => sub {
  my $root = tempdir;
  leftovers($root);
  my ( $response, $error ) = attempt(worker_in($root, sub { croak 'no route to dispatcher' }));
  like $error, qr/no route to dispatcher/, 'fails';
  ok !$root->child($_)->exists, 'after it removed '.$_ for @removed;
};

subtest 'a worker that has a completion to retry' => sub {
  my $root = tempdir;
  leftovers($root);
  my $completion = { operation => 'finish', run => 4, token => 'unused',
    result => { state => 'success', exit_code => 0 }, log => 'PUBLISH_TOKEN=[REDACTED]' };
  $root->child('completion.json')->spew_utf8($json->encode($completion));
  my $worker = worker_in($root, sub { { state => 'success' } });
  my ( $response, $error ) = attempt($worker);
  is $worker->requests, [$completion], 'delivers it unchanged';
  ok !$root->child($_)->exists, 'and removes '.$_ for @removed;
};

subtest 'what else lies there' => sub {
  my $root = tempdir;
  my $outside = tempdir;
  $outside->child('unrelated')->spew_utf8('not a file of the worker');
  $outside->child('unrelated.log')->spew_utf8('not a log of the worker');
  $root->child($_)->mkpath for qw( work tmp runs public/runs );
  symlink "$outside", $root->child('work/7')->stringify or croak 'cannot link';
  symlink "$outside", $root->child('tmp/7')->stringify or croak 'cannot link';
  symlink $outside->child('unrelated.log')->stringify,
    $root->child('public/runs/7.log')->stringify or croak 'cannot link';
  $root->child('tmp/stray-file')->spew_utf8('PUBLISH_TOKEN='.$value);
  $root->child('public/runs/8.log')->mkpath;
  $root->child('public/runs/8.log/inside')->spew_utf8('PUBLISH_TOKEN='.$value);
  my ( $response, $error, $warned ) = attempt(worker_in($root, sub { {} }));
  is $error, '', 'does not stop the worker';
  is entries($root->child($_)), [], 'nothing is left below '.$_ for qw( work tmp runs public/runs );
  is entries($outside), [qw( unrelated unrelated.log )], 'a link is removed, not followed';
};

subtest 'a log that cannot be removed' => sub {
  skip_all 'the superuser can remove it' unless $>;
  my $root = tempdir;
  leftovers($root);
  $root->child('public/runs')->chmod(0500);
  my $worker = worker_in($root, sub { {} });
  my ( $response, $error, $warned ) = attempt($worker);
  $root->child('public/runs')->chmod(0700);
  like $error, qr/SimpiCI::Worker cannot remove the log of a run: \Q$root\E\/public\/runs\/3\.log/,
    'stops the worker';
  is $worker->requests, [], 'before it asks the dispatcher for anything';
  unlike $error.$warned, qr/\Q$value\E|removed orphaned run files: public/,
    'and nothing claims it was removed';
  ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'the next attempt goes through once it can be';
  ok !$root->child('public/runs/4.log')->exists, 'and removes it';
};

subtest 'files of a run that cannot be removed' => sub {
  skip_all 'the superuser can remove them' unless $>;
  my $root = tempdir;
  leftovers($root);
  $root->child('tmp')->chmod(0500);
  my $worker = worker_in($root, sub { {} });
  my ( $response, $error, $warned ) = attempt($worker);
  is $error, '', 'do not stop the worker';
  is [ map { $_->{operation} } $worker->requests->@* ], ['claim'], 'it asks for work';
  like $warned, qr/^SimpiCI::Worker cannot remove run files: tmp\/4$/m, 'and names what is left';
  unlike $warned, qr/removed orphaned run files: tmp/, 'nothing claims it was removed';
  ok !$root->child('tmp/4/simpici.aB3dE6gH/log.publish.job')->exists,
    'what could be removed of it is removed';
  ok !$root->child($_)->exists, $_.' is removed all the same' for qw( public/runs/4.log work/4 runs/4 );
  ( $response, $error, $warned ) = attempt($worker);
  is $warned, '', 'the same worker does not say it again in every cycle';
  ( $response, $error, $warned ) = attempt(worker_in($root, sub { {} }));
  like $warned, qr/^SimpiCI::Worker cannot remove run files: tmp\/4$/m,
    'a worker that starts again does';
  $root->child('tmp')->chmod(0700);
  ( $response, $error, $warned ) = attempt($worker);
  like $warned, qr/^SimpiCI::Worker removed orphaned run files: tmp\/4$/m,
    'once it can be removed, it is, and the worker says so';
  is entries($root->child('tmp')), [], 'nothing is left below tmp';
};

subtest 'a root that is the state of a dispatcher or of a daemon' => sub {
  # There the logs are the published ones and the checkouts those of local
  # runs: a worker that is pointed at such a root by mistake removes nothing.
  for my $theirs (qw( queue claims state )) {
    my $root = tempdir;
    leftovers($root);
    $root->child($theirs)->mkpath;
    my $worker = worker_in($root, sub { {} });
    my ( $response, $error, $warned ) = attempt($worker);
    like $error, qr/\ASimpiCI::Worker root is the state of a dispatcher or a daemon, it has $theirs\/: \Q$root\E at /,
      'is refused for its '.$theirs.'/';
    ok $root->child($_)->exists, $theirs.': '.$_.' is still there' for @removed;
    is $worker->requests, [], $theirs.': and the dispatcher is not asked for work';
    is $warned, '', $theirs.': nothing is said to have been removed';
    like dies { $worker->remove_orphaned_run_files },
      qr/SimpiCI::Worker root is the state of a dispatcher or a daemon/,
      $theirs.': removing by hand is refused as well';
  }
};

subtest 'removing by hand' => sub {
  my $root = tempdir;
  leftovers($root);
  my $worker = worker_in($root, sub { croak 'not asked' });
  my $removed;
  my $warnings = warnings { $removed = $worker->remove_orphaned_run_files };
  is $removed, scalar @removed, 'remove_orphaned_run_files returns how many entries it removed';
  ok !$root->child($_)->exists, 'and removes '.$_ for @removed;
  is $worker->remove_orphaned_run_files, 0, 'none when there is nothing';
  is $worker->requests, [], 'without a request to the dispatcher';
};

done_testing;
