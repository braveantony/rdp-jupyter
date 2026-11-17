#!/usr/bin/env bash
# Attached mode (RDP_MODE=attached): the container runs no xrdp. It waits on a
# unix socket and starts JupyterLab Desktop for whoever asks, on a desktop that
# another container of the same pod provides.   bash test/image/attached.test.sh [image]
# The "desktop" here is a second container from the same image in standalone
# mode; in a real deployment it is rdp-firefox in workspace mode.
# Chromium keeps CJK font data in /dev/shm; the 64MB default is too small.
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted conditions are eval'd later
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
CLIENT=localhost/rdp-jupyter-e2e-client:dev
POD=rdpj-attached-test
HOMEVOL=rdpj-attached-home
RUNVOL=rdpj-attached-run
PORT=33394
SOCK=/run/rdp-workspace/jupyter.sock
OUT=$PWD/test/e2e/out
# JupyterLab Desktop's main process, and the JupyterLab server it starts
MAIN_RE='^/opt/JupyterLab/jupyterlab-desktop --no-sandbox --disable-gpu$'
SERVER_RE='^python[0-9.]* -m jupyterlab( |$)'
mkdir -p "$OUT"

cleanup() {
  podman rm -f -t 0 rdpj-attached-client rdpj-attached-solo >/dev/null 2>&1
  podman pod rm -f -t 0 "$POD" >/dev/null 2>&1
  podman volume rm -f "$HOMEVOL" "$RUNVOL" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

wait_for() {  # wait_for <seconds> <bash condition>
  local end=$((SECONDS + $1))
  while :; do
    eval "$2" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 1
  done
}
ax() { podman exec "$POD-attached" bash -c "$1"; }   # in the attached container
dx() { podman exec "$POD-desktop" bash -c "$1"; }    # in the desktop container
sx() { podman exec rdpj-attached-solo bash -c "$1"; }
main_pids() { ax "pgrep -u bigred -f '$MAIN_RE' || true"; }
server_pids() { ax "pgrep -u bigred -f '$SERVER_RE' || true"; }
# What the desktop's button does: send the display, print the reply
ask() {  # ask <account> <display>
  dx "su $1 -s /bin/sh -c 'perl -MIO::Socket::UNIX -e \"\\\$s = IO::Socket::UNIX->new(Peer => \\\"$SOCK\\\") or die; print \\\$s \\\"$2\\\\n\\\"; print scalar <\\\$s>\"'"
}

podman image exists "$IMG" || { bad "image $IMG not found"; finish; }
podman build -q -t "$CLIENT" test/e2e/client >/dev/null || { bad "client build"; finish; }

say invalid-mode
out=$(timeout 20 podman run --rm --name rdpj-attached-solo -e RDP_PASSWORD=x -e RDP_MODE=bogus "$IMG" 2>&1); rc=$?
podman rm -f -t 0 rdpj-attached-solo >/dev/null 2>&1
[ "$rc" -ne 124 ] || rc=0   # still running after 20s: the mode was not rejected
[ "$rc" -ne 0 ] && grep -q "RDP_MODE" <<<"$out" && pass "an unknown RDP_MODE stops the container with a message" \
  || bad "RDP_MODE=bogus: rc=$rc out=$out"

say waits-for-home
# The desktop container creates the homes. Started alone, an attached container
# must neither create a home nor serve requests until the home is there.
podman volume create "$HOMEVOL" >/dev/null; podman volume create "$RUNVOL" >/dev/null
podman run -d --name rdpj-attached-solo -e RDP_PASSWORD=bigred -e RDP_MODE=attached \
  -v "$HOMEVOL:/home" -v "$RUNVOL:/run/rdp-workspace" "$IMG" >/dev/null
sleep 6
sx 'id -u bigred >/dev/null 2>&1' && pass "account exists before its home does" || bad "no bigred account"
sx '[ ! -e /home/bigred ]' && pass "attached mode does not create the home" || bad "attached mode created /home/bigred"
sx "[ ! -S $SOCK ]" && pass "not serving while the home is missing" || bad "socket exists before the home"
# Now the "desktop" creates the home, with a file of the user's own
sx 'install -d -m 700 -o bigred -g bigred /home/bigred
    echo "# mine" > /home/bigred/.bashrc; chown bigred:bigred /home/bigred/.bashrc'
wait_for 20 "sx '[ -S $SOCK ]'" && pass "serves once the home exists" || bad "no socket 20s after the home appeared"
sx 'grep -qx "# mine" /home/bigred/.bashrc' && pass "existing files are kept" || bad ".bashrc was overwritten"
sx '[ -f /home/bigred/.profile ] && [ "$(stat -c %U /home/bigred/.profile)" = bigred ]' \
  && pass "missing default files are added, owned by the account" || bad "no bigred-owned ~/.profile"
sx '! pgrep -x xrdp >/dev/null && ! pgrep -x xrdp-sesman >/dev/null' && pass "no xrdp, no xrdp-sesman" || bad "xrdp is running in attached mode"
sx '! (exec 3<>/dev/tcp/127.0.0.1/3389) 2>/dev/null' && pass "nothing listens on 3389" || bad "port 3389 is open in attached mode"
sx 'test -s /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json' && pass "JupyterLab's default locale is still written" || bad "no overrides.json in attached mode"
podman rm -f -t 0 rdpj-attached-solo >/dev/null; podman volume rm -f "$HOMEVOL" "$RUNVOL" >/dev/null

say pod
podman volume create "$HOMEVOL" >/dev/null; podman volume create "$RUNVOL" >/dev/null
podman pod create --name "$POD" --shm-size 1g -p "$PORT:3389" >/dev/null
podman run -d --pod "$POD" --name "$POD-desktop" -e RDP_PASSWORD=bigred \
  -v "$HOMEVOL:/home" -v "$RUNVOL:/run/rdp-workspace" "$IMG" >/dev/null
wait_for 30 'dx "grep -q \"listening to port 3389\" /var/log/xrdp.log" 2>/dev/null' && pass "desktop (standalone) up" || { bad "desktop did not start"; finish; }
podman run -d --pod "$POD" --name "$POD-attached" -e RDP_PASSWORD=bigred -e RDP_MODE=attached \
  -v "$HOMEVOL:/home" -v "$RUNVOL:/run/rdp-workspace" "$IMG" >/dev/null
wait_for 20 "ax '[ -S $SOCK ]' 2>/dev/null" && pass "attached container serving" || { bad "attached container not serving"; podman logs "$POD-attached" 2>&1 | tail -5; finish; }
[ "$(dx 'pgrep -xc xrdp')" -ge 1 ] && [ "$(ax 'pgrep -xc xrdp || true')" = 0 ] \
  && pass "one xrdp in the pod (desktop only)" || bad "xrdp count: desktop=$(dx 'pgrep -xc xrdp') attached=$(ax 'pgrep -xc xrdp || true')"

say launch
podman run -d --name rdpj-attached-client --network host -v "$OUT:/out:Z" \
  "$CLIENT" "127.0.0.1:$PORT" bigred bigred attached-1 :96 >/dev/null
wait_for 60 'dx "ls /tmp/.X11-unix/ 2>/dev/null | grep -q ^X"' || bad "no desktop session after login"
disp=":$(dx 'ls /tmp/.X11-unix/ | sed -n "s/^X//p" | head -1')"
[ -z "$(main_pids)" ] && pass "no JupyterLab Desktop in the attached container before a request" || bad "already running: $(main_pids)"
r=$(ask bigred "$disp")
[ "$r" = OK ] && pass "request on $disp accepted" || bad "request on $disp: $r"
if wait_for 40 '[ -n "$(main_pids)" ]'; then
  pass "JupyterLab Desktop runs in the attached container"
  wait_for 60 '[ -n "$(server_pids)" ]' && pass "and starts its JupyterLab server there" || bad "no python -m jupyterlab within 60s"
  sleep 5   # an X client without access dies within a second or two
  [ -n "$(main_pids)" ] && pass "and stays on the desktop's display" || bad "JupyterLab Desktop exited: $(podman logs "$POD-attached" 2>&1 | tail -3)"
  ax '! pgrep -u bigred -x openbox >/dev/null' && pass "no second window manager" || bad "openbox runs in the attached container"
else
  bad "no JupyterLab Desktop within 40s: $(podman logs "$POD-attached" 2>&1 | tail -3)"
fi

say second-request
# Pressing the button again must not wipe the running session's dirs or
# start a second server
m1=$(main_pids); s1=$(server_pids)
r=$(ask bigred "$disp"); sleep 10
[ "$r" = OK ] && pass "second request accepted" || bad "second request: $r"
[ -n "$m1" ] && [ "$(main_pids)" = "$m1" ] && pass "the first JupyterLab Desktop keeps running, and is the only one" \
  || bad "main processes before: [$m1] after: [$(main_pids)]"
[ -n "$s1" ] && [ "$(server_pids)" = "$s1" ] && pass "still the same JupyterLab server" || bad "servers before: [$s1] after: [$(server_pids)]"
ax 'test -s /tmp/sess/*.1000/xdg/jupyterlab-desktop/settings.json' && pass "its session dir is intact" || bad "session dir damaged: $(ax 'ls -la /tmp/sess/*/xdg/jupyterlab-desktop' 2>&1 | head -3)"

say close
ax "pkill -u bigred -f '$MAIN_RE'" || true
wait_for 30 "[ -z \"\$(ax 'ls -d /tmp/sess/*.1000 2>/dev/null')\" ]" && pass "closing JupyterLab Desktop removes its session dir" || bad "session dir left: $(ax 'ls -d /tmp/sess/*')"
wait_for 15 '[ -z "$(server_pids)" ]' && pass "and stops its JupyterLab server" || bad "server left running: $(server_pids)"
dx 'ls /tmp/.X11-unix/ | grep -q ^X' && pass "the desktop is still there" || bad "closing JupyterLab Desktop ended the desktop"

finish
