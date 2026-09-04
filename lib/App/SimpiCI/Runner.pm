package App::SimpiCI::Runner;
use Moo;

use App::SimpiCI::Store;
use Carp qw( croak );
use POSIX qw( WNOHANG setpgid strftime );
use Time::HiRes qw( sleep time );
use Types::Standard qw( Int InstanceOf );
use namespace::autoclean;

has store => (
  is       => 'ro',
  isa      => InstanceOf['App::SimpiCI::Store'],
  required => 1,
);

has timeout => (
  is      => 'ro',
  isa     => Int,
  default => sub { 3600 },
);

sub run {
  my ( $self, $event ) = @_;

  my $run = $self->store->allocate_run;
  my $workspace = $self->store->root->child('work', $run);
  my $log = $self->store->root->child('public', 'runs', $run.'.log');
  my $started = time;
  my $report = {
    run        => $run,
    state      => 'running',
    started_at => $self->_timestamp($started),
    log        => '/runs/'.$run.'.log',
    $event->as_hash->%*
  };
  delete $report->{payload};
  delete $report->{clone_url};
  $self->_publish($report);

  $workspace->mkpath;
  my $result = $self->_execute($log, 120, 'git', 'init', $workspace->stringify);
  $result = $self->_execute($log, 120, 'git', '-C', $workspace->stringify,
    'remote', 'add', 'origin', $event->clone_url) if $result->{exit_code} == 0;
  $result = $self->_execute($log, 300, 'git', '-C', $workspace->stringify,
    'fetch', '--depth=1', 'origin', $event->commit) if $result->{exit_code} == 0;
  $result = $self->_execute($log, 120, 'git', '-C', $workspace->stringify,
    'checkout', '--detach', $event->commit) if $result->{exit_code} == 0;

  my $script = $workspace->child('.cicd',
    $event->platform.'+'.$event->feature.'+cicd.sh');
  if ($result->{exit_code} == 0 && !$script->is_file) {
    $result = { exit_code => 127, error => 'CI/CD script not found: '.$script };
    $log->append_utf8($result->{error}."\n");
  }
  if ($result->{exit_code} == 0 && $script->is_file) {
    my $event_file = $self->store->write_json('runs/'.$run.'/event.json',
      $event->as_hash);
    my %environment = (
      CICD_RUN_NUMBER => $run,
      CICD_SOURCE     => $event->source,
      CICD_EVENT      => $event->event,
      CICD_REPOSITORY => $event->repository,
      CICD_REF        => $event->ref,
      CICD_COMMIT     => $event->commit,
      CICD_PLATFORM   => $event->platform,
      CICD_FEATURE    => $event->feature,
      CICD_WORKSPACE  => $workspace->stringify,
      CICD_EVENT_FILE => $event_file->stringify,
      CICD_ROOT       => $workspace->child('.cicd')->stringify
    );
    $result = $self->_execute($log, $self->timeout, 
      { %ENV, %environment }, $workspace->stringify, $script->stringify,
      $event_file->stringify);
  }

  my $finished = time;
  $report->{state} = $result->{timed_out} ? 'timed_out'
    : $result->{signal} ? 'signalled'
    : $result->{exit_code} == 0 ? 'success'
    : $result->{exit_code} == 78 ? 'skipped' : 'failed';
  $report->{exit_code} = $result->{exit_code};
  $report->{signal} = $result->{signal} if $result->{signal};
  $report->{finished_at} = $self->_timestamp($finished);
  $report->{duration_seconds} = int($finished - $started);
  $self->_publish($report);
  return { $report->%* };
}

sub _publish {
  my ( $self, $report ) = @_;

  $self->store->write_json('public/runs/'.$report->{run}.'.json', $report);
  $self->store->write_json('public/runs/index.json', {
    latest => $report->{run},
    runs   => [ $report->{run} ]
  });
}

sub _execute {
  my ( $self, $log, $timeout, @command ) = @_;

  my $environment = ref $command[0] eq 'HASH' ? shift @command : undef;
  my $directory = defined $environment ? shift @command : undef;
  my $pid = fork;
  croak __PACKAGE__.'->_execute cannot fork: '.$! unless defined $pid;
  unless ($pid) {
    setpgid(0, 0);
    chdir $directory if defined $directory;
    %ENV = $environment->%* if defined $environment;
    open STDOUT, '>>', $log or POSIX::_exit(126);
    open STDERR, '>&', STDOUT or POSIX::_exit(126);
    exec { $command[0] } @command or POSIX::_exit(126);
  }
  my $deadline = time + $timeout;
  while (waitpid($pid, WNOHANG) == 0) {
    if (time >= $deadline) {
      kill 'TERM', -$pid;
      sleep 1;
      kill 'KILL', -$pid;
      waitpid($pid, 0);
      return { exit_code => 124, timed_out => 1 };
    }
    sleep 0.05;
  }
  return { exit_code => $? >> 8, signal => $? & 127 };
}

sub _timestamp {
  my ( $self, $epoch ) = @_;
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch));
}

1;
