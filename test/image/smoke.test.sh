#!/usr/bin/env bash
# Smoke tests for the built image: bash test/image/smoke.test.sh [image]
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts expand inside the container
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
MAX_SIZE=1200000000
VENV=/opt/jupyter/venv
SITE=$VENV/lib/python3.13/site-packages

# run [podman run options...] <script>: run a bash script in a throwaway container
run() {
  local script=${*: -1}
  podman run --rm "${@:1:$#-1}" --entrypoint bash "$IMG" -c "$script"
}

say image
if ! size=$(podman image inspect --format '{{.Size}}' "$IMG" 2>/dev/null); then
  bad "image $IMG not found"
  finish
fi
[ "$size" -le "$MAX_SIZE" ] \
  && pass "image size $size <= $MAX_SIZE" || bad "image size $size > $MAX_SIZE"

say jupyterlab-desktop
run '[ ! -e /opt/JupyterLab/resources/env_installer ]' \
  && pass "env_installer removed" || bad "env_installer still present"
paks=$(run 'cd /opt/JupyterLab/locales && ls | sort | tr "\n" " "')
[ "$paks" = "en-US.pak zh-TW.pak " ] \
  && pass "locales: $paks" || bad "locales: $paks"
run '[ -s /usr/share/doc/jupyterlab-desktop/LICENSES.chromium.html ] && [ ! -e /opt/JupyterLab/LICENSES.chromium.html ]' \
  && pass "LICENSES.chromium.html moved to /usr/share/doc" || bad "LICENSES.chromium.html not moved"
# Lists the files in app.asar that contain the old token argument, and whether
# server.js has the JUPYTER_TOKEN line (proof the patch ran). The asar also
# ships upstream's TypeScript sources (src/**/*.ts); they are never executed,
# token-env.sh leaves them alone, so they are skipped here.
ASAR_CHECK='
import json, struct, sys
f = open("/opt/JupyterLab/resources/app.asar", "rb")
_, header_size, _, json_len = struct.unpack("<4I", f.read(16))
tree = json.loads(f.read(json_len))
base = 8 + header_size
def walk(node, path):
    for name, entry in node["files"].items():
        p = path + name
        if "files" in entry:
            yield from walk(entry, p + "/")
        elif not entry.get("unpacked"):
            f.seek(base + int(entry["offset"]))
            yield p, f.read(entry["size"])
hits, patched = [], False
for p, data in walk(tree, ""):
    if p == "build/out/main/server.js":
        patched = b"JUPYTER_TOKEN: this._info.token," in data
    if b"ServerApp.token=\"{token}\"" in data and not (p.startswith("src/") and p.endswith(".ts")):
        hits.append(p)
print("patched=%s" % patched)
print("hits=%s" % " ".join(hits))
'
asar=$(podman run --rm -i --entrypoint python3 "$IMG" -I - <<<"$ASAR_CHECK" 2>&1)
case $asar in
  *"patched=True"*) pass "app.asar server.js passes JUPYTER_TOKEN in the env" ;;
  *) bad "app.asar lacks the JUPYTER_TOKEN patch: $asar" ;;
esac
hits=$(printf '%s\n' "$asar" | sed -n 's/^hits=//p')
case $asar in
  *"hits="*) [ -z "$hits" ] \
      && pass "extracted app.asar has no ServerApp.token=\"{token}\" (src/*.ts skipped)" \
      || bad "ServerApp.token=\"{token}\" still in: $hits" ;;
  *) bad "app.asar check failed: $asar" ;;
esac
run '! ldd /opt/JupyterLab/jupyterlab-desktop | grep "not found"' \
  && pass "jupyterlab-desktop has all its shared libraries" || bad "jupyterlab-desktop is missing shared libraries"
# Electron needs a display platform even for --version; headless ozone has none
ver=$(run 'HOME=/tmp timeout 60 jupyterlab-desktop --no-sandbox --ozone-platform=headless --version 2>/dev/null')
case $ver in
  *4.6.3*) pass "jupyterlab-desktop --version: $ver" ;;
  *) bad "jupyterlab-desktop --version: '$ver'" ;;
esac
run '[ "$(stat -c %U /opt/JupyterLab)" = root ] && ! su -s /bin/sh nobody -c "touch /opt/JupyterLab/x" 2>/dev/null' \
  && pass "/opt/JupyterLab is root-owned and read-only for users" || bad "/opt/JupyterLab writable by users"

say venv
out=$(run --user 65534 "$VENV/bin/python -c 'import jupyterlab, pandas, matplotlib; print(jupyterlab.__version__)'" 2>/dev/null)
case $out in
  4.6.*) pass "imports as UID 65534, jupyterlab $out" ;;
  *) bad "imports as UID 65534: $out" ;;
esac
run --user 65534 "touch $VENV/x || touch $SITE/x || mkdir $SITE/evil" 2>/dev/null \
  && bad "UID 65534 can write to the venv" || pass "UID 65534 cannot write to the venv"
pth=$(run "cat $SITE/rdp-jupyter-extra.pth")
[ "$pth" = /opt/jupyter/extra/current ] \
  && pass ".pth is /opt/jupyter/extra/current" || bad ".pth is '$pth'"
last=$(run "tail -n 1 $VENV/bin/activate")
[ "$last" = '. /opt/rdp-jupyter/server-env.sh' ] \
  && pass "activate ends with server-env.sh" || bad "activate last line: '$last'"
run '[ "$(stat -c %U:%a /opt/jupyter/extra)" = root:755 ]' \
  && pass "/opt/jupyter/extra is root:755" || bad "/opt/jupyter/extra owner/mode wrong"
run "$VENV/bin/python -I -c 'import nbclient, pip'" \
  && pass "nbclient and pip are in the venv" || bad "nbclient or pip missing from the venv"

say install-extra-inputs
# constraints.txt is requirements.lock without hashes and comments
want=$(grep -E '^[A-Za-z0-9]' images/rdp-jupyter/requirements.lock | sed 's/ .*//' | sort)
got=$(run 'cat /opt/jupyter/constraints.txt' | sort)
[ -n "$want" ] && [ "$want" = "$got" ] \
  && pass "constraints.txt matches requirements.lock" || bad "constraints.txt differs from requirements.lock"
v=$(run 'cat /opt/rdp-jupyter/VERSION')
[ "$v" = "$(cat VERSION)" ] && pass "VERSION is $v" || bad "VERSION is '$v'"
run 'uv --version' >/dev/null && pass "uv is installed" || bad "uv missing"
run 'for f in entrypoint accounts session-env install-extra notify-extra desktop-settings lab-overrides sesman-config; do
       [ -x /opt/rdp-jupyter/$f.sh ] || exit 1
     done
     [ -x /etc/xrdp/startwm.sh ] && [ -r /opt/rdp-jupyter/server-env.sh ] && [ -s /etc/skel/.config/openbox/rc.xml ]' \
  && pass "scripts are in place and executable" || bad "scripts missing or not executable"
run 'command -v xmessage && command -v pkill && command -v tini' >/dev/null \
  && pass "xmessage, pkill and tini are installed" || bad "xmessage, pkill or tini missing"
run 'locale -a | grep -qi "^zh_TW.utf8$"' \
  && pass "zh_TW.UTF-8 locale generated" || bad "zh_TW.UTF-8 locale missing"
run 'grep -qx "rdpdr=false" /etc/xrdp/xrdp.ini && [ ! -e /etc/xrdp/key.pem ] && [ ! -e /etc/xrdp/rsakeys.ini ]' \
  && pass "xrdp: drive redirection off, no baked keys" || bad "xrdp.ini or baked keys wrong"

finish
