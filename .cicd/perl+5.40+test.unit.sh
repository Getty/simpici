#!/usr/bin/env bash
set -euo pipefail
cpanm --installdeps --notest .
t/action-runner.sh
prove -lr t/
