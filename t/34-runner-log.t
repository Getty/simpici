use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Errno qw( EACCES ENOENT );
use Path::Tiny qw( path tempdir );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;

# The log of a run is published, by a local daemon as it stands. What the
# runner itself adds to the output of git and of the executor names neither
# the state root nor a file of the installation.

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
my $event = SimpiCI::Event->new(source => 'manual', event => 'push', repository => 'fixture',
  clone_url => "$fixture", ref => 'refs/heads/main', commit => $commit);

my $tools = tempdir;
my $executor = $tools->child('executor');
$executor->spew_utf8("#!/usr/bin/env bash\nprintf 'the job ran\\n'\n");
$executor->chmod(0755);
# docker knows no container: an executor that did not end with 0 has the
# runner look for those of its run, and no test asks the docker of the host.
$tools->child('bin')->mkpath;
my $docker = $tools->child('bin/docker');
$docker->spew_utf8("#!/usr/bin/env bash\nexit 0\n");
$docker->chmod(0755);
local $ENV{PATH} = $tools->child('bin').':'.$ENV{PATH};

my $loaded = $INC{'SimpiCI/Runner.pm'};
my $installation = path($loaded)->absolute->parent(2);
my $module_directory = path($loaded)->parent;

sub message { local $! = $_[0]; return "$!" }

# One run, with what it and its commands wrote to standard error, which a
# command that cannot be started is not a part of any more.
sub run_with {
  my ( $script ) = @_;
  my $keep = tempdir;
  my $root = $keep->child('state-of-the-runner');
  my $captured = $keep->child('standard-error');
  open my $saved, '>&', \*STDERR or croak 'cannot keep standard error';
  open STDERR, '>', "$captured" or croak 'cannot capture standard error';
  my $report = eval {
    SimpiCI::Runner->new(store => SimpiCI::Store->new(root => $root), timeout => 30,
      runner_script => $script)->run($event);
  };
  my $error = $@;
  open STDERR, '>&', $saved or croak 'cannot restore standard error';
  croak $error unless $report;
  return {
    keep => $keep, root => $root, report => $report, said => $captured->slurp_utf8,
    log => $root->child('public/runs/1.log')->slurp_utf8,
    private => qr/\Q$root\E|\Q$tools\E|\Q$installation\E|\Q$module_directory\E|\.pm\b|\bline \d+/
  };
}

subtest 'a run that succeeds' => sub {
  my $run = run_with($executor);
  is $run->{report}->{state}, 'success', 'is reported as one';
  like $run->{log}, qr/^the job ran$/m, 'its log has what the executor printed';
  unlike $run->{log}, $run->{private}, 'and names neither the state root nor the installation';
  ok $run->{root}->child('work/1/.git')->is_dir, 'the checkout was made all the same';
};

subtest 'an executor that is not there' => sub {
  my $missing = $tools->child('no-such-executor');
  my $run = run_with($missing);
  is [ $run->{report}->@{qw( state exit_code )} ], [ 'failed', 126 ], 'is a failed run';
  like $run->{log}, qr/^SimpiCI::Runner cannot start the executor: \Q@{[ message(ENOENT) ]}\E\n\z/m,
    'the log says so in a line of the runner';
  unlike $run->{log}, $run->{private},
    'without the path of the executor, a file of the installation or a line';
  is $run->{said}, 'SimpiCI::Runner cannot start '.$missing.': '.message(ENOENT)."\n",
    'standard error names the executor';
};

subtest 'an executor that may not be executed' => sub {
  my $forbidden = $tools->child('forbidden-executor');
  $forbidden->spew_utf8("#!/usr/bin/env bash\n");
  $forbidden->chmod(0600);
  my $run = run_with($forbidden);
  is [ $run->{report}->@{qw( state exit_code )} ], [ 'failed', 126 ], 'is a failed run';
  like $run->{log}, qr/^SimpiCI::Runner cannot start the executor: \Q@{[ message(EACCES) ]}\E\n\z/m,
    'the log says why';
  unlike $run->{log}, $run->{private}, 'and nothing of where';
  is $run->{said}, 'SimpiCI::Runner cannot start '.$forbidden.': '.message(EACCES)."\n",
    'standard error names the executor';
};

subtest 'a git that is not there' => sub {
  my $nowhere = tempdir;
  local $ENV{PATH} = "$nowhere";
  my $run = run_with($executor);
  is [ $run->{report}->@{qw( state exit_code )} ], [ 'failed', 126 ], 'is a failed run';
  is $run->{log}, 'SimpiCI::Runner cannot start git: '.message(ENOENT)."\n",
    'the log is one line of the runner';
  is $run->{said}, 'SimpiCI::Runner cannot start git: '.message(ENOENT)."\n",
    'standard error says the same: there is no path to name';
  unlike $run->{log}, qr/the job ran/, 'and the executor is not started';
};

done_testing;
