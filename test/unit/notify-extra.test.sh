#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/notify-extra.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
ROOT=$PWD
SCRIPT=$ROOT/images/rdp-jupyter/rootfs/opt/rdp-jupyter/notify-extra.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat >"$T/fake-xmessage" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >>"$CALLS"
exit "${FAKE_XMESSAGE_RC:-0}"
FAKE
chmod +x "$T/fake-xmessage"

new_env() { D=$(mktemp -d "$T/case.XXXXXX"); EXTRA=$D/extra CALLS=$D/calls; mkdir "$EXTRA"; : >"$CALLS"; }
run() {  # run [VAR=value...]; sets rc
  env EXTRA_DIR="$EXTRA" XMESSAGE="$T/fake-xmessage" CALLS="$CALLS" "$@" bash "$SCRIPT" >"$D/out" 2>&1
  rc=$?
}

say FAILED present
new_env; printf 'pip: no matching distribution\n' >"$EXTRA/FAILED"; run
[ "$rc" -eq 0 ] && pass "exits 0" || bad "exits 0 (rc=$rc)"
grep -qx -- '-center' "$CALLS" && pass "uses -center" || bad "uses -center"
grep -q 'Extra packages failed to install' "$CALLS" && pass "has heading" || bad "has heading"
grep -q 'pip: no matching distribution' "$CALLS" && pass "has file contents" || bad "has file contents"

say FAILED absent
new_env; run
[ "$rc" -eq 0 ] && [ ! -s "$CALLS" ] && pass "no call, exit 0" || bad "no call, exit 0 (rc=$rc)"

say xmessage fails
new_env; echo boom >"$EXTRA/FAILED"; run FAKE_XMESSAGE_RC=1
[ "$rc" -eq 0 ] && pass "exit 0 despite failing xmessage" || bad "exit 0 despite failing xmessage (rc=$rc)"

say xmessage missing
new_env; echo boom >"$EXTRA/FAILED"; run XMESSAGE="$T/nonexistent"
[ "$rc" -eq 0 ] && pass "exit 0 when xmessage missing" || bad "exit 0 when xmessage missing (rc=$rc)"

finish
