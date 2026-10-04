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

# What the operations guide starts in the poller service has to be on the
# PATH of the image, and has to run as the account the state belongs to:
# simpici refuses to rewrite the state of another one.
my $containerfile = $dir->child('Containerfile')->slurp_utf8;
my ( $wrapped ) = $containerfile =~ /^RUN for program in ([^;]+); do \\$/m;
is [ sort split ' ', $wrapped // '' ], [qw( simpici simpici-dispatch simpicid )],
  'the image puts the poller, the worker endpoint and the operator command on its PATH';
like $containerfile,
  qr{exec /usr/local/bin/perl -I/opt/simpici/lib /opt/simpici/bin/%s "\$@"\\n' "\$program" \\\n\s+> "/usr/local/bin/\$program"},
  'each as a wrapper around the program of that name';
ok path('bin', $_)->is_file, 'bin/'.$_.' is there to be wrapped' for split ' ', $wrapped // '';
my ( $uid, $gid ) = $containerfile =~ /useradd --uid ([0-9]+) --gid ([0-9]+) /;
my ( $poller ) = $dir->child('compose.yaml')->slurp_utf8 =~ /^  poller:\n((?:    .*\n|\n)+)/m;
like $poller // '', qr/^    user: "\Q$uid:$gid\E"$/m,
  'the poller service, and with it a command started in it, runs as the account of the image';

done_testing;
