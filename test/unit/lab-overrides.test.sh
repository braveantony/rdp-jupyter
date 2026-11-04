#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/lab-overrides.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
GEN=images/rdp-jupyter/rootfs/opt/rdp-jupyter/lab-overrides.sh
unset JUPYTER_LOCALE

# locale_of <json text>: the locale the translation plugin is set to, or <error>
locale_of() {
  printf %s "$1" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["@jupyterlab/translation-extension:plugin"]["locale"])' 2>/dev/null || echo "<error>"
}

say "defaults with an empty environment"
out=$(env -i PATH="$PATH" bash "$GEN" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 with empty env" || bad "exit $rc with empty env"
got=$(locale_of "$out")
[ "$got" = zh_TW ] && pass "locale defaults to zh_TW" || bad "default locale: got $got in: $out"

say "locale"
out=$(JUPYTER_LOCALE=en bash "$GEN")
got=$(locale_of "$out")
[ "$got" = en ] && pass "locale en" || bad "locale en: got $got in: $out"
out=$(JUPYTER_LOCALE=zh_TW bash "$GEN")
got=$(locale_of "$out")
[ "$got" = zh_TW ] && pass "locale zh_TW" || bad "locale zh_TW: got $got in: $out"
out=$(env JUPYTER_LOCALE= bash "$GEN")
got=$(locale_of "$out")
[ "$got" = zh_TW ] && pass "empty locale is default" || bad "empty locale: got $got in: $out"

say "output shape"
out=$(JUPYTER_LOCALE=en bash "$GEN")
want='{"@jupyterlab/translation-extension:plugin": {"locale": "en"},
      "@jupyterlab/apputils-extension:notification": {"fetchNews": "false", "checkForUpdates": false}}'
python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])==json.loads(sys.argv[2]) else 1)' "$out" "$want" \
  && pass "exact document" || bad "document differs: $out"

finish
