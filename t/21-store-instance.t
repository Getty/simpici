use strict;
use warnings;
use Test2::V0;
use Path::Tiny qw( tempdir );
use POSIX ();
use SimpiCI::Store;

# The containers of a run are found again by a label, and the label is the
# instance of the store: what the store of another root must never share.

umask 0077;

subtest 'the instance of a store' => sub {
  my $root = tempdir;
  my $store = SimpiCI::Store->new(root => $root);
  my $instance = $store->instance;
  like $instance, qr/\A[0-9a-f]{32}\z/, 'is 32 hexadecimal digits';
  is $store->instance, $instance, 'stays what it is';
  is(SimpiCI::Store->new(root => $root)->instance, $instance,
    'also for another process on the same root');
  is $root->child('instance')->slurp_utf8, $instance."\n", 'it is kept as <root>/instance';
  is $root->child('instance')->stat->mode & 0777, 0600, 'for the account of the store alone';
  is [ grep { $_->basename =~ /\.tmp\./ } $root->children ], [], 'without a temporary file left';
  isnt(SimpiCI::Store->new(root => tempdir)->instance, $instance,
    'the store of another root has another one');
};

subtest 'a root that does not exist yet' => sub {
  my $root = tempdir->child('state', 'worker');
  like(SimpiCI::Store->new(root => $root)->instance, qr/\A[0-9a-f]{32}\z/, 'gets one as well');
};

subtest 'an instance file that is not one' => sub {
  for my $content ('', "\n", "not-an-instance\n", ('a' x 31)."\n", ('A' x 32)."\n",
      ('a' x 32)."\n".('b' x 32)."\n", ('a' x 32).' x') {
    my $root = tempdir;
    $root->child('instance')->spew_utf8($content);
    like dies { SimpiCI::Store->new(root => $root)->instance },
      qr/\ASimpiCI::Store invalid instance in \Q$root\E/,
      'is refused, not replaced and not used: '.( $content =~ s/\n/\\n/gr );
    is $root->child('instance')->slurp_utf8, $content, 'and left as it is';
  }
};

subtest 'processes that ask for it at the same time' => sub {
  my $root = tempdir;
  my $answers = tempdir;
  my @children;
  for my $number (1 .. 8) {
    my $pid = fork;
    die 'fork failed' unless defined $pid;
    unless ($pid) {
      my $instance = eval { SimpiCI::Store->new(root => $root)->instance } // 'failed: '.$@;
      $answers->child($number)->spew_utf8($instance);
      POSIX::_exit(0);
    }
    push @children, $pid;
  }
  waitpid($_, 0) for @children;
  my %seen = map { $_->slurp_utf8 => 1 } $answers->children;
  is [ keys %seen ], [ SimpiCI::Store->new(root => $root)->instance ], 'all get the same one';
};

done_testing;
