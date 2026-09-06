package SimpiCI::Worker;

use Moo;

# ABSTRACT: Outbound-only worker with durable completion retry

use Carp qw( croak );
use IPC::Open3 qw( open3 );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;
use Types::Standard qw( Str InstanceOf );
use namespace::autoclean;

has host => (is => 'ro', isa => Str, required => 1);
has store => (is => 'ro', isa => InstanceOf['SimpiCI::Store'], required => 1);
has runner => (is => 'ro', isa => InstanceOf['SimpiCI::Runner'], required => 1);

sub _request {
  my ( $self, $request ) = @_;
  croak __PACKAGE__.' invalid SSH destination' unless $self->host =~ /\A[a-zA-Z0-9_][a-zA-Z0-9_.@-]*\z/;
  my $json = JSON::MaybeXS->new(canonical => 1, convert_blessed => 1);
  my $pid = open3(my $input, my $output, '>&STDERR',
    'ssh', '-T', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes',
    '-oConnectTimeout=15', '-oServerAliveInterval=15', '-oServerAliveCountMax=2',
    $self->host, 'simpici-dispatch');
  print {$input} $json->encode($request) or croak __PACKAGE__.' cannot send request';
  close $input;
  my $response = do { local $/; <$output> };
  waitpid($pid, 0);
  croak __PACKAGE__.' dispatcher connection failed' if $?;
  return $json->decode($response);
}

sub once {
  my ( $self ) = @_;
  $self->store->prepare;
  my $pending = $self->store->root->child('completion.json');
  if ($pending->is_file) {
    my $request = JSON::MaybeXS->new->decode($pending->slurp_utf8);
    my $response = $self->_request($request);
    $pending->remove;
    return $response;
  }
  my $claim = $self->_request({ operation => 'claim' });
  return unless $claim->{run};
  my $secrets_root = $self->store->root->absolute->child('secrets', $claim->{run});
  $secrets_root->mkpath;
  for my $phase (qw( publish deploy )) {
    my $values = $claim->{secrets}{$phase} // {};
    $secrets_root->child($phase.'.env')->spew_utf8(join '',
      map { $_.'='.$values->{$_}."\n" } sort keys %$values);
  }
  my $report;
  {
    my $temporary = $self->store->root->absolute->child('tmp');
    $temporary->mkpath;
    local $ENV{RUNNER_TEMP} = $temporary->stringify;
    local $ENV{SIMPICI_SECRETS_DIR} = $secrets_root->stringify;
    $report = SimpiCI::Runner->new(
      store => $self->store, runner_script => $self->runner->runner_script,
      timeout => $claim->{timeout}
    )->run(SimpiCI::Event->new($claim->{event}->%*), $claim->{run});
  }
  my $log_path = $self->store->root->child('public', 'runs', $report->{run}.'.log');
  my $log = $log_path->slurp_utf8;
  for my $values (values $claim->{secrets}->%*) {
    for my $value (values %$values) { $log =~ s/\Q$value\E/[REDACTED]/g; }
  }
  $log = substr($log, -4 * 1024 * 1024);
  my $request = {
    operation => 'finish', run => $claim->{run}, token => $claim->{token},
    result => { state => $report->{state}, exit_code => $report->{exit_code} },
    log => $log
  };
  $self->store->write_json('completion.json', $request);
  $secrets_root->remove_tree;
  my $response = $self->_request($request);
  $pending->remove;
  return $response;
}

1;

=head1 NAME

SimpiCI::Worker - outbound SSH runner

=head1 DESCRIPTION

C<once> first retries a persisted completion, otherwise claims and executes one
exact revision. The SSH private key is never mounted in job containers. The
worker's entire state tree is private and must not be served by a web server.

=cut
