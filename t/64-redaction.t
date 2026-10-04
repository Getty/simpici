use strict;
use warnings;
use Test2::V0;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# Worker and dispatcher redact with one function, and no order of the assigned
# values leaves a part of one of them in the log.

{
  package FixedClaim;
  use Moo;
  has claim => (is => 'ro');
  sub request { $_[0]->claim }
}

{
  # Publishes its output as the log of the run instead of running a job.
  package PrintingWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has dispatcher => (is => 'ro');
  has output => (is => 'ro');
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->dispatcher->request('vm', $request);
  }
  sub _run_claim {
    my ( $self, $claim ) = @_;
    $self->store->root->child('public', 'runs', $claim->{run}.'.log')->spew_utf8($self->output);
    return { state => 'success', exit_code => 0 };
  }
}

umask 0077;
my $json = JSON::MaybeXS->new;

# Six values that each begin another one: in hash order at least one short
# value is replaced before the long one it begins, in all but 1 of 64 runs.
my %nested = map { ( 'P'.$_.'_TOKEN' => 'prefix'.$_, 'L'.$_.'_TOKEN' => 'prefix'.$_.'-and-the-rest' ) }
  1 .. 6;
my $nested_text = join '', map { 'long='.$nested{'L'.$_.'_TOKEN'}.' short='.$nested{'P'.$_.'_TOKEN'}."\n" }
  1 .. 6;
my $nested_redacted = "long=[REDACTED] short=[REDACTED]\n" x 6;

my @cases = (
  [ 'a value that begins another one', { publish => \%nested }, $nested_text, $nested_redacted ],
  [ 'a value that ends where another one begins',
    { publish => { A_TOKEN => 'abcd', B_TOKEN => 'cdef' } }, 'x abcdef y', 'x [REDACTED] y' ],
  [ 'a value that overlaps itself', { publish => { A_TOKEN => 'aa' } }, 'x aaa y', 'x [REDACTED] y' ],
  [ 'two values side by side', { publish => { A_TOKEN => 'left', B_TOKEN => 'right' } },
    'x leftright y', 'x [REDACTED] y' ],
  [ 'the same value in two phases',
    { publish => { A_TOKEN => 'twice' }, deploy => { A_TOKEN => 'twice' } },
    'twice and twice', '[REDACTED] and [REDACTED]' ],
  [ 'an empty value next to a real one', { publish => { A_TOKEN => '', B_TOKEN => 'real' } },
    'a real b', 'a [REDACTED] b' ],
  [ 'only an empty value', { publish => { A_TOKEN => '' } }, 'a real b', 'a real b' ],
  [ 'a value that is no string', { publish => { A_TOKEN => undef, B_TOKEN => 'real' } },
    'a real b', 'a [REDACTED] b' ],
  [ 'a value of pattern characters', { publish => { A_TOKEN => '.*', B_TOKEN => 'a|b' } },
    'x .* y a|b z', 'x [REDACTED] y [REDACTED] z' ],
  [ 'a value and a text beyond ASCII', { publish => { A_TOKEN => "gehe\x{fc}m-\x{2713}" } },
    "pr\x{fc}fung gehe\x{fc}m-\x{2713} \x{2713} gehe\x{fc}m", "pr\x{fc}fung [REDACTED] \x{2713} gehe\x{fc}m" ],
  [ 'a text beyond ASCII around a plain value', { publish => { A_TOKEN => 'real' } },
    "\x{2713} real \x{fc}", "\x{2713} [REDACTED] \x{fc}" ],
  [ 'values nested deeper than a phase', { publish => { A_TOKEN => { inner => ['deep'] } } },
    'a deep b', 'a [REDACTED] b' ],
  [ 'no secrets at all', {}, 'a real b', 'a real b' ],
  [ 'secrets of no shape', undef, 'a real b', 'a real b' ]
);

subtest 'the function itself' => sub {
  for my $class (qw( SimpiCI::Worker SimpiCI::Dispatcher )) {
    ok $class->can('redact'), $class.' can redact' or next;
    for my $case (@cases) {
      my ( $name, $secrets, $text, $redacted ) = @$case;
      my $result;
      my $warnings = warnings { $result = $class->redact($text, $secrets) };
      is $result, $redacted, $class.': '.$name;
      is $warnings, [], 'without a warning';
    }
  }
  ok $_->DOES('SimpiCI::Role::Secrets'), $_.' takes it from the shared role'
    for qw( SimpiCI::Worker SimpiCI::Dispatcher );
};

subtest 'the log a worker sends' => sub {
  for my $case (grep { ref $_->[1] } @cases) {
    my ( $name, $secrets, $text, $redacted ) = @$case;
    my $root = tempdir;
    my $store = SimpiCI::Store->new(root => $root);
    my $worker = PrintingWorker->new(host => 'unused', store => $store,
      runner => SimpiCI::Runner->new(store => $store, runner_script => $root->child('unused')),
      output => $text, dispatcher => FixedClaim->new(claim => {
        run => 7, token => 'unused', timeout => 10, event => {}, secrets => $secrets
      }));
    $worker->once;
    is $worker->requests->[-1]{log}, $redacted, $name;
  }
};

subtest 'the log a dispatcher publishes' => sub {
  my $number = 0;
  for my $case (grep { ref $_->[1] } @cases) {
    my ( $name, $secrets, $text, $redacted ) = @$case;
    my $root = tempdir;
    my $store = SimpiCI::Store->new(root => $root);
    my $queue = SimpiCI::Queue->new(store => $store);
    $queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
      repository => 'owner/repo', clone_url => '/fixture', ref => 'refs/heads/main',
      commit => 'a' x 40));
    my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => { repositories => [] });
    my $claim = $dispatcher->request('vm', { operation => 'claim' });
    # The snapshot of the claim, as if these had been the granted values.
    $store->write_json('claims/'.$claim->{run}.'.json', $secrets);
    $dispatcher->request('vm', { operation => 'finish', run => $claim->{run},
      token => $claim->{token}, result => { state => 'success', exit_code => 0 }, log => $text });
    is $root->child('public/runs/'.$claim->{run}.'.log')->slurp_utf8, $redacted, $name;
  }
};

done_testing;
