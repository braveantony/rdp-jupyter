#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/install-extra.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
ROOT=$PWD
SCRIPT=$ROOT/images/rdp-jupyter/rootfs/opt/rdp-jupyter/install-extra.sh
FAKE=$ROOT/test/unit/fixtures/fake-pip.sh
unset PIP_INDEX_URL FAKE_PIP_FAIL FAKE_PIP_SLEEP INSTALL_TIMEOUT
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

new_env() {  # fresh sandbox per scenario
  D=$(mktemp -d "$T/case.XXXXXX")
  EXTRA=$D/extra CALLS=$D/calls REQ=$D/requirements.txt VER=$D/VERSION CONS=$D/constraints.txt LOG=$D/log
  echo 1.0 >"$VER"; : >"$CONS"; : >"$CALLS"
  printf 'requests==2.32.3\n' >"$REQ"
}
run() {  # run [VAR=value...]: run the script with the sandbox paths; sets rc
  env REQ_FILE="$REQ" EXTRA_DIR="$EXTRA" BASE_CONSTRAINTS="$CONS" IMAGE_VERSION_FILE="$VER" \
    PIP_CMD="$FAKE" CALLS="$CALLS" LOG_OUT="$LOG" "$@" bash "$SCRIPT" >"$D/out" 2>&1
  rc=$?
}
ncalls() { wc -l <"$CALLS" | tr -d ' '; }
cur() { basename "$(readlink "$EXTRA/current" 2>/dev/null)"; }
tmps() { find "$EXTRA" -maxdepth 1 -name '*.tmp' 2>/dev/null | wc -l | tr -d ' '; }

say no input
new_env; rm "$REQ"; run
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 0 ] && [ ! -e "$EXTRA/current" ] \
  && pass "no requirements file" || bad "no requirements file: rc=$rc calls=$(ncalls)"
new_env; printf '# x\r\n\r\n  \r\n' >"$REQ"; run
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 0 ] && [ ! -e "$EXTRA/current" ] \
  && pass "comments only" || bad "comments only: rc=$rc calls=$(ncalls)"

say install
new_env; run
c=$(cur)
[ "$rc" -eq 0 ] && [[ $c =~ ^[0-9a-f]{16}$ ]] && [ "$(cat "$EXTRA/.stamp")" = "$c" ] \
  && [ -e "$EXTRA/current/marker" ] && [ "$(tmps)" -eq 0 ] \
  && pass "first install" || bad "first install: rc=$rc cur=$c: $(cat "$D/out")"
grep -q -- "-c $CONS" "$CALLS" && pass "constraints passed" || bad "constraints passed: $(cat "$CALLS")"
grep -q "TMPDIR=$EXTRA/.tmpdir" "$CALLS" && pass "TMPDIR inside EXTRA_DIR" || bad "TMPDIR: $(cat "$CALLS")"
grep -q '^\[install-extra\]' "$LOG" && pass "log prefixed and written" || bad "log: $(cat "$LOG")"
first=$c
run
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 1 ] && pass "same input skips" || bad "same input skips: calls=$(ncalls)"
PIP_INDEX_URL=http://example.invalid/simple run PIP_INDEX_URL=http://example.invalid/simple
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq 2 ] && [ "$(cur)" != "$first" ] && [ ! -e "$EXTRA/$first" ] \
  && pass "index change reinstalls" || bad "index change: calls=$(ncalls) cur=$(cur)"
echo 2.0 >"$VER"; run PIP_INDEX_URL=http://example.invalid/simple
[ "$(ncalls)" -eq 3 ] && pass "image upgrade reinstalls" || bad "image upgrade: calls=$(ncalls)"
rm "$VER"; run
[ "$rc" -eq 0 ] && [ -e "$EXTRA/current/marker" ] && pass "missing version file ok" || bad "missing version: rc=$rc"

say failure
new_env; run; before=$(cur)
printf 'flask==3.0.0\n' >"$REQ"; run FAKE_PIP_FAIL=1
printf 'requests==2.32.3\n' >"$REQ"; n=$(ncalls); run
[ "$rc" -eq 0 ] && [ "$(ncalls)" -eq "$n" ] && [ ! -e "$EXTRA/FAILED" ] && [ "$(cur)" = "$before" ] \
  && pass "revert clears FAILED" || bad "revert clears FAILED: rc=$rc calls=$(ncalls)/$n"
new_env; run; before=$(cur); rm "$EXTRA/.stamp"; run
[ "$rc" -eq 0 ] && [ "$(cur)" = "$before" ] && [ -e "$EXTRA/current/marker" ] && [ -e "$EXTRA/.stamp" ] \
  && pass "lost stamp keeps current valid" || bad "lost stamp: rc=$rc cur=$(cur)"
new_env; run; before=$(cur)
printf 'flask==3.0.0\n' >"$REQ"; run FAKE_PIP_FAIL=1
[ "$rc" -eq 0 ] && [ "$(cur)" = "$before" ] && grep -q 'fake pip failure' "$EXTRA/FAILED" && [ "$(tmps)" -eq 0 ] \
  && pass "failure keeps current" || bad "failure keeps current: rc=$rc cur=$(cur) $(cat "$EXTRA/FAILED" 2>&1)"
run
[ "$rc" -eq 0 ] && [ ! -e "$EXTRA/FAILED" ] && [ "$(cur)" != "$before" ] \
  && pass "success clears FAILED" || bad "success clears FAILED"
new_env; run; before=$(cur); printf 'flask==3.0.0\n' >"$REQ"
SECONDS=0; run FAKE_PIP_SLEEP=5 INSTALL_TIMEOUT=1
[ "$rc" -eq 0 ] && [ "$SECONDS" -lt 4 ] && [ "$(cur)" = "$before" ] && [ -s "$EXTRA/FAILED" ] && [ "$(tmps)" -eq 0 ] \
  && pass "timeout fails" || bad "timeout: rc=$rc secs=$SECONDS cur=$(cur)"

say misc
new_env; mkdir -p "$EXTRA/abc.tmp"; run
[ ! -e "$EXTRA/abc.tmp" ] && [ -e "$EXTRA/current/marker" ] && pass "leftover tmp cleaned" || bad "leftover tmp"
new_env; printf 'requests==2.32.3 --hash=sha256:abc\n' >"$REQ"; run
grep -q -- '--require-hashes' "$CALLS" && pass "hashes enable require-hashes" || bad "hashes: $(cat "$CALLS")"
new_env; run
grep -q -- '--require-hashes' "$CALLS" && bad "no hashes, no flag" || pass "no hashes, no flag"
new_env; printf 'requests==2.32.3\r\nflask\r\n' >"$REQ"; run
[ -s "$CALLS.req" ] && ! grep -q $'\r' "$CALLS.req" && pass "CRLF stripped" || bad "CRLF stripped"
new_env; run LOG_OUT=/nonexistent/dir/log
[ "$rc" -eq 0 ] && grep -q '^\[install-extra\]' "$D/out" && pass "unwritable LOG_OUT falls back to stdout" || bad "LOG_OUT: rc=$rc"

say concurrency
new_env
env REQ_FILE="$REQ" EXTRA_DIR="$EXTRA" BASE_CONSTRAINTS="$CONS" IMAGE_VERSION_FILE="$VER" PIP_CMD="$FAKE" \
  CALLS="$CALLS" LOG_OUT="$LOG" FAKE_PIP_SLEEP=1 bash "$SCRIPT" >/dev/null 2>&1 & p1=$!
env REQ_FILE="$REQ" EXTRA_DIR="$EXTRA" BASE_CONSTRAINTS="$CONS" IMAGE_VERSION_FILE="$VER" PIP_CMD="$FAKE" \
  CALLS="$CALLS" LOG_OUT="$LOG" FAKE_PIP_SLEEP=1 bash "$SCRIPT" >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$(ncalls)" -eq 1 ] && [ -e "$EXTRA/current/marker" ] && [ "$(tmps)" -eq 0 ] \
  && pass "concurrent runs serialize" || bad "concurrent: r1=$r1 r2=$r2 calls=$(ncalls)"

finish
