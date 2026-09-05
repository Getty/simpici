package SimpiCI;

use strict;
use warnings;

# ABSTRACT: Small Git-aware continuous integration daemon

1;

=head1 NAME

SimpiCI - small Git-aware continuous integration runner

=head1 DESCRIPTION

SimpiCI normalizes repository events, checks out exact revisions, and executes
repository-owned jobs in filename-selected containers. See L<SimpiCI::Event>,
L<SimpiCI::Store>, L<SimpiCI::Runner>, and L<SimpiCI::Source::GitPoll>.

=cut
