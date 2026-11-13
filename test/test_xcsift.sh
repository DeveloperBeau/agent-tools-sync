#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"

check "xcsift: rewrite, hook output and idempotent install" "$(command -v python3.14 || command -v python3)" "$HERE/test_xcsift.py"

report
