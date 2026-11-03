#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/session-env.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
GEN=images/rdp-jupyter/rootfs/opt/rdp-jupyter/session-env.sh
unset KERNEL_MEMORY_LIMIT KERNEL_THREADS KERNEL_CULL_IDLE_TIMEOUT JUPYTER_LOCALE DISCONNECTED_TIMEOUT

# value_of <session.env text> <name>: the value after sourcing it like the session scripts do
value_of() { bash -c '. /dev/stdin; printf %s "${!1}"' _ "$2" <<<"$1"; }

check() {  # check <name> <var> <want> [VAR=value...]: run the generator with the given env
  local name=$1 var=$2 want=$3 out got
  shift 3
  out=$(env "$@" bash "$GEN" 2>/dev/null)
  got=$(value_of "$out" "$var")
  [ "$got" = "$want" ] && pass "$name" || bad "$name: want $var='$want' got '$got' in: $out"
}

say defaults
check "memory 2Gi" KERNEL_MEMORY_LIMIT_KB 2097152
check "memory string 2Gi" KERNEL_MEMORY_LIMIT 2Gi
check "threads 2" KERNEL_THREADS 2
check "cull 3600" KERNEL_CULL_IDLE_TIMEOUT 3600
check "locale zh_TW" JUPYTER_LOCALE zh_TW
check "disconnect 28800" DISCONNECTED_TIMEOUT 28800

say memory
check "Mi" KERNEL_MEMORY_LIMIT_KB 1572864 KERNEL_MEMORY_LIMIT=1536Mi
check "Gi" KERNEL_MEMORY_LIMIT_KB 4194304 KERNEL_MEMORY_LIMIT=4Gi
check "Gi keeps string" KERNEL_MEMORY_LIMIT 4Gi KERNEL_MEMORY_LIMIT=4Gi
check "below 1Gi is raised" KERNEL_MEMORY_LIMIT_KB 1048576 KERNEL_MEMORY_LIMIT=256Mi
check "raised string is 1Gi" KERNEL_MEMORY_LIMIT 1Gi KERNEL_MEMORY_LIMIT=256Mi
check "garbage is default" KERNEL_MEMORY_LIMIT_KB 2097152 KERNEL_MEMORY_LIMIT=lots
check "bare number is default" KERNEL_MEMORY_LIMIT_KB 2097152 KERNEL_MEMORY_LIMIT=2048
check "zero is default" KERNEL_MEMORY_LIMIT_KB 2097152 KERNEL_MEMORY_LIMIT=0Gi
err=$(KERNEL_MEMORY_LIMIT=256Mi bash "$GEN" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -q 'raised to 1Gi' <<<"$err" \
  && pass "256Mi warns raised" || bad "256Mi: rc=$rc err=$err"
err=$(KERNEL_MEMORY_LIMIT=lots bash "$GEN" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -q '^\[entrypoint\] invalid KERNEL_MEMORY_LIMIT: lots' <<<"$err" \
  && pass "garbage warns invalid" || bad "garbage: rc=$rc err=$err"

say threads and cull
check "threads 4" KERNEL_THREADS 4 KERNEL_THREADS=4
check "threads 0 is default" KERNEL_THREADS 2 KERNEL_THREADS=0
check "threads text is default" KERNEL_THREADS 2 KERNEL_THREADS=many
check "cull 0 allowed" KERNEL_CULL_IDLE_TIMEOUT 0 KERNEL_CULL_IDLE_TIMEOUT=0
check "cull negative is default" KERNEL_CULL_IDLE_TIMEOUT 3600 KERNEL_CULL_IDLE_TIMEOUT=-1

say locale
check "locale en" JUPYTER_LOCALE en JUPYTER_LOCALE=en
check "locale zh-tw" JUPYTER_LOCALE zh_TW JUPYTER_LOCALE=zh-tw
check "locale zh_TW" JUPYTER_LOCALE zh_TW JUPYTER_LOCALE=zh_TW
check "locale bad" JUPYTER_LOCALE zh_TW JUPYTER_LOCALE=fr

say disconnect
check "disconnect 3600" DISCONNECTED_TIMEOUT 3600 DISCONNECTED_TIMEOUT=3600
check "disconnect bad" DISCONNECTED_TIMEOUT 28800 DISCONNECTED_TIMEOUT=-5
check "disconnect 0 is default" DISCONNECTED_TIMEOUT 28800 DISCONNECTED_TIMEOUT=0
check "disconnect empty is default" DISCONNECTED_TIMEOUT 28800 DISCONNECTED_TIMEOUT=
err=$(env DISCONNECTED_TIMEOUT= bash "$GEN" 2>&1 >/dev/null)
[ -z "$err" ] && pass "unset-like empty does not warn" || bad "empty warns: $err"

finish
