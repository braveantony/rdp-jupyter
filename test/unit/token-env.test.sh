#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/patches/token-env.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
PATCH=images/rdp-jupyter/patches/token-env.sh
FIX=test/unit/fixtures/asar
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SRV=build/out/main/server.js
SET=build/out/main/config/settings.js

say "patch applies"
cp -r "$FIX" "$tmp/a"
out=$(bash "$PATCH" "$tmp/a" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "exit 0" || bad "rc=$rc out=$out"
grep -q 'ServerApp.token' "$tmp/a/$SET" && bad "settings.js still has the token arg" || pass "settings.js has no ServerApp.token"
grep -q "ServerApp.password" "$tmp/a/$SET" && grep -q "LabApp.quit_button" "$tmp/a/$SET" && pass "neighbouring args kept" || bad "neighbours lost"
[ "$(grep -c 'JUPYTER_TOKEN: this._info.token,' "$tmp/a/$SRV")" -eq 1 ] && pass "server.js has JUPYTER_TOKEN once" || bad "JUPYTER_TOKEN count"
# the new line has the same indentation as the line above it
ind_a=$(grep 'JUPYTERLAB_WORKSPACES_DIR' "$tmp/a/$SRV" | sed -E 's/^( *).*/\1/')
ind_b=$(grep 'JUPYTER_TOKEN' "$tmp/a/$SRV" | sed -E 's/^( *).*/\1/')
[ "$ind_a" = "$ind_b" ] && pass "same indentation" || bad "indentation differs"

say "second run fails"
cp "$tmp/a/$SRV" "$tmp/srv.once"; cp "$tmp/a/$SET" "$tmp/set.once"
out=$(bash "$PATCH" "$tmp/a" 2>&1); rc=$?
[ "$rc" -eq 1 ] && pass "exit 1" || bad "rc=$rc"
grep -q '^\[token-env\] expected exactly one match for .* in ' <<<"$out" && pass "message" || bad "msg: $out"
cmp -s "$tmp/srv.once" "$tmp/a/$SRV" && cmp -s "$tmp/set.once" "$tmp/a/$SET" && pass "files unchanged after failure" || bad "files changed"

say "pattern twice fails and changes nothing"
# server.js anchor twice, settings.js fine: settings.js must stay untouched
cp -r "$FIX" "$tmp/b"
cat "$FIX/$SRV" >> "$tmp/b/$SRV"
cp "$tmp/b/$SRV" "$tmp/b.srv"; cp "$tmp/b/$SET" "$tmp/b.set"
out=$(bash "$PATCH" "$tmp/b" 2>&1); rc=$?
[ "$rc" -eq 1 ] && pass "exit 1 (server.js twice)" || bad "rc=$rc"
grep -q '^\[token-env\] expected exactly one match for .*JUPYTERLAB_WORKSPACES_DIR.* in .*server.js' <<<"$out" && pass "message names pattern and file" || bad "msg: $out"
cmp -s "$tmp/b.srv" "$tmp/b/$SRV" && cmp -s "$tmp/b.set" "$tmp/b/$SET" && pass "settings.js unchanged when server.js validation fails" || bad "files changed"
# settings.js token arg twice
cp -r "$FIX" "$tmp/c"
cat "$FIX/$SET" >> "$tmp/c/$SET"
cp "$tmp/c/$SRV" "$tmp/c.srv"; cp "$tmp/c/$SET" "$tmp/c.set"
out=$(bash "$PATCH" "$tmp/c" 2>&1); rc=$?
[ "$rc" -eq 1 ] && pass "exit 1 (settings.js twice)" || bad "rc=$rc"
cmp -s "$tmp/c.srv" "$tmp/c/$SRV" && cmp -s "$tmp/c.set" "$tmp/c/$SET" && pass "server.js unchanged when settings.js validation fails" || bad "files changed"

say "usage and missing files"
out=$(bash "$PATCH" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^\[token-env\]' <<<"$out" && pass "no args" || bad "no args rc=$rc out=$out"
out=$(bash "$PATCH" a b 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^\[token-env\]' <<<"$out" && pass "two args" || bad "two args rc=$rc"
mkdir -p "$tmp/empty"
out=$(bash "$PATCH" "$tmp/empty" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '^\[token-env\]' <<<"$out" && pass "missing files" || bad "missing rc=$rc out=$out"

finish
