package SimpiCI;
our $VERSION = '0.001';

use strict;
use warnings;

# ABSTRACT: Small Git-aware continuous integration daemon

1;

=head1 NAME

SimpiCI - small Git-aware continuous integration runner

=head1 DESCRIPTION

SimpiCI normalizes repository events, checks out exact revisions, and executes
repository-owned jobs in filename-selected containers. See L<SimpiCI::Event>,
L<SimpiCI::Store>, L<SimpiCI::Runner>, L<SimpiCI::Source::GitPoll> and, for
the configuration file of the daemon, L<SimpiCI::Config>.

=cut
