# shellcheck shell=bash
# Kernel runtime limits, sourced by the venv's bin/activate so the Jupyter server
# and every kernel inherit them. RLIMIT_DATA is the per-kernel memory cap, so an
# oversized allocation raises MemoryError instead of OOM-killing the container.
# The thread counts keep OpenBLAS/OMP/MKL from failing to start under that cap.
#
# This file is sourced into the caller's shell: no set -e/-u, no exit, and every
# command that can fail is guarded so the caller always survives.

# _rdp_int <value> <default>: print value as a positive decimal integer, else default.
# 12 digits is the cap so the arithmetic cannot overflow.
_rdp_int() {
  case $1 in
    '' | *[!0-9]*) printf %s "$2" ;;
    *)
      if [ "${#1}" -le 12 ] && [ "$((10#$1))" -gt 0 ]; then
        printf %s "$((10#$1))"
      else
        printf %s "$2"
      fi ;;
  esac
}

_rdp_src=${RDP_JUPYTER_SESSION_ENV:-/run/rdp-jupyter/session.env}
_rdp_kb_raw='' _rdp_th_raw=''
if [ -r "$_rdp_src" ]; then
  # shellcheck disable=SC1090  # path is chosen at runtime; the file is root-written
  # Each value is read in a subshell, so nothing else in session.env reaches the caller.
  _rdp_kb_raw=$(. "$_rdp_src" >/dev/null 2>&1; printf %s "${KERNEL_MEMORY_LIMIT_KB:-}") || _rdp_kb_raw=
  # shellcheck disable=SC1090
  _rdp_th_raw=$(. "$_rdp_src" >/dev/null 2>&1; printf %s "${KERNEL_THREADS:-}") || _rdp_th_raw=
fi
_rdp_kb=$(_rdp_int "$_rdp_kb_raw" 2097152)
_rdp_threads=$(_rdp_int "$_rdp_th_raw" 2)

# Lowering is always allowed. Raising a hard limit fails once it has been lowered
# (e.g. activate sourced twice); then keep the existing limit and only note it.
if ! ulimit -S -H -d "$_rdp_kb" 2>/dev/null; then
  echo "[server-env] kernel memory limit ${_rdp_kb} KB not applied; keeping hard limit $(ulimit -H -d) KB" >&2
fi
export OPENBLAS_NUM_THREADS=$_rdp_threads OMP_NUM_THREADS=$_rdp_threads MKL_NUM_THREADS=$_rdp_threads

# startwm.sh points XDG_CONFIG_HOME at the per-session $S/xdg so each Electron
# instance gets its own userData. The server and kernels must not inherit it:
# matplotlib, pip, git and friends would ignore ~/.config and their writes would
# vanish with the session. Unset, they fall back to ~/.config.
unset XDG_CONFIG_HOME

unset -f _rdp_int
unset _rdp_src _rdp_kb_raw _rdp_th_raw _rdp_kb _rdp_threads
