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

finish
