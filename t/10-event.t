#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use SimpiCI::Event;

my %args = (
  source     => 'git-poll',
  event      => 'push',
  repository => 'LEDaquaristik/sunriser',
  clone_url  => 'git@src.ci:ledaquaristik/sunriser.git',
  ref        => 'refs/heads/master',
  commit     => 'a' x 40
);

my $event = SimpiCI::Event->new(%args);
is $event->as_hash, { %args, payload => {} }, 'event has canonical shape';

is length($event->deduplication_key), 64, 'deduplication key is SHA-256';
is $event->deduplication_key,
  SimpiCI::Event->new(%args, source => 'webhook')->deduplication_key,
  'source does not split otherwise identical runs';

like dies { SimpiCI::Event->new(%args, ref => '../master') },
  qr/ref must start with refs\//,
  'rejects non-canonical refs';
like dies { SimpiCI::Event->new(%args, commit => 'abc123') },
  qr/full hexadecimal object id/,
  'rejects abbreviated commits';

# A repository name and an event name are free text, on one line: they go
# into the event file of every job, the deduplication key and the log lines
# of the operator. The source is one of three words.
for my $field (qw( repository event )) {
  for my $case (
    [ 'a tab', "one\ttwo" ], [ 'a line end', "one\ntwo" ], [ 'a trailing line end', "one\n" ],
    [ 'a carriage return', "one\rtwo" ], [ 'a NUL', "one\0two" ], [ 'an escape', "one\etwo" ],
    [ 'a DEL', "one\x7ftwo" ]
  ) {
    my ( $label, $value ) = @$case;
    my $died = dies { SimpiCI::Event->new(%args, $field => $value) };
    like $died, qr/\ASimpiCI::Event \Q$field\E must not contain control characters at /,
      'rejects '.$label.' in '.$field;
    unlike $died // '', qr/one|two/, 'without repeating it';
  }
  for my $value ( 'two words', "gr\x{fc}n/project", 'owner/pro"ject', '' ) {
    ok lives { SimpiCI::Event->new(%args, $field => $value) }, 'accepts "'.$value.'" as '.$field;
  }
}
if (ok(SimpiCI::Event->can('name_rejection'), 'the rule for both is one method')) {
  is(SimpiCI::Event->name_rejection("one\ttwo"), 'must not contain control characters',
    'which returns its reason');
  is(SimpiCI::Event->name_rejection('LEDaquaristik/sunriser'), undef, 'or nothing');
}
like dies { SimpiCI::Event->new(%args, source => "manual\n") }, qr/type constraint/,
  'a source is one of the three it may be, and so never has one';

# The forms of a clone URL, one of each. The rule itself, case by case, is in
# t/45-config-clone-url.t.
for my $clone_url (
  'https://src.ci/ledaquaristik/sunriser.git',
  'http://forge.internal:3000/ledaquaristik/sunriser.git',
  'ssh://git@src.ci:2222/ledaquaristik/sunriser.git',
  'file:///srv/git/sunriser.git',
  'git@src.ci:ledaquaristik/sunriser.git',
  'src.ci:ledaquaristik/sunriser.git',
  '/srv/git/sunriser.git'
) {
  ok lives { SimpiCI::Event->new(%args, clone_url => $clone_url) }, 'accepts '.$clone_url;
}
like dies { SimpiCI::Event->new(%args, clone_url => '--upload-pack=/srv/git/program') },
  qr/\ASimpiCI::Event clone URL must not begin with "-" at /,
  'rejects a clone URL git would read as an option';
for my $clone_url (
  'ext::/srv/git/program',
  'persistent-https://token@src.ci/ledaquaristik/sunriser.git',
  'git://src.ci/ledaquaristik/sunriser.git',
  'HTTPS://src.ci/ledaquaristik/sunriser.git',
  'ledaquaristik/sunriser.git'
) {
  my $died = dies { SimpiCI::Event->new(%args, clone_url => $clone_url) };
  like $died, qr/\ASimpiCI::Event clone URL must be a URL of the scheme https, http, ssh or file, an SSH address of the form \[user\@\]host:path or an absolute path at /,
    'rejects the form of '.$clone_url;
  unlike $died, qr/src\.ci|sunriser|program/, 'without repeating it';
}

# The two rules a grant of the dispatcher is held against: a grant for a
# source or a ref that no event can have applies to no run.
is [ SimpiCI::Event->sources ], [qw( git-poll webhook manual )], 'an event has one of three sources';
ok lives { SimpiCI::Event->new(%args, source => $_) }, 'the source '.$_.' is accepted'
  for SimpiCI::Event->sources;
like dies { SimpiCI::Event->new(%args, source => 'cron') }, qr/source/, 'another source is refused';
is(scalar(SimpiCI::Event->ref_rejection($_)), undef, 'the ref '.$_.' is one an event can carry')
  for 'refs/heads/main', 'refs/tags/1.0', 'refs/heads/feature/x';
is(scalar(SimpiCI::Event->ref_rejection($_)), 'ref must start with refs/', $_.' does not start with refs/')
  for 'main', 'heads/main', '../master', '';
is(scalar(SimpiCI::Event->ref_rejection($_)), 'ref is not canonical', 'refs/... with something a ref name cannot hold is not canonical')
  for 'refs/heads/ma in', 'refs/heads/*', 'refs/heads/a..b', 'refs/heads/main.lock', 'refs/heads/', "refs/heads/a\tb";
like dies { SimpiCI::Event->new(%args, ref => 'refs/heads/ma in') }, qr/\ASimpiCI::Event ref is not canonical at /,
  'the constructor refuses with the same words';

done_testing;
