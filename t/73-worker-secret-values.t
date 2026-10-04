use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Path::Tiny qw( path tempdir );
use SimpiCI::Runner;
use SimpiCI::Store;
use SimpiCI::Worker;

# A secret of a claim is written as one NAME=VALUE line of an environment
# file. A claim with a secret that is not one such line is not executed: it
# is reported as a failed run, and no secret file is written for it.

{
  package FixedClaim;
  use Moo;
  has claim => (is => 'ro');
  sub request { $_[0]->claim }
}

{
  package TestWorker;
  use Moo;
  extends 'SimpiCI::Worker';
  has dispatcher => (is => 'ro');
  has requests => (is => 'ro', default => sub { [] });
  sub _request {
    my ( $self, $request ) = @_;
    push $self->requests->@*, $request;
    return $self->dispatcher->request('vm', $request);
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

my $good = 'good-secret-value';
my $inner = 'value-inside-a-structure';
my $raised_at = qr/ at \S.* line \d+|\.pm\b/;

sub attempt {
  my ( $secrets ) = @_;
  my $root = tempdir;
  my $executor = $root->child('executor');
  $executor->spew_utf8(<<'SCRIPT');
#!/usr/bin/env bash
set -euo pipefail
cat "$SIMPICI_SECRETS_DIR/publish.env" "$SIMPICI_SECRETS_DIR/deploy.env"
printf 'ran\n' > "$CICD_WORKSPACE/../../executed"
SCRIPT
  $executor->chmod(0755);
  my $store = SimpiCI::Store->new(root => $root);
  my $worker = TestWorker->new(host => 'unused', store => $store,
    runner => SimpiCI::Runner->new(store => $store, runner_script => $executor),
    dispatcher => FixedClaim->new(claim => {
      run => 7, token => 'unused', timeout => 10, secrets => $secrets,
      event => { source => 'git-poll', event => 'push', repository => 'fixture',
        clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit }
    }));
  my $error;
  my $warnings = warnings { eval { $worker->once; 1 } or $error = $@ };
  return ( $root, $worker->requests->[-1], join('', @$warnings), $error );
}

my %refused_value = (
  'an undefined value'        => undef,
  'an object as value'        => { inner => $inner },
  'a list as value'           => [ $inner ],
  'an empty value'            => '',
  'a value of two lines'      => $inner."\nCICD_REGISTRY=forged.invalid",
  'a value with a line end'   => $inner."\n",
  'a value with a return'     => $inner."\r",
  'a value with a NUL'        => $inner."\0"
);
my %refused_name = (
  'a name with an assignment' => 'PUBLISH_TOKEN=x',
  'a name of two lines'       => "PUBLISH_TOKEN=x\nCICD_REGISTRY",
  'a name in lower case'      => 'publish_token',
  'an empty name'             => '',
  'a name that is no token'   => 'PATH'
);

for my $phase (qw( publish deploy )) {
  for my $case (sort keys %refused_value) {
    my ( $root, $finish, $warned, $error ) = attempt({
      $phase => { GOOD_TOKEN => $good, PUBLISH_TOKEN => $refused_value{$case} }
    });
    my $reason = "SimpiCI::Worker run 7 aborted: SimpiCI::Worker invalid secret value in claim\n";
    is $error, undef, $case.' in '.$phase.' does not stop the worker';
    is $finish->{result}, { state => 'failed', exit_code => 125 }, 'it is reported as a failed run';
    is $finish->{log}, $reason, 'with the reason as its log';
    is $warned, $reason, 'which the worker also writes to standard error';
    unlike $finish->{log}.$warned, qr/\Q$good\E|\Q$inner\E|HASH|ARRAY|forged|$raised_at/,
      'and which quotes no value and no place of the installation';
    ok !$root->child('secrets')->exists, 'no secret file is written';
    ok !$root->child('executed')->exists, 'and nothing is executed';
  }
}

for my $case (sort keys %refused_name) {
  my ( $root, $finish, $warned, $error ) = attempt({
    publish => { GOOD_TOKEN => $good, $refused_name{$case} => $inner }
  });
  my $reason = "SimpiCI::Worker run 7 aborted: SimpiCI::Worker invalid secret name in claim\n";
  is $error, undef, $case.' does not stop the worker';
  is $finish->{result}, { state => 'failed', exit_code => 125 }, 'it is reported as a failed run';
  is $finish->{log}, $reason, 'with the reason as its log';
  is $warned, $reason, 'which the worker also writes to standard error';
  ok !$root->child('secrets')->exists, 'no secret file is written';
  ok !$root->child('executed')->exists, 'and nothing is executed';
}

subtest 'secrets that are one line each' => sub {
  my ( $root, $finish, $warned ) = attempt({
    publish => { CICD_REGISTRY_PASSWORD => 'p=a ss#word', PUBLISH_TOKEN => $good },
    deploy  => { DEPLOY_TOKEN => 'another value' }
  });
  is $finish->{result}, { state => 'success', exit_code => 0 }, 'are executed';
  like $finish->{log}, qr/^CICD_REGISTRY_PASSWORD=\[REDACTED\]\nPUBLISH_TOKEN=\[REDACTED\]\nDEPLOY_TOKEN=\[REDACTED\]$/m,
    'each written as its own line of its phase';
  ok $root->child('executed')->is_file, 'the job ran';
  ok !$root->child('secrets/7')->exists, 'and its secret files are removed';
};

subtest 'a claim without secrets' => sub {
  for my $secrets ({}, undef, { publish => {} }) {
    my ( $root, $finish, $warned ) = attempt($secrets);
    is $finish->{result}, { state => 'success', exit_code => 0 }, 'is executed';
  }
};

done_testing;
