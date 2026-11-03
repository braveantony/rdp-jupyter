#!/bin/bash
# Run by xrdp-sesman as the logged-in account for every new desktop. sesman uses
# Policy=Default, so a reconnect reattaches to the existing session and this
# script does not run again. A second session still happens when the colour depth
# differs, and JupyterLab Desktop keeps its single-instance lock in userData, so
# each session gets its own XDG_CONFIG_HOME, runtime dir and D-Bus. Per-user
# JupyterLab settings (~/.jupyter) are shared. Closing JupyterLab Desktop ends
# the session.
set -u

# Container env does not reach sesman sessions; entrypoint.sh saves it here
# shellcheck source=/dev/null
[ -r /run/rdp-jupyter/session.env ] && . /run/rdp-jupyter/session.env
JUPYTER_LOCALE=${JUPYTER_LOCALE:-zh_TW}
case $JUPYTER_LOCALE in
  en) lang=C.UTF-8 ;;
  *)  lang=zh_TW.UTF-8 ;;
esac
export LANG=$lang LC_ALL=$lang TZ=Asia/Taipei NO_AT_BRIDGE=1
# desktop-settings.sh reads these from the environment
export KERNEL_CULL_IDLE_TIMEOUT=${KERNEL_CULL_IDLE_TIMEOUT:-3600}
export KERNEL_MEMORY_LIMIT_KB=${KERNEL_MEMORY_LIMIT_KB:-2097152}
export JUPYTER_LOCALE

# sesman sets DISPLAY=:N.0; the socket is /tmp/.X11-unix/XN
dnum=${DISPLAY#*:}
dnum=${dnum%%.*}
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Keyed by display and UID, so another account's leftover on the same display
# number does not collide. A directory that this account cannot remove (another
# account created it in the sticky /tmp/sess) is refused, never reused.
S="/tmp/sess/$dnum.$(id -u)"
rm -rf "$S" 2>/dev/null
umask 077
if ! mkdir -m 700 "$S"; then
  echo "[startwm] $S exists and is not ours; refusing to start" >&2
  exit 1
fi
mkdir -m 700 "$S/xdg" "$S/run" "$S/xdg/jupyterlab-desktop"
mkdir -p "$HOME/.jupyter"
export XDG_CONFIG_HOME="$S/xdg" XDG_RUNTIME_DIR="$S/run"
export JLAB_DESKTOP_CONFIG_DIR="$HOME/.jupyter"
cd "$HOME" || exit 1

# Write to a temp file and move it into place: JupyterLab Desktop must never
# start with a missing or partial settings.json (it shows its environment chooser)
cfg="$S/xdg/jupyterlab-desktop"
if ! /opt/rdp-jupyter/desktop-settings.sh "$HOME" >"$cfg/settings.json.tmp" ||
   ! mv "$cfg/settings.json.tmp" "$cfg/settings.json"; then
  echo "[startwm] cannot write settings.json" >&2
  rm -rf "$S"
  exit 1
fi

eval "$(dbus-launch --sh-syntax)"

jlab_pid=""
cleanup() {
  if [ -n "$jlab_pid" ]; then
    kill -TERM "$jlab_pid" 2>/dev/null
    for _ in $(seq 20); do kill -0 "$jlab_pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$jlab_pid" 2>/dev/null
  fi
  kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  pkill -TERM -P $$ 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

openbox &
/opt/rdp-jupyter/notify-extra.sh &

# Run the Electron binary itself, with --no-sandbox (spec section 6: the pod's
# seccomp blocks Chromium's namespace sandbox). In the background so a SIGTERM
# from sesman runs the trap right away.
/opt/JupyterLab/jupyterlab-desktop --no-sandbox &
jlab_pid=$!
wait "$jlab_pid"
