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

# The dispatcher redacts what the worker has redacted already. A marker of the
# first pass is no text of the job: no value is found in it or across its
# ends, or the second pass would show what the first one hid.
my @twice = (
  [ 'a value that is a part of the marker', { publish => { A_TOKEN => 'RED' } },
    'token=RED and REDUCED', 'token=[REDACTED] and [REDACTED]UCED' ],
  [ 'the end of the marker as a value', { publish => { A_TOKEN => 'ACTED]' } },
    'x ACTED] y', 'x [REDACTED] y' ],
  [ 'a single character of the marker', { publish => { A_TOKEN => 'E', B_TOKEN => 'long-value' } },
    'E=long-value', '[REDACTED]=[REDACTED]' ],
  [ 'a bracket as a value', { publish => { A_TOKEN => ']', B_TOKEN => 'long-value' } },
    'a] long-value', 'a[REDACTED] [REDACTED]' ],
  [ 'a value that begins with the end of the marker',
    { publish => { A_TOKEN => 'first-value', B_TOKEN => ']bc' } },
    'afirst-valuebc and ]bc', 'a[REDACTED]bc and [REDACTED]' ],
  [ 'a value that ends with the beginning of the marker',
    { publish => { A_TOKEN => 'first-value', B_TOKEN => 'za[RED' } },
    'zafirst-valueb and za[RED', 'za[REDACTED]b and [REDACTED]' ],
  [ 'a value that reaches from one marker into the next',
    { publish => { A_TOKEN => 'first-value', B_TOKEN => 'D] [R' } },
    'first-value first-value D] [R', '[REDACTED] [REDACTED] [REDACTED]' ],
  [ 'a marker the job printed itself', { publish => { A_TOKEN => 'RED', B_TOKEN => 'D]x' } },
    'tool says [REDACTED]x RED', 'tool says [REDACTED]x [REDACTED]' ],
  [ 'a value right behind a marker the job printed', { publish => { A_TOKEN => 'value' } },
    '[REDACTED]value[REDACTED]', '[REDACTED][REDACTED][REDACTED]' ]
);

subtest 'a log that is redacted twice' => sub {
  for my $case (@twice) {
    my ( $name, $secrets, $text, $redacted ) = @$case;
    my $once = SimpiCI::Worker->redact($text, $secrets);
    is $once, $redacted, $name.': the worker redacts it';
    is(SimpiCI::Dispatcher->redact($once, $secrets), $redacted,
      $name.': the dispatcher leaves it as the worker sent it');
  }
};

subtest 'redacting twice is redacting once' => sub {
  # Short values and texts over the characters of the marker and two others:
  # nearly every value is a part of the marker, begins with its end or ends
  # with its beginning, and most texts hold a marker of their own.
  my @alphabet = ( split(//, '[REDACT]'), 'x', ' ' );
  my $marker = SimpiCI::Dispatcher->redaction_marker;
  my $state = 20261004;
  my $random = sub {
    $state = ( $state * 1103515245 + 12345 ) % 2147483648;
    return int($state / 65536) % $_[0];
  };
  my $word = sub { join '', map { $alphabet[ $random->(scalar @alphabet) ] } 1 .. $_[0] };
  my ( $changed, $left, @failed ) = ( 0, 0 );
  for my $round (1 .. 3000) {
    my %values = map { ( 'V'.$_.'_TOKEN' => $word->(1 + $random->(5)) ) } 1 .. 1 + $random->(3);
    next if grep { !SimpiCI::Dispatcher->secret_value_valid($_) } values %values;
    my $text = join '', map {
      my $pick = $random->(4);
      $pick == 0 ? $marker : $pick == 1 ? ( values %values )[ $random->(scalar keys %values) ]
        : $word->(1 + $random->(6));
    } 1 .. 1 + $random->(6);
    my $secrets = { publish => \%values };
    my $once = SimpiCI::Dispatcher->redact($text, $secrets);
    my $twice = SimpiCI::Dispatcher->redact($once, $secrets);
    $changed++ if $once ne $text;
    # What is left of a value stands in a marker or across the end of one:
    # with the markers taken out as barriers, none is found.
    my $leftover = grep { my $piece = $_; grep { index($piece, $_) >= 0 } values %values }
      split /\Q$marker\E/, $once, -1;
    $left++ if $leftover;
    push @failed, { text => $text, values => [ sort values %values ], once => $once, twice => $twice }
      if $twice ne $once || $leftover;
  }
  ok $changed > 1000, 'the texts held values to redact' or diag $changed;
  is $left, 0, 'no value is left outside a marker after the first pass';
  is scalar(@failed), 0, 'and the second pass changes nothing'
    or diag map { $json->encode($_)."\n" } grep { defined } @failed[ 0 .. 2 ];
};

subtest 'a value that holds the marker' => sub {
  for my $class (qw( SimpiCI::Worker SimpiCI::Dispatcher )) {
    ok !$class->secret_value_valid($_), $class.' takes "'.$_.'" for no secret value'
      for '[REDACTED]', 'pass[REDACTED]word', '[REDACTED][REDACTED]';
    ok $class->secret_value_valid($_), $class.' takes "'.$_.'" for one'
      for 'RED', ']', '[', 'REDACTED', '[REDACTED', 'pass]word[', 'D]x';
    # No grant carries one, but a snapshot of another version may: it is
    # found wherever it stands rather than published.
    is $class->redact('a pass[REDACTED]word b', { publish => { A_TOKEN => 'pass[REDACTED]word' } }),
      'a [REDACTED] b', $class.' still redacts such a value';
  }
};

subtest 'a log that is cut in a marker' => sub {
  # The worker sends the last 4 MiB of the redacted log. A cut that falls
  # into a marker would leave a piece of it that is no marker any more, and
  # the second pass would find a value in it.
  my $limit = 4 * 1024 * 1024;
  my $secrets = { publish => { A_TOKEN => 'E' } };
  my $root = tempdir;
  my $store = SimpiCI::Store->new(root => $root);
  my $worker = PrintingWorker->new(host => 'unused', store => $store,
    runner => SimpiCI::Runner->new(store => $store, runner_script => $root->child('unused')),
    output => ( 'y' x 100 ).'E'.( 'x' x ( $limit - 5 ) ),
    dispatcher => FixedClaim->new(claim => {
      run => 7, token => 'unused', timeout => 10, event => {}, secrets => $secrets
    }));
  $worker->once;
  my $sent = $worker->requests->[-1]{log};
  ok length($sent) <= $limit, 'the log is no longer than its limit';
  is substr($sent, 0, 12), 'x' x 12, 'and begins behind the marker the cut fell into';
  is length($sent), $limit - 5, 'with nothing else left out';
  ok(SimpiCI::Dispatcher->redact($sent, $secrets) eq $sent, 'the dispatcher leaves it as it is');

  my $marker = SimpiCI::Worker->redaction_marker;
  for my $case (
    [ 'a text within the limit', 'ab'.$marker, 12, 'ab'.$marker ],
    [ 'a cut in front of a marker', 'ab'.$marker.'cd', 12, $marker.'cd' ],
    [ 'a cut behind a marker', 'ab'.$marker.'cd', 2, 'cd' ],
    [ 'a cut behind the first character of a marker', 'ab'.$marker.'cd', 11, 'cd' ],
    [ 'a cut in front of the last character of a marker', 'ab'.$marker.'cd', 3, 'cd' ],
    [ 'a cut in the second of two markers', $marker.$marker.'cd', 7, 'cd' ],
    [ 'a cut in a text without a marker', 'abcdefghijklmnop', 4, 'mnop' ],
    [ 'a cut in what only begins like a marker', 'ab[REDACTEDxcd', 8, 'ACTEDxcd' ]
  ) {
    my ( $name, $text, $length, $tail ) = @$case;
    is(SimpiCI::Worker->redacted_tail($text, $length), $tail, $name);
  }
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
