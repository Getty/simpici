use strict;
use warnings;
use Test2::V0;
use Carp qw( croak );
use Fcntl qw( LOCK_EX LOCK_UN );
use IO::Handle;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use POSIX qw( WNOHANG );
use SimpiCI::Event;
use SimpiCI::Queue;
use SimpiCI::Store;
use Time::HiRes qw( sleep time );

# simpici-dispatch limits how long it reads a request, not how long it takes
# to serve one: a sender that hangs is given up, and a request that was read
# is served to its end, however long the queue or the redaction take.

umask 0077;
my $root = tempdir;
my $json = JSON::MaybeXS->new(canonical => 1);
my $store = SimpiCI::Store->new(root => $root->child('state'));
my $queue = SimpiCI::Queue->new(store => $store);
$queue->run(SimpiCI::Event->new(source => 'git-poll', event => 'push', repository => 'fixture',
  clone_url => '/fixture', ref => 'refs/heads/main', commit => 'a' x 40));
my $program = path('bin/simpici-dispatch')->absolute;
my $lib = path('lib')->absolute;
my %running;

END {
  local $?;
  for my $pid (keys %running) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
  }
}

sub configure {
  my ( %top ) = @_;
  my $config = $root->child('config.json');
  $config->spew_utf8($json->encode({ root => $store->root->stringify, repositories => [], %top }));
  return $config;
}

# simpici-dispatch as a process: its standard input is a pipe the test keeps,
# its two outputs are files.
my $spawned = 0;
sub spawn {
  my ( $config ) = @_;
  my $output = $root->child('process.'.++$spawned);
  pipe(my $reader, my $writer) or croak 'pipe failed: '.$!;
  my $pid = fork;
  croak 'fork failed' unless defined $pid;
  unless ($pid) {
    close $writer;
    open STDIN, '<&', $reader or POSIX::_exit(97);
    open STDOUT, '>', $output.'.out' or POSIX::_exit(97);
    open STDERR, '>', $output.'.err' or POSIX::_exit(97);
    exec $^X, '-I'.$lib, "$program", '--config', "$config", '--worker', 'test-vm'
      or POSIX::_exit(98);
  }
  close $reader;
  $writer->autoflush(1);
  $running{$pid} = 1;
  return { pid => $pid, input => $writer, started => time,
    out => path($output.'.out'), err => path($output.'.err') };
}

# Whether the process has ended, and then with what.
sub ended {
  my ( $process ) = @_;
  return $process->{status} if exists $process->{status};
  return unless waitpid($process->{pid}, WNOHANG) == $process->{pid};
  delete $running{ $process->{pid} };
  $process->{took} = time - $process->{started};
  return $process->{status} = $?;
}

sub wait_for_end {
  my ( $process, $seconds ) = @_;
  my $deadline = time + $seconds;
  until (defined ended($process)) {
    return if time > $deadline;
    sleep 0.05;
  }
  return $process->{status};
}

sub record { $json->decode($store->root->child('queue/'.$_[0].'.json')->slurp_utf8) }

my $claim = $json->encode({ operation => 'claim' });

#### A sender that does not finish

for my $case (
  [ 'a sender that sends nothing', sub { } ],
  [ 'a sender that stops in the middle of a request', sub { print { $_[0] } substr($claim, 0, 9) } ],
  [ 'a sender that keeps sending a little', sub {
      my ( $input, $process ) = @_;
      local $SIG{PIPE} = 'IGNORE';
      until (defined ended($process) || time > $process->{started} + 8) {
        print {$input} ' ';
        sleep 0.2;
      }
    } ]
) {
  my ( $name, $send ) = @$case;
  my $process = spawn(configure(request_read_timeout => 1));
  $send->($process->{input}, $process);
  my $status = wait_for_end($process, 10);
  ok defined $status, $name.' is given up' or next;
  ok $status != 0, $name.': the program fails';
  ok $process->{took} >= 0.9 && $process->{took} < 5, $name.': after the limit, not at once and not much later'
    or diag $process->{took};
  like $process->{err}->slurp_utf8, qr/\Asimpici-dispatch request not read within 1 s at \S+ line \d+\.\n\z/,
    $name.': it says so in one line on standard error';
  is $process->{out}->slurp_utf8, '', $name.': and answers nothing';
  is record(1)->{state}, 'queued', $name.': no lease is taken';
  close $process->{input};
}

#### A request that was read

# The queue is locked by somebody else for longer than the limit: the request
# is read at once and then has to wait.
{
  open my $lock, '>>', $store->root->child('queue.lock')->stringify or croak 'cannot open the queue lock';
  flock $lock, LOCK_EX or croak 'cannot lock the queue';
  my $process = spawn(configure(request_read_timeout => 1));
  print { $process->{input} } $claim;
  close $process->{input};
  sleep 2.5;
  is ended($process), undef, 'a request that was read waits for the queue beyond the limit';
  flock $lock, LOCK_UN;
  my $status = wait_for_end($process, 20);
  is $status, 0, 'and is served once the queue is free';
  is $process->{err}->slurp_utf8, '', 'without a word on standard error';
  my $answer = eval { $json->decode($process->{out}->slurp_utf8) } // {};
  is [ $answer->@{qw( run worker )} ], [ 1, 'test-vm' ], 'the answer is the claim';
  is record(1)->{state}, 'running', 'and the lease is taken';
  ok $process->{took} > 2, 'after longer than the limit' or diag $process->{took};
}

# A request that arrives in pieces, but within the limit.
{
  my $process = spawn(configure(request_read_timeout => 5));
  for my $piece ($claim =~ /(.{1,6})/gs) {
    print { $process->{input} } $piece;
    sleep 0.1;
  }
  close $process->{input};
  is wait_for_end($process, 20), 0, 'a request that arrives slowly, but in time, is served';
  is $process->{out}->slurp_utf8, '{}', 'with its answer: nothing is queued any more';
}

#### The setting

for my $case (
  [ 'zero', 0 ], [ 'a negative number', -1 ], [ 'a fraction', 1.5 ], [ 'a word', 'soon' ],
  [ 'an empty string', '' ], [ 'a list', [30] ], [ 'a number with a unit', '30s' ]
) {
  my ( $name, $value ) = @$case;
  my $process = spawn(configure(request_read_timeout => $value));
  my $status = wait_for_end($process, 10);
  ok defined $status && $status != 0, $name.' as request_read_timeout fails the program at once';
  like $process->{err}->slurp_utf8,
    qr/\Asimpici-dispatch request_read_timeout must be a positive integer at \S+ line \d+\.\n\z/,
    $name.': with the name of the setting';
  ok defined $process->{took} && $process->{took} < 5, $name.': before anything is read';
  close $process->{input};
}

{
  # Without the setting the limit is 30 seconds: long enough that a request
  # which is still on its way after two of them is not given up.
  my $process = spawn(configure());
  print { $process->{input} } substr($claim, 0, 9);
  sleep 2;
  is ended($process), undef, 'without the setting a sender is not given up after two seconds';
  print { $process->{input} } substr($claim, 9);
  close $process->{input};
  is wait_for_end($process, 20), 0, 'and its request is served when it is complete';
  like path('bin/simpici-dispatch')->slurp_utf8, qr/\{request_read_timeout\} \/\/ 30;/,
    'the default is 30 seconds';
}

done_testing;
