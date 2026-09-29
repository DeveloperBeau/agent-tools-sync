#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git init -q --bare -b main "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/source"
git -C "$tmp/source" config user.name ATS
git -C "$tmp/source" config user.email ats@example.invalid
printf 'old\n' >"$tmp/source/version"
git -C "$tmp/source" add version
git -C "$tmp/source" commit -qm initial
git -C "$tmp/source" push -q origin main
git clone -q "$tmp/remote.git" "$tmp/work"

printf 'new\n' >"$tmp/source/version"
git -C "$tmp/source" commit -qam update
git -C "$tmp/source" push -q origin main

updated() { ats_check_update "$tmp/work"; [ "$?" -eq 2 ]; }
check "fast-forward update detected" updated
check "new content present" test "$(cat "$tmp/work/version")" = new
check "current checkout reports ready" ats_check_update "$tmp/work"
version_shown() { [[ "$(ats_check_update "$tmp/work")" == *"ats v1.4.0"* ]]; }
check "current version shown during update check" version_shown

printf 'local\n' >"$tmp/work/local"
printf 'newer\n' >"$tmp/source/version"
git -C "$tmp/source" commit -qam newer
git -C "$tmp/source" push -q origin main
check "dirty checkout stays unchanged" ats_check_update "$tmp/work"
check "local file retained" test -f "$tmp/work/local"
check "dirty checkout not fast-forwarded" test "$(cat "$tmp/work/version")" = new

report
