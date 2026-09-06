#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Runner;
use SimpiCI::Queue;
use SimpiCI::Source::GitPoll;
use SimpiCI::Store;
use File::Temp qw( tempdir );
use Path::Tiny qw( path );

my $fixture = path(tempdir(CLEANUP => 1));
system('git', 'init', '-q', '-b', 'main', $fixture->stringify) == 0
  or die 'git init failed';
$fixture->child('.cicd')->mkpath;
$fixture->child('.cicd', 'linux+test.sh')->spew_utf8(
  "#!/usr/bin/env bash\nexit 0\n"
);
chmod 0755, $fixture->child('.cicd', 'linux+test.sh');
system('git', '-C', $fixture->stringify, 'add', '.cicd') == 0
  or die 'git add failed';
{
  local $ENV{GIT_AUTHOR_NAME} = 'SimpiCI Test';
  local $ENV{GIT_AUTHOR_EMAIL} = 'test@example.invalid';
  local $ENV{GIT_COMMITTER_NAME} = 'SimpiCI Test';
  local $ENV{GIT_COMMITTER_EMAIL} = 'test@example.invalid';
  system('git', '-C', $fixture->stringify, 'commit', '-q', '-m', 'fixture') == 0
    or die 'git commit failed';
}

my $root = path(tempdir(CLEANUP => 1));
my $store = SimpiCI::Store->new(root => $root);
my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8(<<'RUNNER');
#!/usr/bin/env bash
set -euo pipefail
exec "$GITHUB_WORKSPACE/.cicd/linux+test.sh" "$CICD_EVENT_FILE"
RUNNER
chmod 0755, $runner_script;
my $poller = SimpiCI::Source::GitPoll->new(
  store  => $store,
  runner => SimpiCI::Runner->new(
    store         => $store,
    timeout       => 30,
    runner_script => $runner_script
  ),
  repository => {
    name          => 'fixture',
    clone_url     => $fixture->stringify,
    refs          => ['refs/heads/main'],
    build_initial => 1
  }
);

is scalar($poller->poll->@*), 1, 'initial policy can build current tip';
is scalar($poller->poll->@*), 0, 'unchanged ref creates no duplicate run';

my $queue_store = SimpiCI::Store->new(root => path(tempdir(CLEANUP => 1)));
my $queue = SimpiCI::Queue->new(store => $queue_store);
my %repository = (name => 'owner/fixture', clone_url => "$fixture",
  refs => ['refs/heads/main', 'refs/tags/*'], build_initial => 0);
my $queued_poller = SimpiCI::Source::GitPoll->new(
  store => $queue_store, runner => $queue, repository => { %repository });
is $queued_poller->poll, [], 'initial observation does not enqueue history';
system('git', '-C', "$fixture", 'tag', 'new-tag') == 0 or die 'tag failed';
is scalar($queued_poller->poll->@*), 1, 'new tag builds after initial observation';
my $mirror_poller = SimpiCI::Source::GitPoll->new(
  store => $queue_store, runner => $queue, repository => {
    %repository, clone_url => "$fixture/.", build_initial => 1
  });
my $mirror_reports = $mirror_poller->poll;
is scalar(@$mirror_reports), 2, 'mirror has independent observations';
is [sort map { $_->{run} } @$mirror_reports], [1, 2],
  'same tag through second clone URL reuses existing run';
is $mirror_poller->poll, [], 'mirror polling stays idle when unchanged';

done_testing;
