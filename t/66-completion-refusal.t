use strict;
use warnings;
use Test2::V0;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;

# A completion that can never be accepted is answered, not failed: the worker
# has to tell it from a dispatcher it could not reach.

umask 0077;
my $json = JSON::MaybeXS->new;
my $secret = 'refusal-secret-value';
my $root = tempdir;
my $store = SimpiCI::Store->new(root => $root);
my $queue = SimpiCI::Queue->new(store => $store);
my $token = $root->child('token');
$token->spew_utf8($secret."\n");
my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
  repositories => [{ name => 'fixture', clone_url => '/fixture', secrets => [{
    name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
  }]}]
});

my $commits = 0;
sub claimed {
  $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
    clone_url => '/fixture', ref => 'refs/heads/main', commit => sprintf('%040x', ++$commits)));
  return $dispatcher->request('vm', { operation => 'claim' });
}

sub completion {
  my ( $claim, %change ) = @_;
  return { operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => { state => 'success', exit_code => 0 }, log => 'token='.$secret."\n", %change };
}

sub record { $json->decode($root->child('queue/'.$_[0].'.json')->slurp_utf8) }

sub expire {
  my ( $run ) = @_;
  my $record = record($run);
  $record->{expires} = time - 1;
  $store->write_json('queue/'.$run.'.json', $record);
}

subtest 'a completion whose lease expired' => sub {
  my $claim = claimed();
  expire($claim->{run});
  my $response = $dispatcher->request('vm', completion($claim));
  is $response, { rejected => 'expired claim' }, 'is answered with the reason and nothing else';
  is record($claim->{run})->{state}, 'running', 'the run is left as it was';
  ok !$root->child('public/runs/'.$claim->{run}.'.log')->exists, 'and no log is published';
  is $queue->claim('vm'), undef, 'the next claim marks it';
  is record($claim->{run})->{state}, 'interrupted', 'as interrupted';
  is $dispatcher->request('vm', completion($claim)), { rejected => 'expired claim' },
    'and the completion is answered the same way afterwards';
  is record($claim->{run})->{state}, 'interrupted', 'without an effect on the run';
};

subtest 'a completion with another token' => sub {
  my $claim = claimed();
  my $snapshot = $root->child('claims', $claim->{run}.'.json');
  is $dispatcher->request('vm', completion($claim, token => 'f' x 64)),
    { rejected => 'stale claim' }, 'is answered as a stale claim';
  is $dispatcher->request('other', completion($claim)), { rejected => 'stale claim' },
    'as is the right token from another worker';
  is record($claim->{run})->{state}, 'running', 'the lease of the claimant is untouched';
  ok $snapshot->is_file, 'and so is its secret snapshot';
  is $dispatcher->request('vm', completion($claim))->{state}, 'success',
    'the completion of the claimant is accepted';
  is $root->child('public/runs/'.$claim->{run}.'.log')->slurp_utf8, "token=[REDACTED]\n",
    'and redacted from that snapshot, not withheld';
};

subtest 'a completion of a run the queue does not have' => sub {
  is $dispatcher->request('vm', { operation => 'finish', run => 4711, token => 'f' x 64,
    result => { state => 'success', exit_code => 0 }, log => '' }),
    { rejected => 'unknown run' }, 'is answered as an unknown run';
  ok !$root->child('public/runs/4711.log')->exists, 'and nothing is published for it';
};

subtest 'a refused completion of any shape' => sub {
  my $claim = claimed();
  expire($claim->{run});
  is $dispatcher->request('vm', completion($claim, log => 'x' x (4 * 1024 * 1024 + 1))),
    { rejected => 'expired claim' }, 'a log that is too long does not hide the refusal';
  is $dispatcher->request('vm', completion($claim, result => 'none')),
    { rejected => 'expired claim' }, 'nor does a result that is none';
};

subtest 'a completion that is repeated' => sub {
  my $claim = claimed();
  is $dispatcher->request('vm', completion($claim))->{state}, 'success', 'is accepted once';
  my $again = $dispatcher->request('vm', completion($claim));
  is $again->{state}, 'success', 'and answered with the report again';
  ok !exists $again->{rejected}, 'not as a refusal';
};

subtest 'what is not a refusal' => sub {
  my $claim = claimed();
  like dies { $dispatcher->request('vm', completion($claim, run => '../1')) },
    qr/SimpiCI::Dispatcher invalid run/, 'a run that is no run number is an error';
  like dies { $dispatcher->request('vm', completion($claim, result => { state => 'fine' })) },
    qr/SimpiCI::Queue invalid result/, 'a result of a leased run that is none is an error';
  like dies { $dispatcher->request('vm', completion($claim, log => 'x' x (4 * 1024 * 1024 + 1))) },
    qr/SimpiCI::Dispatcher invalid log/, 'and so is its log when it is too long';
  is record($claim->{run})->{state}, 'running', 'the run keeps its lease through all of them';
  is $dispatcher->request('vm', completion($claim))->{state}, 'success',
    'and its completion is accepted';
};

subtest 'the queue names the reason' => sub {
  my $claim = claimed();
  my $run = $claim->{run};
  is $queue->refusal('vm', $run, $claim->{token}), undef, 'none for a leased run';
  is $queue->refusal('vm', $run, 'f' x 64), 'stale claim', 'stale claim for another token';
  is $queue->refusal('other', $run, $claim->{token}), 'stale claim', 'and for another worker';
  is $queue->refusal('vm', 4711, $claim->{token}), 'unknown run', 'unknown run';
  like dies { $queue->refusal('vm', '../1', $claim->{token}) }, qr/SimpiCI::Queue invalid run/,
    'a run that is no run number is refused before a path is built';
  expire($run);
  is $queue->refusal('vm', $run, $claim->{token}), 'expired claim',
    'expired claim once the lease is over';
  is $queue->refusal('vm', $run, 'f' x 64), 'stale claim',
    'another token is stale whatever became of the lease';
  like dies { $queue->finish('vm', $run, $claim->{token}, { state => 'success', exit_code => 0 }, '') },
    qr/SimpiCI::Queue expired claim/, 'finish croaks with the same reason';
  my $done = claimed();
  $dispatcher->request('vm', completion($done));
  is $queue->refusal('vm', $done->{run}, $done->{token}), undef,
    'none for a completed run and the claim that completed it';
  is [ $queue->refusal_reasons ], [ 'unknown run', 'stale claim', 'expired claim' ],
    'and lists every reason it gives';
};

done_testing;
