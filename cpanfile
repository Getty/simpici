requires 'Digest::SHA';
requires 'File::Which';
requires 'JSON::MaybeXS';
requires 'Moo';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'Types::Standard';

on test => sub {
  requires 'Test2::V0';
};
