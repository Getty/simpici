use strict;
use warnings;
use Test2::V0;
use JSON::MaybeXS;
use Path::Tiny qw( path tempdir );
use SimpiCI::Store;
use SimpiCI::Queue;
use SimpiCI::Dispatcher;

my $dir = path('deploy/dispatcher');
my $config = JSON::MaybeXS->new->decode($dir->child('dispatcher.example.json')->slurp_utf8);
is $config->{mode}, 'dispatcher', 'example runs in dispatcher mode';
is $config->{root}, '/var/lib/simpici', 'state path matches the compose volume';

my $root = tempdir;
my $token = $root->child('package-token');
$token->spew_utf8("example-token\n");
for my $repo ($config->{repositories}->@*) {
  like $repo->{clone_url}, qr{\Ahttps://src\.ci/}, "$repo->{name} is polled from the forge";
  is $repo->{refs}, ['refs/heads/main', 'refs/tags/*'], "$repo->{name} polls main and tags";
  $_->{file} = "$token" for $repo->{secrets}->@*;
}
my $dispatcher = SimpiCI::Dispatcher->new(config => $config,
  queue => SimpiCI::Queue->new(store => SimpiCI::Store->new(root => $root->child('state'))));
my $repo = $config->{repositories}[0];
my %event = (repository => $repo->{name}, clone_url => $repo->{clone_url},
  source => 'git-poll', event => 'push');
is $dispatcher->_secrets({%event, ref => 'refs/tags/0.504'}),
  {publish => {CICD_PACKAGE_TOKEN => 'example-token'}}, 'a tag gets the package token in publish';
is $dispatcher->_secrets({%event, ref => 'refs/heads/main'}), {},
  'a push to main gets nothing';

my $sshd = $dir->child('sshd_config')->slurp_utf8;
like $sshd, qr/^$_$/m, "sshd_config: $_" for
  'PasswordAuthentication no', 'PermitRootLogin no', 'AllowUsers simpici',
  'PermitTTY no', 'AllowTcpForwarding no', 'AllowStreamLocalForwarding no';
like $dir->child('authorized_keys.example')->slurp_utf8,
  qr{\Arestrict,command="/usr/local/bin/simpici-dispatch --config /etc/simpici/dispatcher\.json --worker [a-z0-9]+" ssh-ed25519 },
  'key example carries restrict and the forced command';

done_testing;
