#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/desktop-settings.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
GEN=images/rdp-jupyter/rootfs/opt/rdp-jupyter/desktop-settings.sh
HOME_WEIRD='/tmp/a b"c'
unset KERNEL_CULL_IDLE_TIMEOUT KERNEL_MEMORY_LIMIT_KB JUPYTER_LOCALE

# field <json text> <key>: the JSON encoding of one top-level field, so "false" and false differ
field() { printf %s "$1" | python3 -I -c 'import json,sys; sys.stdout.write(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$2"; }

# check <name> <key> <want-json> <out>: compare one field of the generated settings
check() {
  local name=$1 key=$2 want=$3 out=$4 got
  got=$(field "$out" "$key" 2>/dev/null) || got="<error>"
  [ "$got" = "$want" ] && pass "$name" || bad "$name: want $key=$want got $got"
}

say "defaults with an empty environment"
out=$(env -i PATH="$PATH" bash "$GEN" "$HOME_WEIRD" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && pass "exit 0 with empty env" || bad "exit $rc with empty env"
check "serverArgs defaults" serverArgs '"--MappingKernelManager.cull_idle_timeout=3600 --MappingKernelManager.cull_interval=300 --ResourceUseDisplay.mem_limit=2147483648"' "$out"

say "settings fields"
out=$(env KERNEL_CULL_IDLE_TIMEOUT=3600 bash "$GEN" "$HOME_WEIRD")
check "pythonPath" pythonPath '"/opt/jupyter/venv/bin/python"' "$out"
check "startupMode" startupMode '"new-local-session"' "$out"
check "checkForUpdatesAutomatically" checkForUpdatesAutomatically 'false' "$out"
check "installUpdatesAutomatically" installUpdatesAutomatically 'false' "$out"
check "notifyOnBundledEnvUpdates" notifyOnBundledEnvUpdates 'false' "$out"
check "showNewsFeed" showNewsFeed 'false' "$out"
check "defaultWorkingDirectory is the home argument" defaultWorkingDirectory '"/tmp/a b\"c"' "$out"
check "serverArgs cull and memory" serverArgs \
  '"--MappingKernelManager.cull_idle_timeout=3600 --MappingKernelManager.cull_interval=300 --ResourceUseDisplay.mem_limit=2147483648"' "$out"

say "environment values"
out=$(env KERNEL_CULL_IDLE_TIMEOUT=7200 KERNEL_MEMORY_LIMIT_KB=4194304 bash "$GEN" /home/x)
check "cull from env" serverArgs \
  '"--MappingKernelManager.cull_idle_timeout=7200 --MappingKernelManager.cull_interval=300 --ResourceUseDisplay.mem_limit=4294967296"' "$out"
check "plain home" defaultWorkingDirectory '"/home/x"' "$out"

say "escaping"
# shellcheck disable=SC2016  # the single quotes keep this string literal on purpose
inj='$(touch /nonexistent/pwned)'
out=$(bash "$GEN" "$inj" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && pass "hostile home exits 0" || bad "hostile home: rc=$rc"
check "home with \$() kept literal" defaultWorkingDirectory "\"$inj\"" "$out"
out=$(env KERNEL_CULL_IDLE_TIMEOUT="0;x" bash "$GEN" /home/x 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && pass "non-numeric cull fails with no output" || bad "hostile cull: rc=$rc out=$out"

say "usage"
bash "$GEN" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "missing home argument fails" || bad "missing home argument exits 0"

finish
