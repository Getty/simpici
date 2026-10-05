use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::App::Eventd;
use SimpiCI::Dispatcher;
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $token = $root->child('package-token');
$token->spew_utf8("tag-secret\n");
my $empty = $root->child('empty-token');
$empty->spew_utf8("\n");
my $two_lines = $root->child('two-lines');
$two_lines->spew_utf8("leaky-alpha\nleaky-beta\n");
# What is pasted from a published log instead of the value.
my $marked = $root->child('marked-token');
$marked->spew_utf8("leaky-prefix[REDACTED]leaky-suffix\n");
my $missing = $root->child('no-such-token');

sub grant {
  my ( %override ) = @_;
  return { name => 'CICD_PACKAGE_TOKEN', file => "$token", refs => ['refs/tags/*'],
    events => ['push'], phases => ['publish'], %override };
}

# The grants sit on the second repository, so a message has to name the
# repository instead of the first one it finds.
sub config_for {
  my ( @secrets ) = @_;
  return { repositories => [
    { name => 'owner/other', clone_url => '/other' },
    { name => 'owner/repo', clone_url => '/fixture', secrets => \@secrets }
  ] };
}

sub queue_in {
  my ( $name ) = @_;
  return SimpiCI::Queue->new(store => SimpiCI::Store->new(root => $root->child($name)));
}

sub dispatcher_for {
  my ( @secrets ) = @_;
  return SimpiCI::Dispatcher->new(queue => queue_in('unused'), config => config_for(@secrets));
}

sub record_of {
  my ( $state, $run ) = @_;
  return $json->decode($root->child($state, 'queue', $run.'.json')->slurp_utf8);
}

my %tag_event = (source => 'git-poll', event => 'push', repository => 'owner/repo',
  clone_url => '/fixture', ref => 'refs/tags/1.0');

#### Whole configuration is checked, whatever event arrives

ok dispatcher_for(grant(), grant(name => 'CICD_REGISTRY_PASSWORD', phases => ['publish', 'deploy']))->validate,
  'usable grants pass';
ok dispatcher_for()->validate, 'a repository without grants passes';

my $no_run = ': the grant would apply to no run';
for my $case (
  [{refs => ['refs/tags/*', 'refs/*']}, qr/invalid ref pattern \(refs\[1\]\) at /, 'ref pattern'],
  [{refs => 'refs/tags/*'}, qr/refs must be a list/, 'refs that are no list'],
  [{events => 'push'}, qr/events must be a list/, 'events that are no list'],
  [{sources => 'git-poll'}, qr/sources must be a list/, 'sources that are no list'],
  [{phases => 'publish'}, qr/phases must be a list/, 'phases that are no list'],
  [{phases => ['publish', 'build']}, qr/secrets only allowed in publish\/deploy/, 'phase outside publish/deploy'],
  [{file => "$missing"}, qr/cannot read secret file: No such file or directory at /, 'missing secret file'],
  [{file => undef}, qr/secret file missing/, 'grant without a file'],
  [{file => "$empty"}, qr/secret must be one nonempty line/, 'empty secret file'],
  [{file => "$two_lines"}, qr/secret must be one nonempty line/, 'secret file with two lines'],
  [{file => "$marked"}, qr/secret must not contain \[REDACTED\], the marker of a redacted value/,
    'secret that holds the redaction marker'],
  # Grants that no event could ever match.
  [{refs => []}, qr/refs must name at least one ref or pattern\Q$no_run\E at /, 'an empty list of refs'],
  [{refs => undef}, qr/refs must name at least one ref or pattern\Q$no_run\E at /, 'a grant without refs'],
  [{events => []}, qr/events must name at least one event\Q$no_run\E at /, 'an empty list of events'],
  [{events => undef}, qr/events must name at least one event\Q$no_run\E at /, 'a grant without events'],
  [{events => ['pull_request']},
    qr/events must name an event other than pull_request, which receives no secret\Q$no_run\E at /,
    'a grant for pull requests alone'],
  [{sources => []}, qr/sources must name at least one source if it is given\Q$no_run\E at /,
    'an empty list of sources'],
  [{sources => ['git-poll', 'cron']}, qr/sources must be of git-poll, webhook and manual at /,
    'a source no event has'],
  [{phases => []}, qr/phases must name publish or deploy if it is given\Q$no_run\E at /,
    'an empty list of phases'],
  [{refs => ['refs/tags/*', 'tags/1.0']}, qr/invalid ref \(refs\[1\]\): ref must start with refs\/ at /,
    'an exact ref outside refs/'],
  [{refs => ['refs/heads/ma in']}, qr/invalid ref \(refs\[0\]\): ref is not canonical at /,
    'an exact ref no event carries']
) {
  my ( $override, $reason, $label ) = @$case;
  my $died = dies { dispatcher_for(grant(), grant(%$override))->validate };
  like $died,
    qr/repository owner\/repo \(repositories\[1\]\), secret CICD_PACKAGE_TOKEN \(secrets\[1\]\): $reason/,
    'reject '.$label.' and name repository and secret';
  unlike $died // '', qr/\Q$missing\E|refs\/\*|tags\/1\.0|ma in|cron/,
    'without the path of the secret file or the value that is refused';
}
ok dispatcher_for(grant(events => ['push', 'pull_request'], sources => ['git-poll', 'manual', 'webhook'],
  refs => ['refs/heads/main', 'refs/tags/*'], phases => ['deploy']))->validate,
  'a grant that names pull_request beside another event, every source and one phase passes';
{
  my %sourceless = grant()->%*;
  delete @sourceless{qw( sources phases )};
  ok dispatcher_for(\%sourceless)->validate, 'sources and phases may be left out';
}
for my $name ('lowercase', 'PLAIN', 'CICD_', '', "CICD_\e[2JX", 'glpat-in-the-wrong-place') {
  my $died = dies { dispatcher_for(grant(name => $name))->validate };
  like $died, qr/repository owner\/repo \(repositories\[1\]\), secret \? \(secrets\[0\]\): invalid secret name/,
    'reject a secret name that is none';
  unlike $died, qr/lowercase|PLAIN|CICD_|\e|glpat/, 'and do not repeat it: it may be the value';
}

# A repository whose name no event carries has grants that apply to no run.
# Its name is not printed: it is no line of text.
{
  my $config = { repositories => [ { name => "owner/re\e[2Jpo\n", clone_url => '/fixture', secrets => [ grant() ] } ] };
  my $died = dies { SimpiCI::Dispatcher->new(queue => queue_in('unused'), config => $config)->validate };
  like $died, qr/\ASimpiCI::Dispatcher repository \? \(repositories\[0\]\), secret CICD_PACKAGE_TOKEN \(secrets\[0\]\): repository name must not contain control characters at /,
    'reject the grant of a repository whose name has control characters, without the name';
  unlike $died, qr/[\x00-\x09\x0b-\x1f\x7f]|2J/, 'nothing of it is in the message';
}

#### Every unusable grant is found

{
  my $dispatcher = dispatcher_for(grant(file => "$missing"), grant(), grant(name => 'CICD_TWO', refs => []),
    'CICD_PACKAGE_TOKEN');
  my $where = 'SimpiCI::Dispatcher repository owner/repo (repositories[1]), secret ';
  my @expected = (
    $where.'CICD_PACKAGE_TOKEN (secrets[0]): cannot read secret file: No such file or directory',
    $where.'CICD_TWO (secrets[2]): refs must name at least one ref or pattern'.$no_run,
    $where.'? (secrets[3]): grant must be an object'
  );
  is [ $dispatcher->problems ], \@expected, 'problems lists every unusable grant, in the order of the configuration';
  is [ SimpiCI::Dispatcher->problems($dispatcher->config) ], \@expected,
    'for a configuration that is handed over as well, without a queue';
  like dies { $dispatcher->validate }, qr/\A\Q$expected[0]\E at /, 'validate croaks with the first of them';
  is [ dispatcher_for(grant())->problems ], [], 'a usable configuration has none';
  is [ SimpiCI::Dispatcher->problems({ repositories => 'none' }) ],
    [ 'SimpiCI::Dispatcher repositories must be a list' ], 'repositories that are no list are one problem';
  is [ SimpiCI::Dispatcher->problems({ repositories => [ 'bare', { name => 'owner/x', clone_url => '/x',
    secrets => 'none' } ] }) ],
    [ 'SimpiCI::Dispatcher repositories[0] must be an object',
      'SimpiCI::Dispatcher repository owner/x (repositories[1]): secrets must be a list' ],
    'and so is an entry that is no object and one whose secrets are no list';
}
like dies { dispatcher_for(grant(name => undef))->validate },
  qr/repository owner\/repo \(repositories\[1\]\), secret \? \(secrets\[0\]\): invalid secret name/,
  'reject a grant without a name';
like dies { dispatcher_for('CICD_PACKAGE_TOKEN')->validate },
  qr/repository owner\/repo \(repositories\[1\]\), secret \? \(secrets\[0\]\): grant must be an object/,
  'reject a grant that is no object';
unlike dies { dispatcher_for(grant(file => "$two_lines"))->validate }, qr/leaky/,
  'a rejected secret file does not leak its content';
unlike dies { dispatcher_for(grant(file => "$marked"))->validate }, qr/leaky/,
  'nor does one that is rejected for the marker in it';

#### Reserved names follow the executor

# Every CICD_ name the executor assigns a value to in a container. A secret of
# that name would be overridden by the executor or would forge job context.
my $executor = path('bin/simpici-executor')->slurp_utf8;
my ( %assigned, %passed );
$assigned{$1} = 1 while $executor =~ /-e\s+"?(CICD_[A-Z0-9_]+)=/g;
$passed{$1} = 1 while $executor =~ /-e\s+(CICD_[A-Z0-9_]+)(?=\s)/g;
is [sort SimpiCI::Dispatcher->reserved_secret_names], [sort keys %assigned],
  'reserved secret names are exactly the variables the executor assigns';
ok $assigned{$_}, 'executor assigns '.$_ for qw( CICD_BRANCH CICD_TAG CICD_IMAGE_REPOSITORY );
is [sort keys %passed], ['CICD_REGISTRY_PASSWORD'],
  'the registry password is the one variable the executor only passes through';
for my $name (sort keys %assigned) {
  like dies { dispatcher_for(grant(name => $name))->validate },
    qr/secret \Q$name\E \(secrets\[0\]\): invalid secret name: reserved for the executor/,
    'a secret cannot be named '.$name;
}

#### A broken configuration takes no lease

my $queue = queue_in('state');
is $queue->run(SimpiCI::Event->new(%tag_event, commit => 'a' x 40))->{run}, 1, 'queue a tag run';
for my $case (
  [config_for(grant(file => "$missing")), qr/cannot read secret file/, 'a grant that matches the queued run'],
  [config_for(grant(refs => ['refs/heads/never'], name => 'CICD_TAG')), qr/invalid secret name/,
    'a grant that matches no queued run'],
  [{ repositories => [
      { name => 'owner/other', clone_url => '/other', secrets => [grant(phases => ['test'])] },
      { name => 'owner/repo', clone_url => '/fixture', secrets => [grant()] }
    ] }, qr/repository owner\/other \(repositories\[0\]\), secret CICD_PACKAGE_TOKEN \(secrets\[0\]\): .*publish\/deploy/, 'a grant of another repository']
) {
  my ( $config, $reason, $label ) = @$case;
  my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => $config);
  like dies { $dispatcher->request('vm', {operation => 'claim'}) }, $reason,
    'claim fails on '.$label;
  my $record = record_of('state', 1);
  is $record->{state}, 'queued', 'the run stays queued';
  is [grep { exists $record->{$_} } qw( worker token expires )], [], 'no lease was written';
  ok !$root->child('state/claims/1.json')->exists, 'no secret snapshot was written';
  is $json->decode($root->child('state/public/runs/1.json')->slurp_utf8)->{state}, 'queued',
    'the public report still says queued';
}

my $rotated = $root->child('rotated-token');
$rotated->spew_utf8("before\n");
my $good = SimpiCI::Dispatcher->new(queue => $queue, config => config_for(grant(file => "$rotated")));
$rotated->spew_utf8("after\n");
my $claim = $good->request('vm', {operation => 'claim'});
is $claim->{run}, 1, 'the same run is claimed once the configuration is usable';
is $claim->{secrets}, {publish => {CICD_PACKAGE_TOKEN => 'after'}},
  'the secret file is read at the claim, not when the dispatcher is built';
my $broken = SimpiCI::Dispatcher->new(queue => $queue, config => config_for(grant(file => "$missing")));
is $broken->request('vm', {operation => 'finish', run => 1, token => $claim->{token},
  result => {state => 'success', exit_code => 0}, log => "token=after\n"})->{state}, 'success',
  'a completion is accepted while the configuration is broken';
like $root->child('state/public/runs/1.log')->slurp_utf8, qr/token=\[REDACTED\]/,
  'and is still redacted from the claim snapshot';

#### simpici-dispatch as a process

sub dispatch {
  my ( $config, $request ) = @_;
  my $config_file = $root->child('dispatch.json');
  $config_file->spew_utf8($json->encode($config));
  my %file = map { $_ => $root->child('dispatch.'.$_) } qw( stdin stdout stderr );
  $file{stdin}->spew_utf8($json->encode($request));
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    open STDIN, '<', $file{stdin}->stringify or exit 97;
    open STDOUT, '>', $file{stdout}->stringify or exit 97;
    open STDERR, '>', $file{stderr}->stringify or exit 97;
    exec $^X, '-I'.path('lib')->absolute, path('bin/simpici-dispatch')->absolute->stringify,
      '--config', "$config_file", '--worker', 'test-vm' or exit 98;
  }
  waitpid($pid, 0);
  return ( $? >> 8, $file{stdout}->slurp_utf8, $file{stderr}->slurp_utf8 );
}

my $process_queue = queue_in('process');
my $process_root = $process_queue->store->root->stringify;
$process_queue->run(SimpiCI::Event->new(%tag_event, commit => 'b' x 40));
my ( $status, $stdout, $stderr ) = dispatch(
  { root => $process_root, config_for(grant(refs => ['refs/tags/v*']))->%* }, {operation => 'claim'});
isnt $status, 0, 'simpici-dispatch fails a claim on a broken configuration';
is $stderr, 'simpici-dispatch: configuration unusable'."\n",
  'and tells the worker no more than that';
like $process_queue->store->root->child('dispatch.log')->slurp_utf8,
  qr/ worker test-vm: configuration unusable: SimpiCI::Dispatcher repository owner\/repo \(repositories\[1\]\), secret CICD_PACKAGE_TOKEN \(secrets\[0\]\): invalid ref pattern \(refs\[0\]\)\n\z/,
  'its log says which repository, which secret and what is wrong';
is $stdout, '', 'and answers nothing';
is record_of('process', 1)->{state}, 'queued', 'and leaves the run queued';

( $status, $stdout ) = dispatch({ root => $process_root, config_for(grant())->%* }, {operation => 'claim'});
is $status, 0, 'simpici-dispatch serves the claim once the configuration is fixed';
my $served = $json->decode($stdout);
is $served->{secrets}, {publish => {CICD_PACKAGE_TOKEN => 'tag-secret'}}, 'with its secret';
( $status, $stdout ) = dispatch(
  { root => $process_root, config_for(grant(refs => ['refs/tags/v*']))->%* },
  { operation => 'finish', run => $served->{run}, token => $served->{token},
    result => {state => 'success', exit_code => 0}, log => 'done' });
is $status, 0, 'simpici-dispatch accepts a completion on a broken configuration';
is record_of('process', 1)->{state}, 'success', 'and records it';

#### simpicid

my $fixture = tempdir;
for my $command (['init', '-q', '-b', 'main'], ['config', 'user.name', 'Test'],
    ['config', 'user.email', 'test@example.invalid']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git fixture failed';
}
$fixture->child('tracked')->spew_utf8('fixture');
for my $command (['add', '.'], ['commit', '-qm', 'fixture']) {
  system('git', '-C', "$fixture", @$command) == 0 or croak 'git commit failed';
}

sub daemon_config {
  my ( $state, $build_initial, %top ) = @_;
  my $file = $root->child($state.'.json');
  $file->spew_utf8($json->encode({
    root => $root->child($state)->stringify, %top,
    repositories => [{ name => 'owner/repo', clone_url => "$fixture", refs => ['refs/heads/main'],
      build_initial => $build_initial ? JSON->true : JSON->false,
      secrets => [grant(), grant(name => 'CICD_DEPLOY_TOKEN', file => "$missing", phases => ['deploy'])] }]
  }));
  return $file;
}

like dies { SimpiCI::App::Eventd->run('--config', daemon_config('daemon', 1, mode => 'dispatcher'), '--once') },
  qr/repository owner\/repo \(repositories\[0\]\), secret CICD_DEPLOY_TOKEN \(secrets\[1\]\): cannot read secret file/,
  'simpicid refuses to start in dispatcher mode on a broken grant';
ok !$root->child('daemon/state')->exists, 'and has not polled';
ok !$root->child('daemon/queue')->exists, 'and has not queued anything';

$missing->spew_utf8("deploy-secret\n");
is(SimpiCI::App::Eventd->run('--config', daemon_config('daemon', 1, mode => 'dispatcher'), '--once'), 0,
  'simpicid starts in dispatcher mode once the grant is usable');
is record_of('daemon', 1)->{state}, 'queued', 'and queues the polled tip';
$missing->remove;

is(SimpiCI::App::Eventd->run('--config', daemon_config('local', 0), '--once'), 0,
  'local mode does not evaluate grants');

done_testing;
