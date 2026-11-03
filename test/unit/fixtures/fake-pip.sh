#!/usr/bin/env bash
# Fake PIP_CMD for install-extra tests.
# Records args to $CALLS (one line per call), the TMPDIR it saw, and a copy of
# the -r file to "$CALLS.req". FAKE_PIP_SLEEP=<sec> delays; FAKE_PIP_FAIL=1 fails.
target='' req='' prev=''
for a in "$@"; do
  [ "$prev" = "--target" ] && target=$a
  [ "$prev" = "-r" ] && req=$a
  prev=$a
done
printf '%s TMPDIR=%s\n' "$*" "${TMPDIR:-}" >>"$CALLS"
[ -n "$req" ] && cp "$req" "$CALLS.req"
[ -n "${FAKE_PIP_SLEEP:-}" ] && sleep "$FAKE_PIP_SLEEP"
if [ "${FAKE_PIP_FAIL:-}" = 1 ]; then
  echo "ERROR: fake pip failure: no matching distribution" >&2
  exit 1
fi
mkdir -p "$target" && : >"$target/marker"
