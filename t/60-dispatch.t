use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Path::Tiny qw( path tempdir );
use SimpiCI::Store;
use SimpiCI::Queue;
use SimpiCI::Dispatcher;
use SimpiCI::Event;

umask 0077;
my $root = tempdir;
my $store = SimpiCI::Store->new(root => $root);
my $queue = SimpiCI::Queue->new(store => $store);
my %args = (source => 'git-poll', event => 'push', repository => 'owner/repo',
  clone_url => '/fixture', ref => 'refs/heads/main', commit => 'a' x 40);
my $event = SimpiCI::Event->new(%args);
is $queue->run($event)->{run}, 1, 'accept first event';
is $queue->run(SimpiCI::Event->new(%args, source => 'webhook', clone_url => '/mirror'))->{run},
  1, 'mirror and webhook converge on durable run';
my @children;
for my $number (1..2) {
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    my $claim = $queue->claim('worker'.$number);
    $root->child('claim'.$number)->spew_utf8($claim ? $claim->{run} : 'none');
    exit 0;
  }
  push @children, $pid;
}
waitpid($_, 0) for @children;
is [sort map { $root->child('claim'.$_)->slurp_utf8 } 1..2], ['1', 'none'],
  'only one competing worker gets a claim';
my $record = $store->_json->decode($root->child('queue/1.json')->slurp_utf8);
like dies { $queue->finish('intruder', 1, $record->{token}, {state => 'success', exit_code => 0}, '') },
  qr/stale claim/, 'worker identity fences completion';
like dies { $queue->finish($record->{worker}, '../1', '', {}, '') }, qr/invalid run/,
  'reject completion traversal';
$record->{expires} = time - 1;
$store->write_json('queue/1.json', $record);
is $queue->claim('another'), undef, 'expired work is not replayed';
is $store->_json->decode($root->child('queue/1.json')->slurp_utf8)->{state},
  'interrupted', 'lost worker has observable interrupted status';
like dies { $queue->finish($record->{worker}, 1, $record->{token}, {state => 'success', exit_code => 0}, '') },
  qr/expired claim/, 'late worker cannot overwrite recovery';

my $secret_file = $root->child('registry-token');
$secret_file->spew_utf8("private-value\n");
my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
  repositories => [{name => 'owner/repo', clone_url => '/fixture', secrets => [{
    name => 'CICD_REGISTRY_PASSWORD', file => "$secret_file",
    refs => ['refs/heads/main'], events => ['push'], phases => ['publish']
  }]}]
});
$queue->run(SimpiCI::Event->new(%args, commit => 'b' x 40));
my $claim = $dispatcher->request('vm', {operation => 'claim'});
is $claim->{secrets}, {publish => {CICD_REGISTRY_PASSWORD => 'private-value'}},
  'only allowed phase receives referenced secret';
my $finish = {operation => 'finish', run => $claim->{run}, token => $claim->{token},
  result => {state => 'success', exit_code => 0, payload => 'private-value'},
  log => "token=private-value\n"};
is $dispatcher->request('vm', $finish)->{state}, 'success', 'finish accepted';
is $dispatcher->request('vm', $finish)->{state}, 'success', 'lost acknowledgement can be retried';
my $public = join '', map { $_->slurp_utf8 } $root->child('public/runs')->children;
unlike $public, qr/private-value|registry-token|clone_url|payload/, 'public report and log exclude secret data';
like $root->child('public/runs/2.log')->slurp_utf8, qr/REDACTED/, 'redact secret from worker output';
for my $change ({ref => 'refs/heads/fork'}, {event => 'pull_request', commit => 'c' x 40}) {
  $queue->run(SimpiCI::Event->new(%args, %$change));
  is $dispatcher->request('vm', {operation => 'claim'})->{secrets}, {},
    'untrusted ref/event receives no secrets';
}
like dies { $dispatcher->request('vm', {operation => 'exec', command => 'id'}) },
  qr/unsupported operation/, 'protocol cannot invoke arbitrary commands';

done_testing;
