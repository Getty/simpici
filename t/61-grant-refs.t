use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( tempdir );
use SimpiCI::Store;
use SimpiCI::Queue;
use SimpiCI::Dispatcher;

umask 0077;
my $root = tempdir;
my $queue = SimpiCI::Queue->new(store => SimpiCI::Store->new(root => $root));
my $secret_file = $root->child('package-token');
$secret_file->spew_utf8("tag-secret\n");

sub secrets_for {
  my ( $refs, $ref, %event ) = @_;
  my $dispatcher = SimpiCI::Dispatcher->new(queue => $queue, config => {
    repositories => [{name => 'owner/repo', clone_url => '/fixture', secrets => [{
      name => 'CICD_PACKAGE_TOKEN', file => "$secret_file",
      refs => $refs, events => ['push', 'pull_request'], phases => ['publish']
    }]}]
  });
  return $dispatcher->_secrets({
    repository => 'owner/repo', clone_url => '/fixture', source => 'git-poll',
    event => 'push', ref => $ref, %event
  });
}

my $granted = {publish => {CICD_PACKAGE_TOKEN => 'tag-secret'}};

is secrets_for(['refs/tags/*'], 'refs/tags/0.504'), $granted,
  'trailing /* grants any tag';
is secrets_for(['refs/tags/*'], 'refs/tags/release/1.0'), $granted,
  'the rest may contain further slashes';
is secrets_for(['refs/heads/main', 'refs/tags/*'], 'refs/heads/main'), $granted,
  'exact entries still work next to a pattern';
is secrets_for(['refs/tags/*'], 'refs/heads/main'), {},
  'pattern does not reach another namespace';
is secrets_for(['refs/tags/*'], 'refs/tagsx/1'), {},
  'pattern prefix ends at the slash';
is secrets_for(['refs/tags/1'], 'refs/tags/10'), {},
  'an exact entry is never a prefix';
is secrets_for(['refs/heads/main'], 'refs/heads/main2'), {},
  'exact comparison unchanged';
is secrets_for(['refs/tags/*'], 'refs/tags/0.504', event => 'pull_request'), {},
  'pull requests receive nothing even when the pattern matches';

for my $bad ('*', 'refs/*', 'refs/tags/v*', 'refs/*/main', 'refs/tags/**', 'tags/*') {
  like dies { secrets_for([$bad], 'refs/tags/0.504') }, qr/invalid ref pattern/,
    "reject pattern $bad";
}
like dies { secrets_for(['refs/tags/*', 'refs/*'], 'refs/tags/0.504') },
  qr/invalid ref pattern/, 'an invalid pattern aborts even after a match';

done_testing;
