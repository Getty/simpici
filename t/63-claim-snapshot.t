use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;

# claims/N.json holds the secret values of a claim in the clear. It lives as
# long as a completion of that claim can still be accepted, and no log is
# published that it did not redact.

{
  # Publishes the log and then dies before the result is recorded, once.
  package CrashingQueue;
  use Moo;
  extends 'SimpiCI::Queue';
  has crash => (is => 'rw', default => sub { 0 });
  around _save => sub {
    my ( $orig, $self, $record ) = @_;
    if ($self->crash && $record->{result}) {
      $self->crash(0);
      Carp::croak('killed before the result was recorded');
    }
    return $self->$orig($record);
  };
}

umask 0077;
my $json = JSON::MaybeXS->new;
my $value = 'snapshot-secret-value';
my $success = { state => 'success', exit_code => 0 };
my $withheld = qr/\ASimpiCI::Dispatcher log of run \d+ withheld: no secret snapshot to redact it with\n\z/;

my $commit = 0;
sub setup {
  my ( %option ) = @_;
  my $root = tempdir;
  my $store = SimpiCI::Store->new(root => $root);
  my $queue = ( $option{queue_class} // 'SimpiCI::Queue' )->new(store => $store);
  my $token = $root->child('token');
  $token->spew_utf8($value."\n");
  my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
    repositories => [{ name => 'owner/repo', clone_url => '/fixture', secrets => [{
      name => 'PUBLISH_TOKEN', file => "$token", refs => ['refs/heads/main'], events => ['push']
    }] }]
  });
  return ( $root, $queue, $dispatcher, $token );
}

sub enqueue {
  my ( $queue ) = @_;
  return $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
    repository => 'owner/repo', clone_url => '/fixture', ref => 'refs/heads/main',
    commit => sprintf('%040x', ++$commit)))->{run};
}

sub finish {
  my ( $claim, %override ) = @_;
  return { operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => $success, log => 'token='.$value."\n", %override };
}

sub record { $json->decode($_[0]->child('queue/'.$_[1].'.json')->slurp_utf8) }

sub expire {
  my ( $root, $run ) = @_;
  my $record = record($root, $run);
  $record->{expires} = time - 1;
  SimpiCI::Store->new(root => $root)->write_json('queue/'.$run.'.json', $record);
}

sub everything_below {
  my ( $root ) = @_;
  my $content = '';
  $root->visit(sub { $content .= $_->slurp_raw if $_->is_file && $_->basename ne 'token' },
    { recurse => 1 });
  return $content;
}

subtest 'an accepted completion' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  my $snapshot = $root->child('claims/1.json');
  like $snapshot->slurp_utf8, qr/\Q$value\E/, 'the claim keeps a snapshot of its secret values';
  is sprintf('%04o', $snapshot->stat->mode & 07777), '0600', 'readable by its owner only';
  is $dispatcher->request('vm', finish($claim))->{state}, 'success', 'the completion is accepted';
  ok !$snapshot->exists, 'and the snapshot is removed';
  is $root->child('public/runs/1.log')->slurp_utf8, "token=[REDACTED]\n", 'the log is redacted';
  unlike everything_below($root), qr/\Q$value\E/,
    'no file of the dispatcher state holds the value any more';

  is $dispatcher->request('vm', finish($claim))->{state}, 'success',
    'the completion can be repeated after a lost acknowledgement';
  is $dispatcher->request('vm', finish($claim, log => 'again '.$value))->{state}, 'success',
    'also with another log';
  is $root->child('public/runs/1.log')->slurp_utf8, "token=[REDACTED]\n",
    'the published log stays the redacted one';
  unlike everything_below($root), qr/\Q$value\E/, 'and the value is not written anywhere';
};

subtest 'a dispatcher that dies between the log and the result' => sub {
  my ( $root, $queue, $dispatcher ) = setup(queue_class => 'CrashingQueue');
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  $queue->crash(1);
  like dies { $dispatcher->request('vm', finish($claim)) }, qr/killed before the result was recorded/,
    'the completion is lost';
  is record($root, 1)->{state}, 'running', 'the run still holds its lease';
  ok $root->child('claims/1.json')->is_file, 'so the snapshot is kept';
  unlike $root->child('public/runs/1.log')->slurp_utf8, qr/\Q$value\E/,
    'the log that was already published is redacted';
  is $dispatcher->request('vm', finish($claim))->{state}, 'success', 'the worker repeats it';
  is $root->child('public/runs/1.log')->slurp_utf8, "token=[REDACTED]\n", 'redacted again';
  ok !$root->child('claims/1.json')->exists, 'and the snapshot is removed then';
};

subtest 'a lease that expires' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 1);
  ok $root->child('claims/1.json')->is_file, 'the snapshot is there until the dispatcher is asked';
  is $dispatcher->request('other', { operation => 'claim' }), {}, 'the next claim finds no work';
  is record($root, 1)->{state}, 'interrupted', 'marks the run interrupted';
  ok !$root->child('claims/1.json')->exists, 'and removes its snapshot';
  like dies { $dispatcher->request('vm', finish($claim)) }, qr/expired claim/,
    'the late completion is refused';
  ok !$root->child('public/runs/1.log')->exists, 'and publishes no log';
  unlike everything_below($root), qr/\Q$value\E/, 'nothing holds the value any more';
};

subtest 'a late completion is the first request after the lease expired' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 1);
  like dies { $dispatcher->request('vm', finish($claim)) }, qr/expired claim/, 'it is refused';
  ok !$root->child('claims/1.json')->exists, 'and the snapshot is removed all the same';
  unlike everything_below($root), qr/\Q$value\E/, 'nothing holds the value any more';
};

subtest 'a configuration that serves no claim' => sub {
  my ( $root, $queue, $dispatcher, $token ) = setup();
  enqueue($queue);
  $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 1);
  $token->remove;
  like dies { $dispatcher->request('other', { operation => 'claim' }) }, qr/cannot read secret file/,
    'the claim fails on the unusable grant';
  ok !$root->child('claims/1.json')->exists, 'the snapshot of the expired lease is removed before that';
};

subtest 'the snapshots of other runs' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue) for 1 .. 3;
  my @claim = map { $dispatcher->request('vm'.$_, { operation => 'claim' }) } 1 .. 3;
  is [ map { $_->{run} } @claim ], [ 1, 2, 3 ], 'three workers hold three claims';
  ok $root->child('claims/'.$_.'.json')->is_file, 'run '.$_.' has its snapshot' for 1 .. 3;
  $dispatcher->request('vm2', finish($claim[1]));
  ok $root->child('claims/1.json')->is_file, 'a completion leaves the snapshot of a leased run';
  ok !$root->child('claims/2.json')->exists, 'and removes its own';
  like dies { $dispatcher->request('vm1', finish($claim[0], token => 'f' x 64)) }, qr/stale claim/,
    'a completion with the wrong token is refused';
  ok $root->child('claims/1.json')->is_file, 'and leaves the snapshot: the lease still stands';
  is $dispatcher->request('vm1', finish($claim[0]))->{state}, 'success', 'the owner completes it';
  is $root->child('public/runs/1.log')->slurp_utf8, "token=[REDACTED]\n", 'with a redacted log';
  ok $root->child('claims/3.json')->is_file, 'run 3 keeps its snapshot throughout';
};

subtest 'what an earlier dispatcher or a crash left in claims/' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue) for 1 .. 2;
  my $done = $dispatcher->request('vm', { operation => 'claim' });
  $dispatcher->request('vm', finish($done));
  my $leased = $dispatcher->request('vm', { operation => 'claim' });
  my $claims = $root->child('claims');
  my %left = (
    '1.json'            => 'the snapshot of a completed run',
    '.1.json.tmp.4711'  => 'a snapshot of a completed run that was not written to its end',
    '9.json'            => 'the snapshot of a run the queue does not know'
  );
  $claims->child($_)->spew_utf8($json->encode({ publish => { PUBLISH_TOKEN => $value } }))
    for keys %left;
  $claims->child('.2.json.tmp.4711')->spew_utf8('{}');
  $claims->child('notes.txt')->spew_utf8('kept by an operator');
  is $dispatcher->request('vm', { operation => 'claim' }), {}, 'the next request finds no work';
  ok !$claims->child($_)->exists, 'and removes '.$left{$_} for sort keys %left;
  ok $claims->child('2.json')->is_file, 'the snapshot of the leased run stays';
  ok $claims->child('.2.json.tmp.4711')->is_file, 'and so does a file being written for it';
  ok $claims->child('notes.txt')->is_file, 'a file that is no snapshot is left alone';
  is $dispatcher->request('vm', finish($leased))->{state}, 'success', 'the leased run completes';
  is [ sort map { $_->basename } $claims->children ], [ '.2.json.tmp.4711', 'notes.txt' ],
    'and takes its snapshot with it';
};

subtest 'a snapshot that cannot be removed' => sub {
  skip_all 'the superuser can remove it' unless $>;
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue) for 1 .. 2;
  $dispatcher->request('vm', { operation => 'claim' });
  expire($root, 1);
  $root->child('claims')->chmod(0500);
  my $error = dies { $dispatcher->request('other', { operation => 'claim' }) };
  $root->child('claims')->chmod(0700);
  like $error, qr/SimpiCI::Dispatcher cannot remove secret snapshot \S+claims\/1\.json: /,
    'fails the request and names the file';
  unlike $error, qr/\Q$value\E/, 'not the value';
  is record($root, 2)->{state}, 'queued', 'no lease is taken beside it';
  is $dispatcher->request('other', { operation => 'claim' })->{run}, 2,
    'the claim is served once it can be removed';
  ok !$root->child('claims/1.json')->exists, 'and it is';
};

subtest 'a leased run without its snapshot' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue);
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  $root->child('claims/1.json')->remove;
  is $dispatcher->request('vm', finish($claim))->{state}, 'success', 'is completed';
  like $root->child('public/runs/1.log')->slurp_utf8, $withheld,
    'but the log is withheld: nothing could redact it';
  unlike everything_below($root), qr/\Q$value\E/, 'so the value is not published';
};

subtest 'a claim without secrets' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
    repository => 'owner/repo', clone_url => '/fixture', ref => 'refs/heads/fork',
    commit => 'c' x 40));
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  is $claim->{secrets}, {}, 'receives none';
  ok $root->child('claims/1.json')->is_file, 'and has a snapshot all the same';
  $dispatcher->request('vm', finish($claim, log => "plain output\n"));
  is $root->child('public/runs/1.log')->slurp_utf8, "plain output\n", 'its log is published as it is';
  ok !$root->child('claims/1.json')->exists, 'and its snapshot removed';
};

subtest 'whether a completion can still be accepted' => sub {
  my ( $root, $queue, $dispatcher ) = setup();
  enqueue($queue) for 1 .. 2;
  ok !$queue->leased(1), 'not for a queued run';
  my $claim = $dispatcher->request('vm', { operation => 'claim' });
  ok $queue->leased(1), 'for a claimed run';
  ok !$queue->leased(2), 'not for the run queued behind it';
  ok !$queue->leased(9), 'not for a run the queue does not know';
  like dies { $queue->leased('../1') }, qr/invalid run/, 'a run that is no number is refused';
  expire($root, 1);
  ok !$queue->leased(1), 'not once the lease expired';
  my $second = $dispatcher->request('vm', { operation => 'claim' });
  $dispatcher->request('vm', finish($second));
  ok !$queue->leased(2), 'not for a completed run';
};

done_testing;
