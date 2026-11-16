#!/bin/bash
# Run by xrdp-sesman as the logged-in account for every new desktop. sesman uses
# Policy=Default, so a reconnect reattaches to the existing session and this
# script does not run again. Xorg sessions are fixed at 24 bpp (xrdp's
# libipm/scp.c), so a client asking for another colour depth reattaches too.
# Each session still gets its own XDG_CONFIG_HOME, runtime dir and D-Bus as
# defense in depth: JupyterLab Desktop keeps its single-instance lock in
# userData, so if one account ever ends up with two desktops, a shared userData
# would make the second JupyterLab Desktop exit at once. Per-user
# JupyterLab settings (~/.jupyter) are shared. Closing JupyterLab Desktop ends
# the session.
# In attached mode (RDP_ATTACHED=1, set by attached-session.sh) the launcher
# runs this script instead of sesman: the desktop, its window manager and its
# input method belong to another container, so only JupyterLab Desktop is
# started here.
set -u
RDP_ATTACHED=${RDP_ATTACHED:-0}

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
if [ "$RDP_ATTACHED" = 1 ] && [ -O "$S/xdg" ] && [ -s "$S/jlab.pid" ] &&
   kill -0 "$(cat "$S/jlab.pid")" 2>/dev/null; then
  # Asked again while JupyterLab Desktop is open on this desktop: start it with
  # the same userData, so its single-instance lock hands over to the running
  # one, instead of wiping the running session's dirs
  export XDG_CONFIG_HOME="$S/xdg" XDG_RUNTIME_DIR="$S/run"
  export JLAB_DESKTOP_CONFIG_DIR="$HOME/.jupyter"
  exec /opt/JupyterLab/jupyterlab-desktop --no-sandbox --disable-gpu
fi
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
  # JupyterLab Desktop leads its own process group (setsid below), which holds
  # its helpers and the JupyterLab server. Signal the whole group: when Xorg
  # goes away first (the disconnected timeout), JupyterLab Desktop dies without
  # stopping its server, and the server would be left running. The server
  # stops its kernels (they have their own sessions) on SIGTERM. If it has to be
  # KILLed, each ipykernel's parent poller (JPY_PARENT_PID, set by
  # jupyter_client) sees its parent gone and ends the kernel.
  if [ -n "$jlab_pid" ]; then
    kill -TERM -- "-$jlab_pid" 2>/dev/null
    for _ in $(seq 20); do kill -0 -- "-$jlab_pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL -- "-$jlab_pid" 2>/dev/null
  fi
  kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  pkill -TERM -P $$ 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

# The kiosk config is root-owned and passed explicitly: XDG_CONFIG_HOME points
# at $S/xdg, so openbox would never find ~/.config/openbox/rc.xml, and users
# must not be able to edit kiosk mode away
if [ "$RDP_ATTACHED" = 1 ]; then
  # The desktop's input method is reached over X (XIM); GTK's own XIM module
  # is in every image, the desktop's input method module is not
  export GTK_IM_MODULE=xim XMODIFIERS=@im=fcitx
else
  openbox --config-file /etc/rdp-jupyter/openbox-rc.xml &
fi
/opt/rdp-jupyter/notify-extra.sh &

# Run the Electron binary itself, with --no-sandbox (spec section 6: the pod's
# seccomp blocks Chromium's namespace sandbox) and --disable-gpu (there is no
# GPU and the image has no Mesa drivers; see docs/spike-notes.md section 6).
# In the background so a SIGTERM from sesman runs the trap right away. setsid
# makes it a process group leader (this shell has no job control, so the child
# is not one already and setsid runs it in place: $! is its PID and PGID).
setsid /opt/JupyterLab/jupyterlab-desktop --no-sandbox --disable-gpu &
jlab_pid=$!
echo "$jlab_pid" > "$S/jlab.pid"
wait "$jlab_pid"
