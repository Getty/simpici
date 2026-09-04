#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use App::SimpiCI::Runner;
use App::SimpiCI::Source::GitPoll;
use App::SimpiCI::Store;
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
my $store = App::SimpiCI::Store->new(root => $root);
my $runner_script = $root->child('runner.sh');
$runner_script->spew_utf8(<<'RUNNER');
#!/usr/bin/env bash
set -euo pipefail
exec "$GITHUB_WORKSPACE/.cicd/linux+test.sh" "$CICD_EVENT_FILE"
RUNNER
chmod 0755, $runner_script;
my $poller = App::SimpiCI::Source::GitPoll->new(
  store  => $store,
  runner => App::SimpiCI::Runner->new(
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

done_testing;
