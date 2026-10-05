#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"

check "xcsift: rewrite, hook output and idempotent install" python3 "$HERE/test_xcsift.py"

report
