#!/usr/bin/env bash
# Runs test/image/fixtures/smoke.ipynb in the image with the kernel memory limit
# from session.env: bash test/image/notebook.test.sh [image]
# nbclient comes from the image's venv (jupyter-server -> nbconvert -> nbclient),
# so nothing extra is installed for the test.
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts expand inside the container
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}

if ! podman image exists "$IMG"; then
  bad "image $IMG not found"
  finish
fi

# As root, write session.env the way entrypoint.sh does; then, as UID 65534,
# source the venv's activate (which applies server-env.sh) and execute the
# notebook. Prints one line per check: <name>=<value>.
out=$(podman run --rm -e KERNEL_MEMORY_LIMIT=1Gi \
  -v "$PWD/test/image/fixtures/smoke.ipynb:/fixtures/smoke.ipynb:ro" \
  --entrypoint bash "$IMG" -c '
  set -e
  install -d -m 755 /run/rdp-jupyter
  /opt/rdp-jupyter/session-env.sh > /run/rdp-jupyter/session.env
  chmod 644 /run/rdp-jupyter/session.env
  install -d -o 65534 -g 65534 /tmp/nb
  cp /fixtures/smoke.ipynb /tmp/nb/
  exec setpriv --reuid 65534 --regid 65534 --clear-groups env -i HOME=/tmp/nb PATH=/usr/bin:/bin bash -c "
    cd /tmp/nb
    . /opt/jupyter/venv/bin/activate
    echo limit_kb=\$(ulimit -d)
    python -I - <<\"PY\"
import nbformat
from nbclient import NotebookClient

nb = nbformat.read(\"smoke.ipynb\", as_version=4)
NotebookClient(nb, timeout=300, kernel_name=\"python3\", allow_errors=True).execute()

def stream(cell):
    return \"\".join(o.get(\"text\", \"\") for o in cell.outputs if o.output_type == \"stream\").strip()

errors = [o for o in nb.cells[1].outputs if o.output_type == \"error\"]
print(\"cell1_out=\" + stream(nb.cells[0]))
print(\"cell2_ename=\" + (errors[0].ename if errors else \"none\"))
print(\"cell3_out=\" + stream(nb.cells[2]))
PY
    [ -s smoke.png ] && echo png=yes || echo png=no
  "
' 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/  | /'
[ "$rc" -eq 0 ] && pass "notebook ran (rc=0)" || bad "notebook run failed (rc=$rc)"

get() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -n 1; }
[ "$(get limit_kb)" = 1048576 ] && pass "activate set the 1Gi data limit" || bad "data limit is '$(get limit_kb)'"
[ "$(get cell1_out)" = 3 ] && [ "$(get png)" = yes ] \
  && pass "cell 1: DataFrame and PNG" || bad "cell 1: out='$(get cell1_out)' png='$(get png)'"
[ "$(get cell2_ename)" = MemoryError ] \
  && pass "cell 2: MemoryError" || bad "cell 2: ename='$(get cell2_ename)'"
[ "$(get cell3_out)" = alive ] \
  && pass "cell 3: kernel still alive" || bad "cell 3: out='$(get cell3_out)'"

finish
