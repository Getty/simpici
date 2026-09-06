use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

{
  package TestWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has dispatcher => (is => 'ro');
  has lose_ack => (is => 'rw', default => sub { 1 });
  sub _request {
    my ( $self, $request ) = @_;
    my $response = $self->dispatcher->request('vm', $request);
    if ($request->{operation} eq 'finish' && $self->lose_ack) {
      $self->lose_ack(0);
      Carp::croak('lost acknowledgement');
    }
    return $response;
  }
}

umask 0077;
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
my $store = SimpiCI::Store->new(root => $root);
my $queue = SimpiCI::Queue->new(store => $store);
$store->allocate_run;
$queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
  repository => 'fixture', clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit));
my $token = $root->child('token');
$token->spew_utf8('test-secret-value');
my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
  timeout => 10, repositories => [{name => 'fixture', clone_url => "$fixture", secrets => [{
    name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
  }]}]
});
my $worker_root = tempdir;
my $executor = $worker_root->child('executor');
$executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
[[ "$(git rev-parse HEAD)" == "$CICD_COMMIT" ]]
[[ "$CICD_RUN_NUMBER" == 2 ]]
! git symbolic-ref -q HEAD
[[ -f "$SIMPICI_SECRETS_DIR/publish.env" ]]
cat "$SIMPICI_SECRETS_DIR/publish.env"
printf 'ran\n' >> "$CICD_WORKSPACE/../../executions"
SCRIPT
$executor->chmod(0755);
my $worker_store = SimpiCI::Store->new(root => $worker_root);
my $worker = TestWorker->new(host => 'unused', store => $worker_store,
  runner => SimpiCI::Runner->new(store => $worker_store, runner_script => $executor),
  dispatcher => $dispatcher);
like dies { $worker->once }, qr/lost acknowledgement/, 'simulate lost upload response';
ok $worker_root->child('completion.json')->is_file, 'completion survives connection loss';
is $worker->once->{state}, 'success', 'restart retries completion';
is $worker_root->child('executions')->slurp_utf8, "ran\n", 'completion retry does not rebuild';
unlike $root->child('public/runs/2.log')->slurp_utf8, qr/test-secret-value/,
  'remote result does not publish secret';
like $root->child('public/runs/2.log')->slurp_utf8, qr/REDACTED/, 'redacted job output arrives';
ok !$worker_root->child('secrets/2')->exists, 'remove per-run secret files after execution';
is $worker->once, undef, 'empty queue is idle';

done_testing;
