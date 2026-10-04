use strict;
use warnings;
use Test2::V0;
use Carp qw( confess croak );
use File::Which qw( which );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# The log of a run is published. Of a claim that was not executed to its end
# it gives one reason of a closed list and nothing of what the error itself
# said: no path below the store of the worker, no file of the installation,
# no line number, no value of the claim. What the error said goes to standard
# error of the worker, in one line.

{
  package ScriptedWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has claim => (is => 'ro', required => 1);
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $request->{operation} eq 'claim' ? $self->claim : { state => 'recorded' };
  }
}

{
  package AbortingWorker;
  use Moo;
  extends 'ScriptedWorker';
  has raise => (is => 'ro', required => 1);
  sub _run_claim { $_[0]->raise->() }
}

{
  package InventiveWorker;
  use Moo;
  extends 'ScriptedWorker';
  sub _run_claim { ( undef, 'cannot read /etc/simpici/worker.key', 'said on standard error' ) }
}

umask 0077;
my $json = JSON::MaybeXS->new(canonical => 1);
my $value = 'abort-reason-secret-value';

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

# docker knows no container: no test asks the one of the host.
my $tools = tempdir;
$tools->child('bin')->mkpath;
my $docker = $tools->child('bin/docker');
$docker->spew_utf8("#!/usr/bin/env bash\nexit 0\n");
$docker->chmod(0755);
my %executor = (
  # Runs, and that is all.
  plain => "printf 'the job ran\\n'\n",
  # Turns the report of its own run into a directory: the runner croaks when
  # it publishes the final state.
  unreportable => <<'SCRIPT',
printf 'the job ran\n'
report="$CICD_WORKSPACE/../../public/runs/$CICD_RUN_NUMBER.json"
rm "$report"
mkdir "$report"
SCRIPT
  # The same, and then the worker is told to end during the run.
  stopped => <<'SCRIPT'
printf 'the job ran\n'
report="$CICD_WORKSPACE/../../public/runs/$CICD_RUN_NUMBER.json"
rm "$report"
mkdir "$report"
kill -TERM "$TEST_SUPERVISOR"
sleep 30
SCRIPT
);
for my $name (keys %executor) {
  my $script = $tools->child('executor.'.$name);
  $script->spew_utf8("#!/usr/bin/env bash\nset -euo pipefail\n".$executor{$name});
  $script->chmod(0755);
}
local $ENV{PATH} = $tools->child('bin').':'.$ENV{PATH};
local $ENV{TEST_SUPERVISOR} = $$;

# Where the modules are loaded from, as a path and as Perl names it in an
# error: relative under "prove -l".
my $loaded = $INC{'SimpiCI/Worker.pm'};
my $installation = path($loaded)->absolute->parent(2);
my $module_directory = path($loaded)->parent;

sub private {
  my ( $root ) = @_;
  return qr/\Q$root\E|\Q$installation\E|\Q$module_directory\E|\.pm\b|\bline \d+|\Q$value\E/;
}

my @reasons = SimpiCI::Worker->abort_reasons;

sub claim {
  my ( %change ) = @_;
  my $event = { source => 'git-poll', event => 'push', repository => 'fixture',
    clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit,
    ( $change{event} // {} )->%* };
  delete $event->{$_} for ( $change{without} // [] )->@*;
  return {
    run => 7, token => 'token-of-run-7', timeout => 30,
    secrets => { publish => { PUBLISH_TOKEN => $value }, deploy => {} },
    event => $event, ( $change{claim} // {} )->%*
  };
}

# One cycle of a worker with the given claim. Returns the log it reports,
# what it wrote to standard error, and its store.
sub cycle {
  my ( %arg ) = @_;
  my $keep = tempdir;
  my $root = $keep->child('state-of-the-worker');
  $root->mkpath;
  $arg{prepare}->($root) if $arg{prepare};
  my $store = SimpiCI::Store->new(root => $root);
  my $class = $arg{raise} ? 'AbortingWorker' : $arg{class} // 'ScriptedWorker';
  my $worker = $class->new(host => 'unused', store => $store, claim => $arg{claim} // claim(),
    runner => SimpiCI::Runner->new(store => $store,
      runner_script => $tools->child('executor.'.( $arg{executor} // 'plain' ))),
    $arg{raise} ? ( raise => $arg{raise} ) : ());
  my ( $error, @passed_on );
  my $warnings = warnings {
    # A worker that is told to end passes the signal on to its caller.
    local $SIG{TERM} = sub { push @passed_on, $_[0] };
    eval { $worker->once; 1 } or $error = $@;
  };
  $arg{restore}->($root) if $arg{restore};
  my $pending = $root->child('completion.json');
  my $completion = $pending->is_file ? $json->decode($pending->slurp_utf8)
    : ( grep { $_->{operation} eq 'finish' } $worker->requests->@* )[-1];
  return {
    root => $root, keep => $keep, error => $error, warned => join('', @$warnings),
    completion => $completion, passed_on => \@passed_on
  };
}

# What holds for every claim that was not executed to its end, whatever it
# failed of.
sub aborted_for {
  my ( $name, $reason, $detail, %arg ) = @_;
  my $cycle = cycle(%arg);
  my $root = $cycle->{root};
  my $log = $cycle->{completion}->{log} // '';
  my $line = 'SimpiCI::Worker run 7 aborted: '.$reason;
  is $cycle->{error}, undef, $name.' does not stop the worker';
  is $cycle->{completion}->{result}, { state => 'failed', exit_code => 125 },
    'it is reported as a failed run';
  like $log, qr/(?:\A|\n)\Q$line\E\n\z/, 'its log ends with the reason: '.$reason;
  ok scalar( grep { $_ eq $reason } @reasons ), 'which is one of the list';
  unlike $log, private($root),
    'the log names no path of the worker, no file of the installation, no line and no value';
  my @said = grep { /\ASimpiCI::Worker run 7 aborted: / } split /^/, $cycle->{warned};
  is scalar @said, 1, 'standard error gets one line for it';
  if (defined $detail) {
    like $said[0], qr/\A\Q$line\E: [^\n]*$detail[^\n]*\n\z/,
      'with the reason and what the error said';
  }
  else {
    is $said[0], $line."\n", 'with the reason and nothing else';
  }
  unlike $cycle->{warned}, qr/\Q$value\E/, 'and without a secret value';
  ok !$root->child($_)->exists, $_.' is not left behind'
    for qw( secrets/7 public/runs/7.log work/7 tmp/7 );
  return $cycle;
}

subtest 'the reasons are a closed list' => sub {
  is \@reasons, [
    'invalid event in claim', 'invalid secrets in claim', 'invalid secret name in claim',
    'invalid secret value in claim', 'invalid timeout in claim', 'cannot write secret files',
    'cannot create temporary directory', 'run supervisor failed', 'internal error'
  ], 'abort_reasons lists them';
  is( SimpiCI::Worker->abort_reason($_), $_, $_.' is published as it stands' ) for @reasons;
  is( SimpiCI::Worker->abort_reason($_->[1]), 'internal error',
    $_->[0].' is published as internal error' )
    for [ 'what is no reason of the list', 'cannot publish /var/lib/simpici-worker/x.json' ],
      [ 'a reason with something after it', 'run supervisor failed at /opt/simpici' ],
      [ 'no reason at all', undef ], [ 'a structure', [ 'internal error' ] ];
  is [ grep { !/\A[a-z]+(?: [a-z]+)*\z/ } @reasons ], [],
    'each is a few lowercase words, with no room for a path or a number';
};

subtest 'an event the worker refuses' => sub {
  my %refused = (
    'a ref outside refs/' => [ { ref => 'heads/main' }, qr/SimpiCI::Event ref must start with refs\// ],
    'a ref that is not canonical' => [ { ref => 'refs/heads/a..b' }, qr/SimpiCI::Event ref is not canonical/ ],
    'a short commit' => [ { commit => 'abc123' }, qr/SimpiCI::Event commit must be a full/ ],
    'a clone URL with a space' => [ { clone_url => 'https://forge.invalid/a b.git' },
      qr/SimpiCI::Event clone URL must not contain whitespace/ ],
    'a clone URL with a token' => [ { clone_url => 'https://builder:'.$value.'@forge.invalid/a.git' },
      qr/SimpiCI::Event clone URL must not contain credentials/ ],
    'a clone URL with a password' => [ { clone_url => 'ssh://builder:hunter2@forge.invalid/a.git' },
      qr/SimpiCI::Event clone URL must not contain a password/ ],
    'a repository with a NUL' => [ { repository => "fix\0ture" },
      qr/SimpiCI::Event repository must not contain NUL/ ],
    # A type error quotes what it found: on standard error, not in the log.
    'a source that is none' => [ { source => '/srv/forge/hooks/post-receive' },
      qr{/srv/forge/hooks/post-receive} ]
  );
  for my $name (sort keys %refused) {
    my ( $event, $detail ) = $refused{$name}->@*;
    my $cycle = aborted_for($name, 'invalid event in claim', $detail, claim => claim(event => $event));
    unlike $cycle->{completion}->{log}, qr/hunter2|post-receive|forge\.invalid/,
      'the log quotes nothing of the event';
  }
  my %shapeless = (
    'an event that is a list' => claim(claim => { event => [ 'push' ] }),
    'an event without a commit' => claim(without => ['commit']),
    'a list as clone URL' => claim(event => { clone_url => [ 'ssh://builder:hunter2@forge.invalid/a.git' ] }),
    'a string as payload' => claim(event => { payload => 'ssh://builder:hunter2@forge.invalid/a.git' })
  );
  aborted_for($_, 'invalid event in claim', undef, claim => $shapeless{$_}) for sort keys %shapeless;
};

subtest 'a claim of another shape than the dispatcher sends' => sub {
  my %refused = (
    'secrets that are a list' => [ 'invalid secrets in claim', { secrets => [ $value ] } ],
    'secrets of a phase that are a string' => [ 'invalid secrets in claim', { secrets => { publish => $value } } ],
    'a secret name that is no variable' => [ 'invalid secret name in claim',
      { secrets => { publish => { 'PUBLISH_TOKEN=x' => $value } } } ],
    'a secret value of two lines' => [ 'invalid secret value in claim',
      { secrets => { deploy => { DEPLOY_TOKEN => $value."\nCICD_REGISTRY=forged.invalid" } } } ],
    'a timeout that is a word' => [ 'invalid timeout in claim', { timeout => '/opt/soon' } ],
    'a timeout that is a fraction' => [ 'invalid timeout in claim', { timeout => 1.5 } ],
    'a timeout that is a list' => [ 'invalid timeout in claim', { timeout => [ 30 ] } ],
    'no timeout' => [ 'invalid timeout in claim', { timeout => undef } ]
  );
  for my $name (sort keys %refused) {
    my ( $reason, $change ) = $refused{$name}->@*;
    my $cycle = aborted_for($name, $reason, undef, claim => claim(claim => $change));
    unlike $cycle->{completion}->{log}, qr/forged|soon/, 'the log quotes nothing of the claim';
    ok !$cycle->{root}->child('secrets')->exists, 'and no secret file is written for it';
  }
};

subtest 'files the worker cannot write' => sub {
  my $cycle = aborted_for('a secret directory that cannot be created', 'cannot write secret files',
    qr{state-of-the-worker/secrets}, prepare => sub { $_[0]->child('secrets')->spew_utf8('no directory') });
  $cycle = aborted_for('a temporary directory that cannot be created',
    'cannot create temporary directory', qr{state-of-the-worker/tmp},
    prepare => sub { $_[0]->child('tmp')->spew_utf8('no directory') });
};

subtest 'a run supervisor that fails' => sub {
  my $cycle = aborted_for('a report that cannot be published', 'run supervisor failed',
    qr{SimpiCI::Store->write_json cannot publish \S*state-of-the-worker/public/runs/7\.json: },
    executor => 'unreportable');
  like $cycle->{completion}->{log}, qr/^the job ran$/m, 'what the run wrote up to then is reported';

  $cycle = aborted_for('an instance that cannot be read', 'run supervisor failed',
    qr{SimpiCI::Store invalid instance in \S*state-of-the-worker/instance},
    prepare => sub { $_[0]->child('instance')->spew_utf8("no instance\n") });
  unlike $cycle->{completion}->{log}, qr/the job ran/, 'no job was started for it';

  SKIP: {
    skip 'the superuser creates a directory wherever it likes' unless $>;
    aborted_for('a checkout that cannot be created', 'run supervisor failed',
      qr{state-of-the-worker/work/7},
      prepare => sub { $_[0]->child('work')->mkpath; $_[0]->child('work')->chmod(0500) },
      restore => sub { $_[0]->child('work')->chmod(0700) });
  }
};

subtest 'a run that was stopped and cannot be reported' => sub {
  my $cycle = aborted_for('it', 'run supervisor failed',
    qr{SimpiCI::Runner cannot report run 7: SimpiCI::Store->write_json cannot publish \S*state-of-the-worker/},
    executor => 'stopped');
  like $cycle->{completion}->{log}, qr/^SimpiCI::Runner run 7 stopped by signal TERM$/m,
    'the log says that it was stopped';
  ok scalar $cycle->{passed_on}->@*, 'and the signal is passed on';
};

subtest 'an error nobody expected' => sub {
  my @raised = (
    [ 'a die', sub { die 'no supervisor' }, qr/no supervisor at \S+ line \d+\./ ],
    [ 'a croak', sub { croak 'cannot reach git at forge.invalid' },
      qr/cannot reach git at forge\.invalid at \S+ line \d+\./ ],
    [ 'a backtrace', sub { confess 'deep failure' }, qr/deep failure at \S+ line \d+\./ ],
    [ 'an error of Path::Tiny', sub { path('/nonexistent/simpici/private.key')->slurp_utf8 },
      qr{/nonexistent/simpici/private\.key} ],
    [ 'an error that is a structure', sub { die { file => '/opt/simpici/etc/worker.json' } },
      qr/HASH\(0x[0-9a-f]+\)/ ],
    [ 'a reason of the list that was raised, not returned', sub { die "run supervisor failed\n" },
      qr/run supervisor failed/ ],
    # (I) Nothing is cut off a message any more, because none is published.
    [ 'a message that itself ends like a place in a file',
      sub { die "cannot read the counter at byte 3 line 7\n" },
      qr/cannot read the counter at byte 3 line 7/ ],
    # (J) A path with " at " in it has nowhere left to stay.
    [ 'an installation whose path has " at " in it',
      sub { die "boom at /opt/simpici at ci/lib/SimpiCI/Runner.pm line 5.\n" },
      qr{boom at /opt/simpici at ci/lib/SimpiCI/Runner\.pm line 5\.} ]
  );
  for my $case (@raised) {
    my ( $name, $raise, $detail ) = @$case;
    my $cycle = aborted_for($name, 'internal error', $detail, raise => $raise);
    is $cycle->{completion}->{log}, "SimpiCI::Worker run 7 aborted: internal error\n",
      'the log is the reason alone';
    unlike $cycle->{completion}->{log}, qr{/opt/simpici|/nonexistent|forge\.invalid|counter},
      'and has nothing of the message';
  }
};

subtest 'a reason that is not of the list' => sub {
  my $cycle = aborted_for('it', 'internal error', qr/said on standard error/, class => 'InventiveWorker');
  is $cycle->{completion}->{log}, "SimpiCI::Worker run 7 aborted: internal error\n",
    'is not published, whoever gave it';
};

subtest 'the reasons are documented' => sub {
  # As a reader finds them: each in the markup of the document, and so not
  # merely because the code of the module has them.
  my %document = ( 'the manual of SimpiCI::Worker' => [ path($loaded), 'C<%s>' ] );
  my $operations = path('deploy/README.md');
  $document{'the operations guide'} = [ $operations, '`%s`' ] if $operations->is_file;
  for my $name (sort keys %document) {
    my ( $file, $markup ) = $document{$name}->@*;
    my $text = $file->slurp_utf8;
    ok index($text, sprintf $markup, $_) >= 0, $name.' names '.$_ for @reasons;
  }
};

done_testing;
