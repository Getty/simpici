#!/usr/bin/env bash
set -euo pipefail

if [[ -d "$HOME/perl5/lib/perl5" ]]; then
  export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
  export PATH="$HOME/perl5/bin:$PATH"
fi

if ! perl -MJSON::MaybeXS -MTest2::V0 -MTypes::Standard -e 1 2>/dev/null; then
  if command -v cpanm >/dev/null 2>&1; then
    cpanm --installdeps --notest .
  else
    curl -fsSL https://cpanmin.us | perl - --installdeps --notest .
  fi
  export PERL5LIB="$HOME/perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
  export PATH="$HOME/perl5/bin:$PATH"
fi

t/action-runner.sh
prove -lr t/
