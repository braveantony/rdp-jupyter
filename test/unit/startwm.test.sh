#!/usr/bin/env bash
# Tests for startwm.sh, run inside the image: bash test/unit/startwm.test.sh [image]
# Needs the built image (Task 9); it cannot run before that.
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts expand inside the container
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
run() { podman run --rm --entrypoint bash "$IMG" -c "$1"; }

say planted-session-dir
# alice pre-creates bob's session dir (display 10, uid 1001); bob's session
# must refuse it instead of running JupyterLab Desktop with a dir alice controls.
run 'printf "alice:a\nbob:b\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
     install -d -m 1777 /tmp/sess
     su alice -c "mkdir -m 777 /tmp/sess/10.1001"
     su bob -c "cd ~ && DISPLAY=:10 timeout 60 /etc/xrdp/startwm.sh" >/dev/null 2>&1 && exit 2
     [ ! -e /home/bob/.jupyter ] || exit 3' \
  && pass "session refuses a session dir it does not own" || bad "planted-session-dir (rc=$?)"

say kiosk-launch
# Stub openbox and JupyterLab Desktop record their arguments; a real session
# runs with XDG_CONFIG_HOME=$S/xdg, so openbox only gets the kiosk config if
# it is passed explicitly, and that file must be root-owned.
run 'printf "alice:a\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
     install -d -m 1777 /tmp/sess
     printf "#!/bin/sh\necho \"\$*\" >/tmp/openbox.args\nsleep 30\n" >/usr/local/bin/openbox
     printf "#!/bin/sh\necho \"\$*\" >/tmp/jlab.args\nsleep 2\n" >/opt/JupyterLab/jupyterlab-desktop
     chmod 755 /usr/local/bin/openbox /opt/JupyterLab/jupyterlab-desktop
     su alice -c "cd ~ && DISPLAY=:10 timeout 60 /etc/xrdp/startwm.sh" >/dev/null 2>&1
     sleep 1
     [ "$(cat /tmp/openbox.args)" = "--config-file /etc/rdp-jupyter/openbox-rc.xml" ] || exit 2
     [ "$(stat -c %U:%G:%a /etc/rdp-jupyter/openbox-rc.xml)" = root:root:644 ] || exit 3
     grep -q "<maximized>true</maximized>" /etc/rdp-jupyter/openbox-rc.xml || exit 4
     grep -q "<decor>no</decor>" /etc/rdp-jupyter/openbox-rc.xml || exit 5
     [ "$(cat /tmp/jlab.args)" = "--no-sandbox --disable-gpu" ] || exit 6' \
  && pass "openbox gets the root-owned kiosk config; JupyterLab Desktop gets --no-sandbox --disable-gpu" \
  || bad "kiosk-launch (rc=$?)"

say orphan-cleanup
# When Xorg goes away first (the disconnected timeout), JupyterLab Desktop dies
# without stopping the JupyterLab server it started. The stub starts a long-lived
# child (standing in for that server) and exits at once; once startwm.sh has
# returned, the child must be gone too.
run 'printf "alice:a\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
     install -d -m 1777 /tmp/sess
     printf "#!/bin/sh\nexit 0\n" >/usr/local/bin/openbox
     printf "#!/bin/sh\nsleep 300 &\necho \$! >/tmp/server.pid\nexit 133\n" >/opt/JupyterLab/jupyterlab-desktop
     chmod 755 /usr/local/bin/openbox /opt/JupyterLab/jupyterlab-desktop
     su alice -c "cd ~ && DISPLAY=:10 timeout 60 /etc/xrdp/startwm.sh" >/dev/null 2>&1
     pid=$(cat /tmp/server.pid) || exit 2
     for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 0.5; done
     exit 3' \
  && pass "a child left behind by JupyterLab Desktop is stopped with the session" \
  || bad "orphan-cleanup (rc=$?)"

finish
