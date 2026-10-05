#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX ();

# Standard error of simpici-dispatch is standard error of the ssh of a
# worker. A worker is told that its request failed and for which of a few
# fixed reasons, and nothing else: not the repositories of others, not the
# names and files of their secrets, not the paths of this installation. What
# went wrong in detail is written where the operator of the dispatcher reads
# it, into dispatch.log below the state root.

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $token = $root->child('package-token');
$token->spew_utf8("dispatch-secret-value\n");
my $missing = $root->child('private-dir-of-another-team', 'no-such-token');
my $program = path('bin/simpici-dispatch')->absolute;
my $lib = path('lib')->absolute;

my @reasons = ( 'configuration unusable', 'request not read in time', 'request too large',
  'invalid request', 'internal error' );
is [ SimpiCI::Dispatcher->failure_reasons ], \@reasons, 'a failed request has one of five reasons';
is(scalar(SimpiCI::Dispatcher->failure_reason($_)), $_, '"'.$_.'" is said as it is') for @reasons;
is(scalar(SimpiCI::Dispatcher->failure_reason($_)), 'internal error', 'anything else is an internal error')
  for 'cannot read secret file /etc/simpici/secrets/x', '', undef, 'Configuration unusable';

sub grant {
  my ( %override ) = @_;
  return { name => 'CICD_PACKAGE_TOKEN', file => "$token", refs => ['refs/tags/*'],
    events => ['push'], phases => ['publish'], %override };
}

# A state root of its own for each case, with one queued run.
my $states = 0;
sub state {
  my $store = SimpiCI::Store->new(root => $root->child('state-'.++$states));
  SimpiCI::Queue->new(store => $store)->run(SimpiCI::Event->new(source => 'git-poll', event => 'push',
    repository => 'owner/queued', clone_url => '/srv/git/queued.git', ref => 'refs/heads/main',
    commit => 'a' x 40));
  return $store->root;
}

sub record { $json->decode($_[0]->child('queue/1.json')->slurp_utf8) }

# simpici-dispatch as a process: exit status, standard output, standard error.
sub dispatch {
  my ( $config, $request, %option ) = @_;
  my $config_file = $root->child('dispatch.json');
  $config_file->spew_utf8(ref $config ? $json->encode($config) : $config) if defined $config;
  my %file = map { $_ => $root->child('dispatch.'.$_) } qw( stdin stdout stderr );
  $file{stdin}->spew_utf8(ref $request ? $json->encode($request) : $request);
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDIN, '<', $file{stdin}->stringify or POSIX::_exit(97);
    open STDOUT, '>', $file{stdout}->stringify or POSIX::_exit(97);
    open STDERR, '>', $file{stderr}->stringify or POSIX::_exit(97);
    exec $^X, '-I'.$lib, "$program", '--config', $option{config} // "$config_file",
      '--worker', $option{worker} // 'test-vm' or POSIX::_exit(98);
  }
  waitpid($pid, 0);
  my $status = $?;
  return ( $status & 127 ? 'signal '.( $status & 127 ) : $status >> 8,
    $file{stdout}->slurp_utf8, $file{stderr}->slurp_utf8 );
}

sub log_lines {
  my ( $state ) = @_;
  my $log = $state->child('dispatch.log');
  return [] unless $log->is_file;
  return [ $log->lines_utf8({ chomp => 1 }) ];
}

my $stamp = qr/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/;

# What a worker must not learn from a failure.
sub says_only {
  my ( $stderr, $reason, $state, $label ) = @_;
  is $stderr, 'simpici-dispatch: '.$reason."\n", $label.': standard error has the reason and nothing else';
}

#### A grant of another repository that cannot be used

{
  my $state = state();
  my $config = { root => "$state", repositories => [
    { name => 'owner/queued', clone_url => '/srv/git/queued.git' },
    { name => 'other-team/private-project', clone_url => '/srv/git/private.git', secrets => [
      grant(name => 'CICD_DEPLOY_TOKEN', file => "$missing"), grant(),
      grant(name => 'CICD_OTHER_TOKEN', events => []) ] }
  ] };
  my ( $status, $stdout, $stderr ) = dispatch($config, { operation => 'claim' });
  is [ $status, $stdout ], [ 1, '' ], 'a claim on a configuration with an unusable grant fails with 1 and answers nothing';
  says_only($stderr, 'configuration unusable', $state, 'the worker');
  unlike $stderr, qr/other-team|private|CICD_|\Q$root\E|line [0-9]/,
    'neither the repository of the other, nor its secret, nor a path';
  my $lines = log_lines($state);
  is scalar(@$lines), 2, 'the log of the dispatcher has a line for each unusable grant';
  like $lines->[0], qr/\A$stamp worker test-vm: configuration unusable: SimpiCI::Dispatcher repository other-team\/private-project \(repositories\[1\]\), secret CICD_DEPLOY_TOKEN \(secrets\[0\]\): cannot read secret file: No such file or directory\z/,
    'with the time, the worker, the reason and what was wrong';
  like $lines->[1], qr/\A$stamp worker test-vm: configuration unusable: SimpiCI::Dispatcher repository other-team\/private-project \(repositories\[1\]\), secret CICD_OTHER_TOKEN \(secrets\[2\]\): events must name at least one event: the grant would apply to no run\z/,
    'for the second grant as for the first';
  unlike join("\n", @$lines), qr/\Q$missing\E|dispatch-secret-value/, 'without the path of a secret file or a value';
  is sprintf('%04o', ( stat $state->child('dispatch.log')->stringify )[2] & 07777), '0600',
    'the log is readable by the account alone';
  is record($state)->{state}, 'queued', 'no lease is taken';
  ok !$state->child('claims')->exists, 'and no snapshot written';

  # The completion of a run needs no grant.
  $config->{repositories}[1]{secrets} = [];
  ( $status, $stdout ) = dispatch($config, { operation => 'claim' });
  my $claim = $json->decode($stdout);
  is [ $status, $claim->{run} ], [ 0, 1 ], 'the claim is served once the configuration is usable';
  is scalar(@{ log_lines($state) }), 2, 'a request that is served writes no line';
  ( $status, $stdout, $stderr ) = dispatch($config, { operation => 'finish', run => 1,
    token => $claim->{token}, result => { state => 'success', exit_code => 0 }, log => [ 'done' ] });
  is [ $status, $stdout ], [ 1, '' ], 'a completion with a log that is no text fails';
  says_only($stderr, 'invalid request', $state, 'such a completion');
  like log_lines($state)->[2] // '', qr/\A$stamp worker test-vm: invalid request: SimpiCI::Dispatcher invalid log\z/,
    'and the log says what was wrong with it';
  $config->{repositories}[1]{secrets} = [ grant(file => "$missing") ];
  $config->{timeout} = 'soon';
  ( $status, $stdout, $stderr ) = dispatch($config, { operation => 'finish', run => 1,
    token => $claim->{token}, result => { state => 'success', exit_code => 0 }, log => 'done' });
  is [ $status, $stderr, $json->decode($stdout)->{state} ], [ 0, '', 'success' ],
    'a completion is accepted on a configuration no claim is served from';
}

#### The settings a request uses

for my $case (
  [ { timeout => 'soon' }, 'timeout must be a positive integer', 'a timeout that is a word' ],
  [ { timeout => 1.5 }, 'timeout must be a positive integer', 'a timeout that is a fraction' ],
  [ { timeout => [ 3600 ] }, 'timeout must be a positive integer', 'a timeout that is a list' ],
  [ { timeout => 0 }, 'timeout must be a positive integer', 'a timeout of zero' ],
  [ { request_read_timeout => 'never' }, 'request_read_timeout must be a positive integer',
    'a request_read_timeout that is a word' ]
) {
  my ( $settings, $detail, $label ) = @$case;
  my $state = state();
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [], %$settings },
    { operation => 'claim' });
  is [ $status, $stdout ], [ 1, '' ], $label.' fails the claim';
  says_only($stderr, 'configuration unusable', $state, $label);
  like log_lines($state)->[0] // '', qr/\A$stamp worker test-vm: configuration unusable: (?:SimpiCI::Dispatcher|simpici-dispatch) \Q$detail\E\z/,
    $label.': the log names the setting, not its value';
  is record($state)->{state}, 'queued', $label.': no lease is taken, so no worker gets a claim it has to abort';
}

#### A configuration that cannot be read

{
  my $state = state();
  for my $case (
    [ '{ "root": "'.$state.'", "repositories": [', 'a file that is no JSON' ],
    [ '["'.$state.'"]', 'a list in place of the configuration' ],
    [ { repositories => [] }, 'a configuration without a root' ],
    [ { root => [ "$state" ], repositories => [] }, 'a root that is a list' ]
  ) {
    my ( $config, $label ) = @$case;
    my ( $status, $stdout, $stderr ) = dispatch($config, { operation => 'claim' });
    is [ $status, $stdout ], [ 1, '' ], $label.' fails the request';
    says_only($stderr, 'configuration unusable', $state, $label);
  }
  my ( $status, $stdout, $stderr ) = dispatch(undef, { operation => 'claim' },
    config => $root->child('private-dir-of-another-team', 'dispatcher.json')->stringify);
  is [ $status, $stdout ], [ 1, '' ], 'a configuration file that is not there fails the request';
  says_only($stderr, 'configuration unusable', $state, 'a missing file');
  is log_lines($state), [], 'without a state root there is no log to write to';
  is record($state)->{state}, 'queued', 'nothing is claimed';
}

#### A request that is none

{
  my $state = state();
  my $config = { root => "$state", repositories => [] };
  my $secret_looking = 'lease-token-0123456789abcdef';
  for my $case (
    [ '{"operation":"finish","token":"'.$secret_looking.'",', 'a request that is no JSON' ],
    [ '["claim"]', 'a list in place of a request' ],
    [ '"'.$secret_looking.'"', 'a string in place of a request' ],
    [ { operation => 'retry-'.$secret_looking }, 'an operation the protocol does not have' ],
    [ { run => 1 }, 'a request without an operation' ],
    [ { operation => 'finish', run => '../'.$secret_looking, token => 'x' }, 'a run that is no number' ]
  ) {
    my ( $request, $label ) = @$case;
    my $before = scalar @{ log_lines($state) };
    my ( $status, $stdout, $stderr ) = dispatch($config, $request);
    is [ $status, $stdout ], [ 1, '' ], $label.' fails';
    says_only($stderr, 'invalid request', $state, $label);
    my @new = @{ log_lines($state) }[ $before .. $#{ log_lines($state) } ];
    is scalar(@new), 1, $label.': one line in the log';
    like $new[0] // '', qr/\A$stamp worker test-vm: invalid request: /, $label.': with the reason';
    unlike $new[0] // '', qr/\Q$secret_looking\E/, $label.': and nothing of what was sent';
  }
  is record($state)->{state}, 'queued', 'none of them took a lease';
}

{
  my $state = state();
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [] },
    '{"operation":"finish","log":"'.( 'x' x ( 8 * 1024 * 1024 ) ).'"}');
  is [ $status, $stdout ], [ 1, '' ], 'a request of more than 8 MiB fails';
  says_only($stderr, 'request too large', $state, 'too large');
  like log_lines($state)->[0] // '', qr/\A$stamp worker test-vm: request too large: /, 'the log says so too';
}

#### What the dispatcher itself cannot do

{
  my $state = state();
  # A queue that cannot be read: an entry that is no JSON.
  $state->child('queue/2.json')->spew_utf8('{ "run": 2, ');
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [] }, { operation => 'claim' });
  is [ $status, $stdout ], [ 1, '' ], 'a queue that cannot be read fails the request';
  says_only($stderr, 'internal error', $state, 'an internal error');
  like log_lines($state)->[0] // '', qr/\A$stamp worker test-vm: internal error: \S.* at \S+ line [0-9]+\.?\z/,
    'the log has the error as it was raised, with the place';
}

{
  # A worker name the queue refuses: a mistake in authorized_keys.
  my $state = state();
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [] }, { operation => 'claim' },
    worker => "vm\e[2J one");
  is [ $status, $stdout ], [ 1, '' ], 'a worker name the queue refuses fails the request';
  says_only($stderr, 'internal error', $state, 'a refused worker name');
  my $line = log_lines($state)->[0] // '';
  like $line, qr/\A$stamp worker vm\?\[2J one: internal error: SimpiCI::Queue invalid worker/,
    'the log shows the name with its control character replaced';
  unlike $line, qr/[\x00-\x1f\x7f]/, 'and has no control character in it';
}

{
  # A name in the configuration that would move the terminal of whoever
  # reads the log.
  my $state = state();
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [
    { name => "team/\e[2Jproject", clone_url => '/srv/git/x.git', secrets => [ grant(file => "$missing") ] } ] },
    { operation => 'claim' });
  says_only($stderr, 'configuration unusable', $state, 'a name with a control character');
  my $line = log_lines($state)->[0] // '';
  like $line, qr/: SimpiCI::Dispatcher repository \? \(repositories\[0\]\), secret CICD_PACKAGE_TOKEN \(secrets\[0\]\): /,
    'the log names the entry by its position, not by a name that is no line of text';
  unlike $line, qr/[\x00-\x1f\x7f]|project/, 'and has nothing of that name in it';
}

#### A warning of Perl

{
  # A warning names a file of the installation and its line, and may quote
  # what it warns about. Printing a claim with a secret value that has a
  # character beyond Latin-1 is one way to get one; whether that still warns
  # or not, nothing of it goes to the worker.
  my $state = state();
  my $wide = $root->child('wide-token');
  $wide->spew_utf8("pass\x{20ac}word\n");
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [
    { name => 'owner/queued', clone_url => '/srv/git/queued.git', secrets => [
      grant(file => "$wide", refs => ['refs/heads/main']) ] } ] }, { operation => 'claim' });
  is [ $status, $stderr ], [ 0, '' ], 'a request that is served says nothing on standard error, whatever Perl warns of';
  like $stdout, qr/"run":1\b/, 'and is answered';
  my @logged = @{ log_lines($state) };
  is [ grep { !/\A$stamp worker test-vm: warning: \S/ } @logged ], [],
    'a warning, if there was one, is a line of the log of the dispatcher';
  unlike join("\n", @logged), qr/pass|word/, 'without the value';
}

#### The log

{
  # A log that cannot be written does not change what the worker is told.
  my $state = state();
  $state->child('dispatch.log')->mkpath;
  my ( $status, $stdout, $stderr ) = dispatch({ root => "$state", repositories => [], timeout => 'soon' },
    { operation => 'claim' });
  is [ $status, $stdout ], [ 1, '' ], 'with a log that cannot be written the request fails as it would';
  says_only($stderr, 'configuration unusable', $state, 'no log');
}

{
  # The log does not grow without end: at its limit it is set aside once.
  my $state = state();
  my $limit = SimpiCI::Dispatcher->failure_log_limit;
  is $limit, 1024 * 1024, 'the log is set aside at 1 MiB';
  my $log = $state->child('dispatch.log');
  my $old = ( 'an older line'."\n" ) x ( $limit / 14 + 1 );
  $log->spew_utf8($old);
  $state->child('dispatch.log.1')->spew_utf8('what was set aside before'."\n");
  my $config = { root => "$state", repositories => [], timeout => 'soon' };
  dispatch($config, { operation => 'claim' });
  is $state->child('dispatch.log.1')->slurp_utf8, $old, 'a log at its limit becomes dispatch.log.1, in place of the one before';
  is scalar(@{ log_lines($state) }), 1, 'and the new line begins a new log';
  dispatch($config, { operation => 'claim' });
  is scalar(@{ log_lines($state) }), 2, 'which the next line is appended to';
  is $state->child('dispatch.log.1')->slurp_utf8, $old, 'while what was set aside stays';
}

done_testing;
