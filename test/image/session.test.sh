#!/usr/bin/env bash
# RDP session tests against a local server container: bash test/image/session.test.sh [image]
# Logs in like a user does (test/e2e/client: FreeRDP on Xvfb, xrdp login screen)
# and checks the kiosk, the token, limits, reconnects, the extra-packages notice,
# closing the window and the disconnected timeout. Screenshots and client logs
# go to test/e2e/out/, named after the section.
# shellcheck disable=SC1091,SC2015,SC2016,SC2034  # pass() never fails; single-quoted conditions (and the variables only they use) are eval'd later
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
CLIENT=localhost/rdp-jupyter-e2e-client:dev
PORT=33391
OUT=$PWD/test/e2e/out
# Every container this run starts carries this prefix; the trap removes them all
P=rdpj-session-$$
SERVER=$P-server
MARK=/tmp/session-test.mark
# The JupyterLab server started by JupyterLab Desktop: `python -m jupyterlab --no-browser ...`
SERVER_RE='^python[0-9.]* -m jupyterlab( |$)'
# Settings file of the translation extension, as JupyterLab writes it under JLAB_DESKTOP_CONFIG_DIR
LOCALE_FILE=/home/bigred/.jupyter/lab/user-settings/@jupyterlab/translation-extension/plugin.jupyterlab-settings
OVERRIDES=/opt/jupyter/venv/share/jupyter/lab/settings/overrides.json
mkdir -p "$OUT"

cleanup() {
  podman ps -aq --filter "name=^$P-" | xargs -r podman rm -f -t 0 >/dev/null 2>&1
}
trap cleanup EXIT

# wait_for <seconds> <bash condition>: poll until the condition holds or the deadline passes
wait_for() {
  local end=$((SECONDS + $1))
  while :; do
    eval "$2" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 1
  done
}

px() { podman exec "$SERVER" bash -c "$1"; }
pxu() { podman exec --user bigred "$SERVER" bash -c "$1"; }
xorg_count() { px 'pgrep -c -u bigred -x Xorg || true'; }
server_pids() { px "pgrep -u bigred -f '$SERVER_RE' || true"; }
xorg_displays() { px 'pgrep -a -u bigred -x Xorg' | grep -o ' :[0-9]*' | tr -d ' :'; }
reconnects() { px 'grep -c "++ reconnected session" /var/log/xrdp-sesman.log || true'; }

server_start() {  # server_start [podman run options...]
  podman rm -f -t 0 "$SERVER" >/dev/null 2>&1
  podman run -d --name "$SERVER" --shm-size=1g -e RDP_PASSWORD=bigred -p "$PORT:3389" \
    "$@" "$IMG" >/dev/null || return 1
  wait_for 30 'px "grep -q \"listening to port 3389\" /var/log/xrdp.log" 2>/dev/null'
}

# login <name> <X display> [bpp]: start client $P-<name> (name = <section>-cN); its
# login screenshot and FreeRDP log are /out/<name>.*
login() {
  podman run -d --name "$P-$1" --network host -v "$OUT:/out:Z" \
    "$CLIENT" "127.0.0.1:$PORT" bigred bigred "$1" "$2" ${3:+"$3"} >/dev/null
}
client_rm() { podman rm -f -t 0 "$P-$1" >/dev/null 2>&1; }
# shot <client> <X display> <file>: screenshot of the client's screen to $OUT/<file>.png
shot() {
  podman exec "$P-$1" sh -c "xwd -display $2 -root -silent | magick xwd:- /out/$3.png"
}
# title_bar <client> <X display>: JupyterLab Desktop's own title bar is on the
# client's screen. Its close (X) glyph is the only dark shape in the top-right
# 40x30 corner of the 1280x800 screen: a 12x12 box at 1254,9 (centre 1260,15).
title_bar() {
  [ "$(podman exec "$P-$1" sh -c "xwd -display $2 -root -silent | magick xwd:- -crop 40x30+1240+0 \
      -threshold 50% -negate -trim -format '%wx%h%X%Y' info:" 2>/dev/null)" = 12x12+1254+9 ]
}
# lab_loaded: the JupyterLab front end has saved its workspace since the marker,
# so the lab UI (not just the window) is up
lab_loaded() {
  pxu "find ~/.jupyter/desktop-workspaces -name '*.jupyterlab-workspace' -newer $MARK 2>/dev/null | grep -q ."
}
mark() { px "touch $MARK && chmod 644 $MARK"; }
# close_all: quit every desktop (JupyterLab Desktop's main process; startwm.sh then ends the session)
close_all() {
  podman ps -a --format '{{.Names}}' --filter "name=^$P-" | grep -vx "$SERVER" \
    | xargs -r podman rm -f -t 0 >/dev/null 2>&1
  px "pkill -u bigred -f '^/opt/JupyterLab/jupyterlab-desktop --no-sandbox' || true"
  wait_for 30 '[ "$(xorg_count)" -eq 0 ]'
}

podman image exists "$IMG" || { bad "image $IMG not found"; finish; }
podman build -q -t "$CLIENT" test/e2e/client >/dev/null || { bad "client build"; finish; }
rm -f "$OUT"/kiosk* "$OUT"/reconnect* "$OUT"/other-bpp* "$OUT"/locale-kept* \
  "$OUT"/failed-notice* "$OUT"/close* "$OUT"/timeout*
server_start || { bad "server did not start listening"; finish; }

say kiosk
mark
login kiosk-c1 :95
if wait_for 40 '[ -n "$(server_pids)" ]'; then
  pass "jupyterlab server running: $(px "pgrep -a -u bigred -f '$SERVER_RE'" | cut -c1-80)"
else
  bad "no python -m jupyterlab within 40s"
fi
if wait_for 60 'lab_loaded && title_bar kiosk-c1 :95'; then
  shot kiosk-c1 :95 kiosk && pass "screenshot test/e2e/out/kiosk.png" || bad "kiosk screenshot failed"
else
  shot kiosk-c1 :95 kiosk
  bad "JupyterLab not on screen within 60s (see test/e2e/out/kiosk.png)"
fi

say token
pid=$(server_pids)
procs=$(podman exec --user nobody "$SERVER" ps -eo args)
if ! grep -Eq "$SERVER_RE" <<<"$procs"; then
  bad "nobody cannot see the jupyterlab server, so the check below would prove nothing"
elif grep -q ServerApp.token <<<"$procs"; then
  bad "ps as nobody shows ServerApp.token"
else
  pass "ps -eo args as nobody has no ServerApp.token"
fi
[ -n "$pid" ] && pxu "tr '\0' '\n' </proc/$pid/environ | grep -q '^JUPYTER_TOKEN=.'" \
  && pass "server $pid has JUPYTER_TOKEN in its environ" || bad "no JUPYTER_TOKEN in the environ of server '$pid'"

say limits
lim=$([ -n "$pid" ] && px "grep '^Max data size' /proc/$pid/limits")
read -r soft hard <<<"$(awk '{print $4, $5}' <<<"$lim")"
[ "${soft:-}" = 2147483648 ] && [ "${hard:-}" = 2147483648 ] \
  && pass "Max data size soft $soft hard $hard" || bad "Max data size: '$lim'"

say reconnect
r0=$(reconnects)
client_rm kiosk-c1
login reconnect-c2 :96
if wait_for 60 '[ "$(reconnects)" -gt "$r0" ]'; then
  [ "$(xorg_count)" -eq 1 ] && pass "client 2 reattached, still one Xorg" || bad "Xorg count $(xorg_count) after reconnect"
  [ -n "$pid" ] && [ "$(server_pids)" = "$pid" ] \
    && pass "jupyterlab server PID unchanged ($pid)" || bad "server PID '$(server_pids)', before '$pid'"
else
  bad "client 2 did not reattach within 60s (Xorg count $(xorg_count))"
fi

say other-bpp-reattaches
# xrdp 0.10.1 fixes Xorg sessions at 24 bpp (libipm/scp.c), so a 16 bpp client
# reattaches to the same desktop instead of opening a second one
r0=$(reconnects)
login other-bpp-reattaches-c3 :97 16
if wait_for 60 '[ "$(reconnects)" -gt "$r0" ]'; then
  [ "$(xorg_count)" -eq 1 ] && pass "bpp=16 client reattached, still one Xorg" || bad "Xorg count $(xorg_count) with a bpp=16 client"
  [ -n "$pid" ] && [ "$(server_pids)" = "$pid" ] \
    && pass "jupyterlab server PID unchanged ($pid)" || bad "server PID '$(server_pids)', before '$pid'"
else
  bad "bpp=16 client did not reattach within 60s (Xorg count $(xorg_count))"
fi
if wait_for 30 'title_bar other-bpp-reattaches-c3 :97'; then
  shot other-bpp-reattaches-c3 :97 other-bpp-reattaches && pass "screenshot test/e2e/out/other-bpp-reattaches.png" || bad "client 3 screenshot failed"
else
  shot other-bpp-reattaches-c3 :97 other-bpp-reattaches
  bad "JupyterLab not on client 3's screen within 30s"
fi

say locale-kept
want='{"locale":"en"}'
pxu "mkdir -p \"\$(dirname $LOCALE_FILE)\" && printf %s '$want' > $LOCALE_FILE"
close_all || bad "desktops still running after closing them"
mark
login locale-kept-c4 :98
wait_for 60 '[ -n "$(server_pids)" ] && lab_loaded && title_bar locale-kept-c4 :98' \
  || bad "JupyterLab not up within 60s after logging in again"
shot locale-kept-c4 :98 locale-kept
got=$(pxu "cat $LOCALE_FILE")
[ "$got" = "$want" ] && pass "user locale setting unchanged: $got" || bad "user locale setting is now: $got"
ov=$(px "python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"@jupyterlab/translation-extension:plugin\"][\"locale\"])' $OVERRIDES")
[ "$ov" = zh_TW ] && pass "overrides.json locale is still zh_TW" || bad "overrides.json locale: '$ov'"

say failed-notice
close_all || bad "desktops still running after closing them"
px 'echo "session test" > /opt/jupyter/extra/FAILED'
login failed-notice-c5 :99
wait_for 30 'px "pgrep -u bigred -x xmessage" >/dev/null' \
  && pass "xmessage shown within 30s" || bad "no xmessage within 30s"
wait_for 20 'title_bar failed-notice-c5 :99' || true
shot failed-notice-c5 :99 failed-notice
px 'rm -f /opt/jupyter/extra/FAILED'

say close
close_all || bad "desktops still running after closing them"
mark
login close-c6 :94
if wait_for 60 '[ -n "$(server_pids)" ] && lab_loaded && title_bar close-c6 :94'; then
  d=$(xorg_displays)
  shot close-c6 :94 close-before
  podman exec "$P-close-c6" sh -c 'DISPLAY=:94 xdotool mousemove 1260 15 click 1'
  wait_for 10 '! px "pgrep -u bigred -x Xorg -a" | grep -q " :$d " && ! px "test -e /tmp/sess/$d.1000"' \
    && pass "closing the window ended display :$d and removed /tmp/sess/$d.1000" \
    || bad "display :$d still there 10s after clicking close (Xorg: $(xorg_count), sess: $(px 'ls /tmp/sess'))"
else
  shot close-c6 :94 close-before
  bad "JupyterLab not on screen within 60s, nothing to close"
fi

say timeout
# xorgxrdp, not sesman, kills a disconnected desktop: module/rdpClientCon.c clamps
# the timeout to at least 60 s and checks every 10 s, so 60 s + 10 s + slack
close_all >/dev/null
if server_start -e DISCONNECTED_TIMEOUT=60; then
  login timeout-c7 :93
  if wait_for 60 '[ -n "$(server_pids)" ]'; then
    client_rm timeout-c7
    t0=$SECONDS
    wait_for 80 '[ "$(xorg_count)" -eq 0 ] && [ -z "$(server_pids)" ]' \
      && pass "Xorg and the jupyterlab server gone $((SECONDS - t0))s after disconnecting (limit 80s)" \
      || bad "after 80s: Xorg count $(xorg_count), servers '$(server_pids)'"
  else
    bad "no jupyterlab server within 60s with DISCONNECTED_TIMEOUT=60"
  fi
else
  bad "server with DISCONNECTED_TIMEOUT=60 did not start listening"
fi

finish
