#!/usr/bin/env bash
# Stop JupyterLab Desktop from putting the server token on the command line.
# Usage: token-env.sh <extracted-app.asar-dir>
#
# Two edits, each applied only if its original text occurs exactly once:
#   build/out/main/config/settings.js  drop the --ServerApp.token="{token}" argument
#   build/out/main/server.js           pass the token as JUPYTER_TOKEN in the server env
# Both files are validated first and edited as temp copies; they are moved into
# place only after every edit succeeded, so a failure leaves both untouched.
set -eu

die() { printf '[token-env] %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: token-env.sh <extracted-asar-dir>"
dir=$1
settings=$dir/build/out/main/config/settings.js
server=$dir/build/out/main/server.js
[ -f "$settings" ] || die "missing file: $settings"
[ -f "$server" ] || die "missing file: $server"

# shellcheck disable=SC2016  # literal JS text, no expansion wanted
settings_pat='`--ServerApp.token="{token}"`,'
# shellcheck disable=SC2016
server_pat='JUPYTERLAB_WORKSPACES_DIR: process.env.JLAB_DESKTOP_WORKSPACES_DIR || jlabWorkspacesDir,'
server_new='JUPYTER_TOKEN: this._info.token,'

check_once() { # <pattern> <file>
  n=$(grep -cF -- "$1" "$2" || true)
  [ "$n" -eq 1 ] || die "expected exactly one match for $1 in $2 (found $n)"
}
check_once "$settings_pat" "$settings"
check_once "$server_pat" "$server"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -p "$settings" "$tmp/settings.js"
cp -p "$server" "$tmp/server.js"

# Fixed-string edit of the whole line that holds the pattern. python3 -I is
# used because the strings contain backticks, braces and quotes.
python3 -I - "$tmp/settings.js" "$settings_pat" "$tmp/server.js" "$server_pat" "$server_new" <<'PY'
import sys
settings, spat, server, vpat, vnew = sys.argv[1:6]

def lines(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read().splitlines(keepends=True)

def write(path, ls):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("".join(ls))

ls = lines(settings)
hit = [i for i, l in enumerate(ls) if l.strip() == spat]
if len(hit) != 1:
    sys.exit("settings.js: expected one whole-line match, found %d" % len(hit))
del ls[hit[0]]
write(settings, ls)

ls = lines(server)
hit = [i for i, l in enumerate(ls) if l.strip() == vpat]
if len(hit) != 1:
    sys.exit("server.js: expected one whole-line match, found %d" % len(hit))
old = ls[hit[0]]
indent = old[: len(old) - len(old.lstrip())]
eol = old[len(old.rstrip("\r\n")):] or "\n"
if not old.endswith(("\n", "\r")):
    ls[hit[0]] = old + eol
ls.insert(hit[0] + 1, indent + vnew + eol)
write(server, ls)
PY

# Every edit succeeded: move both into place.
mv "$tmp/settings.js" "$settings"
mv "$tmp/server.js" "$server"
printf '[token-env] patched %s and %s\n' "$settings" "$server"
