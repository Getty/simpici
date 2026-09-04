#!/usr/bin/env bash
set -euo pipefail

if ! perl -MJSON::MaybeXS -MTest2::V0 -MTypes::Standard -e 1 2>/dev/null; then
  if command -v cpanm >/dev/null 2>&1; then
    cpanm --installdeps --notest .
  else
    curl -fsSL https://cpanmin.us | perl - --installdeps --notest .
  fi
fi

t/action-runner.sh
prove -lr t/
