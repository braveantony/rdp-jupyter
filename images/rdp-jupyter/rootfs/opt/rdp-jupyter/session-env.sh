#!/usr/bin/env bash
# Print the session settings that the per-session scripts source: sessions start
# with a clean environment, so the container env has to be saved to a file.
set -eu

# invalid <NAME> <value> <default>: warn on stderr that a set value was rejected
invalid() { echo "[entrypoint] invalid $1: $2; using $3" >&2; }

# int_setting <NAME> <default> <min>: print NAME as an integer >= min, else the default.
# Unset or empty means the default silently. 12 digits is the cap so the
# arithmetic cannot overflow; it is far above any real timeout.
int_setting() {
  local name=$1 def=$2 min=$3 v=${!1:-}
  if [ -z "$v" ]; then
    printf %s "$def"
    return
  fi
  case $v in
    '' | *[!0-9]*) ;;
    *) if [ "${#v}" -le 12 ] && [ $((10#$v)) -ge "$min" ]; then
         printf %s "$((10#$v))"
         return
       fi ;;
  esac
  invalid "$name" "$v" "$def"
  printf %s "$def"
}

# Memory: <positive integer>Mi or <positive integer>Gi; below 1Gi is raised to 1Gi.
mem=2Gi
mem_kb=2097152
raw=${KERNEL_MEMORY_LIMIT:-}
if [ -n "$raw" ]; then
  num=${raw%[MG]i}
  unit=0
  case $raw in
    *Mi) unit=1024 ;;
    *Gi) unit=1048576 ;;
  esac
  case $num in
    '' | *[!0-9]*) unit=0 ;;
  esac
  if [ "$unit" -gt 0 ] && [ "${#num}" -le 12 ] && [ $((10#$num)) -ge 1 ]; then
    mem_kb=$((10#$num * unit))
    mem="$((10#$num))${raw#"$num"}"
    if [ "$mem_kb" -lt 1048576 ]; then
      echo "[entrypoint] KERNEL_MEMORY_LIMIT $raw raised to 1Gi" >&2
      mem=1Gi
      mem_kb=1048576
    fi
  else
    invalid KERNEL_MEMORY_LIMIT "$raw" 2Gi
  fi
fi

threads=$(int_setting KERNEL_THREADS 2 1)
cull=$(int_setting KERNEL_CULL_IDLE_TIMEOUT 3600 0)
disconnected=$(int_setting DISCONNECTED_TIMEOUT 28800 1)
# xorgxrdp (module/rdpClientCon.c) kills a disconnected desktop after at least
# 60 seconds, whatever sesman.ini says; say so instead of silently differing
if [ "$disconnected" -lt 60 ]; then
  echo "[entrypoint] DISCONNECTED_TIMEOUT $DISCONNECTED_TIMEOUT raised to 60" >&2
  disconnected=60
fi

# JUPYTER_LOCALE: zh-tw or zh_TW (JupyterLab's zh_TW code) or en. Unset or empty is the default.
locale=zh_TW
case ${JUPYTER_LOCALE:-zh-tw} in
  zh-tw | zh_TW) ;;
  en) locale=en ;;
  *) invalid JUPYTER_LOCALE "${JUPYTER_LOCALE:-}" zh_TW ;;
esac

printf 'KERNEL_MEMORY_LIMIT_KB=%q\n' "$mem_kb"
printf 'KERNEL_MEMORY_LIMIT=%q\n' "$mem"
printf 'KERNEL_THREADS=%q\n' "$threads"
printf 'KERNEL_CULL_IDLE_TIMEOUT=%q\n' "$cull"
printf 'JUPYTER_LOCALE=%q\n' "$locale"
printf 'DISCONNECTED_TIMEOUT=%q\n' "$disconnected"
