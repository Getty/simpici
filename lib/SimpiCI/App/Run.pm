package SimpiCI::App::Run;

use strict;
use warnings;

# ABSTRACT: Implementation of the simpici one-shot command

use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Pod::Usage qw( pod2usage );
use SimpiCI::Event;
use SimpiCI::Runner;
use SimpiCI::Store;

sub run {
  my ( $class, @arguments ) = @_;

  my ($root, $event_path, $timeout, $runner_script, $help, $man);
  GetOptionsFromArray(
    \@arguments,
    'root=s'    => \$root,
    'event=s'   => \$event_path,
    'timeout=i' => \$timeout,
    'runner=s'  => \$runner_script,
    'help|h'    => \$help,
    'man'       => \$man
  ) or pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1);
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 1) if $help;
  pod2usage(-input => __FILE__, -exitval => 0, -verbose => 2) if $man;
  pod2usage(-input => __FILE__, -exitval => 64, -verbose => 1,
    -message => 'An event JSON file is required.') unless $event_path;

  $root //= './var';
  $timeout //= 3600;
  my $data = JSON::MaybeXS->new->decode(path($event_path)->slurp_utf8);
  my $event = SimpiCI::Event->new($data->%*);
  my $report = SimpiCI::Runner->new(
    store   => SimpiCI::Store->new(root => path($root)),
    timeout => $timeout,
    $runner_script ? (runner_script => path($runner_script)) : ()
  )->run($event);
  print JSON::MaybeXS->new(canonical => 1)->encode($report)."\n";
  return $report->{state} eq 'success' || $report->{state} eq 'skipped' ? 0 : 1;
}

1;

=head1 NAME

SimpiCI::App::Run - implementation of the simpici one-shot command

=head1 SYNOPSIS

  simpici --event event.json [--root var] [--timeout 3600]
  simpici --event event.json --runner /opt/simpici/action/run.sh
  simpici --help

=head1 DESCRIPTION

Validates one normalized event, allocates a run, checks out the exact commit
detached, and invokes the shared phased container executor. This trusted
one-shot entry point does not read daemon configuration or use queue
deduplication; each invocation allocates a new run.

=head1 METHODS

=head2 run

  my $status = SimpiCI::App::Run->run(@arguments);

Runs the command with an explicit argument list and returns its process exit
status. Help and usage errors are handled by L<Pod::Usage>.

=head1 OPTIONS

=over 4

=item B<--event> I<file>

Required event JSON containing C<source>, C<event>, C<repository>, C<clone_url>,
C<ref>, and a full 40- or 64-character lowercase hexadecimal C<commit>.

=item B<--root> I<directory>

Private state, checkout, log, and report root. Defaults to C<./var>.

=item B<--timeout> I<seconds>

Maximum executor runtime. Defaults to 3600 seconds.

=item B<--runner> I<file>

Executor path. Defaults to C<bin/simpici-executor> in a source checkout or the
installed C<simpici-executor> found on C<PATH>. Use an absolute override path:
the runner changes into the checkout before execution.

=item B<--help>, B<-h>

Print concise help.

=item B<--man>

Print the complete manual.

=back

=cut
