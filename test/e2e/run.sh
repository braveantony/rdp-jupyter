#!/usr/bin/env bash
# End-to-end acceptance on the real tk8s cluster (spec A7):
#   bash test/e2e/run.sh [stateless|requirements|stateful|pip-unreachable|kernel-limit|oom|all]
#
# Loads the local image onto every node with skopeo (the manifests reference
# ghcr.io/braveantony/rdp-jupyter:0.1 with imagePullPolicy IfNotPresent, so the
# on-node copy is used), deploys the Kustomize manifests from Task 12, logs in
# over RDP with the e2e client, and runs the six scenarios. Logs and screenshots
# go to test/e2e/out/. Every scenario must PASS except `oom`, which is
# record-only (its result is written by hand into docs/ops/).
#
# All kubectl calls are pinned to a context (E2E_CONTEXT, default
# kubernetes-admin@tk8s). Namespaces created: rdp-jupyter (redeployed per
# scenario) and rdp-jupyter-e2e-data (the PostgreSQL fixture). Each is labelled
# rdp-jupyter-e2e-owner=run-sh at creation, and reset_ns/cleanup delete ONLY
# namespaces carrying that label, so a real deployment under the same name is
# never wiped. Both are deleted on exit unless E2E_KEEP=1.
# shellcheck disable=SC1091,SC2015,SC2016,SC2086,SC2034  # pass() never fails; single-quoted scripts run in the pod; word-split is intended for env lists; vars used only inside eval'd conditions
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh

MODE=${1:-all}
IMG=localhost/rdp-jupyter:dev
REF=ghcr.io/braveantony/rdp-jupyter:0.1   # the tag the manifests expect on-node
CLIENT=localhost/rdp-jupyter-e2e-client:dev
NS=rdp-jupyter
DATA_NS=rdp-jupyter-e2e-data
PORT=33391
OUT=$PWD/test/e2e/out
WORK=$(mktemp -d)
NODES="tk8s-control-plane-1 tk8s-worker-1 tk8s-worker-2"
EXAMPLE_REQ=$PWD/manifests/example/requirements/requirements.txt
# Pin the kubectl context so nothing can run against the wrong cluster.
CONTEXT=${E2E_CONTEXT:-kubernetes-admin@tk8s}
# Label every namespace this harness creates, so cleanup only ever deletes its own.
OWNER_LABEL=rdp-jupyter-e2e-owner
OWNER_VALUE=run-sh
pf_pid=""
mkdir -p "$OUT"

kc() { kubectl --context "$CONTEXT" "$@"; }
k()  { kc -n "$NS" "$@"; }
kd() { kc -n "$DATA_NS" "$@"; }
# exec a command in the desktop pod as root
kx() { k exec deploy/rdp-jupyter -- bash -c "$1"; }

# own_ns <ns>: mark a namespace as created by this harness (idempotent)
own_ns() { kc label ns "$1" "$OWNER_LABEL=$OWNER_VALUE" --overwrite >/dev/null 2>&1; }
# ns_ours <ns>: succeed if the namespace is absent (safe to create) or carries
# our ownership label; fail if it exists without the label (someone else's).
ns_ours() {
  kc get ns "$1" >/dev/null 2>&1 || return 0
  [ "$(kc get ns "$1" -o jsonpath='{.metadata.labels.'"$OWNER_LABEL"'}' 2>/dev/null)" = "$OWNER_VALUE" ]
}
# del_owned_ns <ns> [wait]: delete a namespace only if it is absent or ours.
del_owned_ns() {
  if ns_ours "$1"; then
    kc delete ns "$1" --ignore-not-found --wait="${2:-true}" >/dev/null 2>&1
  else
    bad "refusing to delete namespace $1: no $OWNER_LABEL=$OWNER_VALUE label (not created by this harness)"
    return 1
  fi
}
# png_nontrivial <file>: a real PNG screenshot, not a blank/failed capture
png_nontrivial() {
  [ -s "$1" ] || return 1
  [ "$(head -c8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || return 1
  [ "$(stat -c %s "$1")" -ge 20000 ]
}
# wait_for <seconds> <bash condition>
wait_for() {
  local end=$((SECONDS + $1))
  while :; do
    eval "$2" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 2
  done
}
restart_count() { k get pod -l app=rdp-jupyter -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null; }
last_oom() { k get pod -l app=rdp-jupyter -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null; }

# put_file <local> <pod-path>: stream a local file into the pod (no tar/kubectl cp)
put_file() { k exec -i deploy/rdp-jupyter -- bash -c "cat > '$2'" < "$1"; }

# run_user_py <localpy> <name> [env assignments...]: run as uid 1000 under the
# venv (so server-env.sh applies the kernel RLIMIT), print its stdout. Prints a
# leading LIMIT_KB=<ulimit -d> line.
run_user_py() {
  local py=$1 name=$2; shift 2
  put_file "$py" "/tmp/$name.py" || return 1
  k exec deploy/rdp-jupyter -- bash -c "
    install -d -o 1000 -g 1000 /tmp/w-$name &&
    cp /tmp/$name.py /tmp/w-$name/run.py && chown 1000:1000 /tmp/w-$name/run.py &&
    exec setpriv --reuid 1000 --regid 1000 --clear-groups \
      env -i HOME=/home/bigred PATH=/opt/jupyter/venv/bin:/usr/bin:/bin $* bash -c '
        cd /tmp/w-$name
        . /opt/jupyter/venv/bin/activate
        echo LIMIT_KB=\$(ulimit -d)
        python -I run.py 2>&1
      '
  "
}

# pip_target <name> <dir> <packages...>: install packages into <dir> as bigred (needs egress)
pip_target() {
  local name=$1 dir=$2; shift 2
  k exec deploy/rdp-jupyter -- bash -c "
    install -d -o 1000 -g 1000 '$dir' &&
    exec setpriv --reuid 1000 --regid 1000 --clear-groups \
      env HOME=/home/bigred PATH=/opt/jupyter/venv/bin:/usr/bin:/bin \
      /opt/jupyter/venv/bin/python -m pip install --quiet --target '$dir' $*
  "
}

# --- RDP client / port-forward (ported from test/image/session.test.sh) ---
pf_stop()  { [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null; pf_pid=""; }
pf_start() {
  pf_stop
  k port-forward svc/rdp-jupyter "$PORT:3389" >"$WORK/pf.log" 2>&1 &
  pf_pid=$!
  wait_for 20 'nc -z 127.0.0.1 '"$PORT"' 2>/dev/null'
}
# login <name> <user> <display>: start an RDP client container that logs in and
# screenshots to test/e2e/out/<name>.png
login()     { podman run -d --name "e2e-$1" --network host -v "$OUT:/out:Z" \
                "$CLIENT" "127.0.0.1:$PORT" "$2" "$2" "$1" "$3" >/dev/null; }
client_rm() { podman rm -f -t 0 "e2e-$1" >/dev/null 2>&1; }
clients_rm_all() { podman ps -aq --filter 'name=^e2e-' | xargs -r podman rm -f -t 0 >/dev/null 2>&1; }
shot() { podman exec "e2e-$1" sh -c "xwd -display $2 -root -silent | magick xwd:- /out/$3.png" 2>/dev/null; }
xorg_count()   { kx 'pgrep -c -x Xorg || true'; }
server_count() { kx "pgrep -f '^python[0-9.]* -m jupyterlab( |\$)' | wc -l"; }

# --- deploy helpers ---------------------------------------------------------
reset_ns() {
  clients_rm_all; pf_stop
  del_owned_ns "$NS" true || return 1
}
wait_ready() {
  k rollout status deploy/rdp-jupyter --timeout=300s >/dev/null 2>&1 &&
    k wait --for=condition=Ready pod -l app=rdp-jupyter --timeout=180s >/dev/null 2>&1
}

# deploy_app <name> <emptydir|pvc> <users-text> [requirements-file]
deploy_app() {
  local name=$1 storage=$2 users=$3 req=${4:-}
  local d=$OUT/k-$name
  rm -rf "$d"; mkdir -p "$d"
  printf '%s\n' "$users" > "$d/users.txt"
  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "namespace: $NS"
    echo "resources:"
    echo "- ../../../../manifests/base"
    if [ "$storage" = pvc ]; then
      cp manifests/stateful/pvc.yaml "$d/pvc.yaml"
      cp manifests/stateful/volumes-pvc.yaml "$d/volumes.yaml"
      echo "- pvc.yaml"
    else
      cp manifests/stateless/volumes-emptydir.yaml "$d/volumes.yaml"
    fi
    echo "patches:"
    echo "- path: volumes.yaml"
    echo "secretGenerator:"
    echo "- name: rdp-jupyter-users"
    echo "  files:"
    echo "  - users=users.txt"
    if [ -n "$req" ]; then
      cp "$req" "$d/requirements.txt"
      echo "configMapGenerator:"
      echo "- name: rdp-jupyter-requirements"
      echo "  files:"
      echo "  - requirements.txt"
    fi
  } > "$d/kustomization.yaml"
  kc apply -k "$d" >"$WORK/apply-$name.log" 2>&1 && own_ns "$NS"
}

# ===========================================================================
scn_stateless() {
  say "stateless: deploy (3 accounts), login x3, pandas.read_sql against pg"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  deploy_app stateless emptydir $'alice:alice\nbob:bob\nbigred:bigred' || { bad "stateless: apply"; return; }
  wait_ready && pass "stateless: pod Ready" || { bad "stateless: pod not Ready"; k describe pod -l app=rdp-jupyter >"$OUT/stateless-describe.log" 2>&1; return; }
  pf_start || { bad "stateless: port-forward"; return; }

  login stateless-alice  alice  :95
  login stateless-bob    bob    :96
  login stateless-bigred bigred :97
  if wait_for 90 '[ "$(xorg_count)" -ge 3 ]'; then
    pass "stateless: 3 concurrent desktops (Xorg count $(xorg_count))"
  else
    bad "stateless: only $(xorg_count) Xorg after 90s"
  fi
  wait_for 90 '[ "$(server_count)" -ge 3 ]' \
    && pass "stateless: 3 jupyterlab servers running" || bad "stateless: only $(server_count) servers"
  sleep 10
  shot stateless-alice  :95 stateless-alice
  shot stateless-bob    :96 stateless-bob
  shot stateless-bigred :97 stateless-bigred
  local a=$OUT/stateless-alice.png b=$OUT/stateless-bob.png g=$OUT/stateless-bigred.png
  if png_nontrivial "$a" && png_nontrivial "$b" && png_nontrivial "$g"; then
    pass "stateless: 3 non-trivial desktop screenshots ($(stat -c %s "$a"),$(stat -c %s "$b"),$(stat -c %s "$g") bytes)"
  else
    bad "stateless: a desktop screenshot is missing/blank (alice=$(stat -c %s "$a" 2>/dev/null) bob=$(stat -c %s "$b" 2>/dev/null) bigred=$(stat -c %s "$g" 2>/dev/null))"
  fi

  say "stateless: pandas.read_sql over the cluster network"
  pip_target pg8000 /tmp/pglib pg8000 >"$OUT/stateless-pip.log" 2>&1 \
    && pass "stateless: pg8000 installed from PyPI (egress ok)" || { bad "stateless: could not install pg8000 (see stateless-pip.log)"; return; }
  # The driver runs under `python -I` (which ignores PYTHONPATH for itself), so
  # it must not import pg8000 at top level; the kernel spawned by nbclient does
  # honour PYTHONPATH=/tmp/pglib and imports it inside the cell.
  cat > "$WORK/read_sql.py" <<'PY'
import nbformat
from nbformat.v4 import new_notebook, new_code_cell
from nbclient import NotebookClient
src = (
    "import pandas as pd, pg8000\n"
    "conn = pg8000.connect(user='analyst', password='analyst',\n"
    "                      host='pg.rdp-jupyter-e2e-data', port=5432, database='analytics')\n"
    "df = pd.read_sql('SELECT id, city, temp_c FROM readings ORDER BY id', conn)\n"
    "print('ROWS=' + str(len(df)))\n"
    "print('CITIES=' + ','.join(df['city']))\n"
)
nb = new_notebook(cells=[new_code_cell(src)])
NotebookClient(nb, timeout=120, kernel_name='python3', allow_errors=True).execute()
for cell in nb.cells:
    for o in cell.outputs:
        if o.output_type == 'stream':
            print(o['text'], end='')
        elif o.output_type == 'error':
            print('ERR=' + o['ename'] + ': ' + ''.join(o.get('evalue', '')))
PY
  out=$(run_user_py "$WORK/read_sql.py" readsql PYTHONPATH=/tmp/pglib)
  printf '%s\n' "$out" | tee "$OUT/stateless-read_sql.log" | sed 's/^/  | /'
  [ "$(sed -n 's/^ROWS=//p' <<<"$out" | tail -1)" = 3 ] \
    && pass "stateless: pandas.read_sql returned 3 rows from pg" || bad "stateless: read_sql did not return 3 rows"
}

scn_requirements() {
  say "requirements: apply example/requirements, import the packages in a notebook"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  deploy_app requirements emptydir $'bigred:bigred' "$EXAMPLE_REQ" || { bad "requirements: apply"; return; }
  wait_ready && pass "requirements: pod Ready" || { bad "requirements: pod not Ready"; return; }
  # postStart installs into /opt/jupyter/extra; wait for the stamp
  wait_for 300 'kx "test -d /opt/jupyter/extra/current" 2>/dev/null' \
    && pass "requirements: install-extra populated /opt/jupyter/extra/current" \
    || { bad "requirements: extra/current never appeared"; k logs deploy/rdp-jupyter >"$OUT/requirements-logs.log" 2>&1; return; }
  k logs deploy/rdp-jupyter >"$OUT/requirements-logs.log" 2>&1
  grep -q 'install-extra.*installed (' "$OUT/requirements-logs.log" \
    && pass "requirements: postStart log shows 'installed'" || bad "requirements: no 'installed' line in logs"
  kx 'ls /opt/jupyter/extra/current' >"$OUT/requirements-extra-ls.log" 2>&1
  grep -q '^humanize$' "$OUT/requirements-extra-ls.log" \
    && pass "requirements: humanize delivered under extra/current" || bad "requirements: humanize not under extra/current"

  # humanize is NOT in the base image, so a successful import proves the extra
  # package was installed and is on sys.path; EXTRA_FILE proves the imported
  # module actually resolves under /opt/jupyter/extra (the .pth), not a base copy.
  cat > "$WORK/imp.py" <<'PY'
import nbformat
from nbformat.v4 import new_notebook, new_code_cell
from nbclient import NotebookClient
src = ("import humanize\n"
       "print('IMPORT_OK ' + humanize.__version__)\n"
       "print('EXTRA_FILE ' + humanize.__file__)\n")
nb = new_notebook(cells=[new_code_cell(src)])
NotebookClient(nb, timeout=120, kernel_name='python3', allow_errors=True).execute()
for cell in nb.cells:
    for o in cell.outputs:
        if o.output_type == 'stream':
            print(o['text'], end='')
        elif o.output_type == 'error':
            print('ERR=' + o['ename'] + ': ' + ''.join(o.get('evalue', '')))
PY
  out=$(run_user_py "$WORK/imp.py" imp)
  printf '%s\n' "$out" | tee "$OUT/requirements-import.log" | sed 's/^/  | /'
  grep -q '^IMPORT_OK ' <<<"$out" \
    && pass "requirements: notebook imported the extra package humanize" || bad "requirements: humanize import failed"
  case "$(sed -n 's/^EXTRA_FILE //p' <<<"$out" | tail -1)" in
    /opt/jupyter/extra/*) pass "requirements: imported humanize resolves under /opt/jupyter/extra (the extra copy, not base)" ;;
    *) bad "requirements: humanize.__file__ is not under /opt/jupyter/extra: '$(sed -n 's/^EXTRA_FILE //p' <<<"$out" | tail -1)'" ;;
  esac
}

scn_stateful() {
  say "stateful: write a file, delete the pod, file persists; postStart skips on unchanged requirements"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  deploy_app stateful pvc $'bigred:bigred' "$EXAMPLE_REQ" || { bad "stateful: apply"; return; }
  wait_ready && pass "stateful: pod Ready" || { bad "stateful: pod not Ready"; return; }
  wait_for 300 'kx "test -f /opt/jupyter/extra/.stamp" 2>/dev/null' \
    && pass "stateful: first postStart installed extra packages" || { bad "stateful: no .stamp after first install"; return; }

  # write a real notebook into the persistent home
  kx 'install -d -o 1000 -g 1000 /home/bigred/work && printf "%s" "{\"cells\":[],\"nbformat\":4,\"nbformat_minor\":5,\"metadata\":{}}" > /home/bigred/work/analysis.ipynb && chown 1000:1000 /home/bigred/work/analysis.ipynb && echo written' >/dev/null
  kx 'cat /home/bigred/work/analysis.ipynb' >"$OUT/stateful-before.ipynb" 2>&1

  say "stateful: delete the pod and wait for the Recreate rollout"
  local old_uid new_uid
  old_uid=$(k get pod -l app=rdp-jupyter -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)
  k delete pod -l app=rdp-jupyter --wait=true >/dev/null 2>&1
  # Wait until a Pod with a *different* UID exists, so wait_ready cannot match the
  # old terminating Pod, before confirming readiness.
  wait_for 180 'new_uid=$(k get pod -l app=rdp-jupyter -o jsonpath="{.items[0].metadata.uid}" 2>/dev/null); [ -n "$new_uid" ] && [ "$new_uid" != "'"$old_uid"'" ]' \
    || { bad "stateful: no genuinely-new Pod within 180s (old uid $old_uid)"; return; }
  wait_ready && pass "stateful: pod recreated (new uid) and Ready" || { bad "stateful: pod not Ready after delete"; return; }

  kx 'test -f /home/bigred/work/analysis.ipynb && cat /home/bigred/work/analysis.ipynb' >"$OUT/stateful-after.ipynb" 2>&1 \
    && pass "stateful: notebook file survived the pod recreation (PVC)" || bad "stateful: notebook file gone after recreation"

  # second postStart sees the unchanged requirements and the kept .stamp -> skip
  k logs deploy/rdp-jupyter >"$OUT/stateful-logs-after.log" 2>&1
  wait_for 120 'grep -q "install-extra.*up to date.*skipping" '"$OUT/stateful-logs-after.log"' || { k logs deploy/rdp-jupyter > '"$OUT/stateful-logs-after.log"' 2>&1; false; }' \
    && pass "stateful: postStart skipped install (up to date) on unchanged requirements" \
    || bad "stateful: no 'up to date ... skipping' in postStart log after recreation"
}

scn_pip_unreachable() {
  say "pip-unreachable: NetworkPolicy blocks egress; pod Ready; xmessage on login; pip error in logs"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  # Create the namespace and deny-all-egress BEFORE the deployment, so postStart's
  # pip install runs with egress already blocked.
  kc apply -f manifests/base/namespace.yaml >/dev/null 2>&1 && own_ns "$NS"
  cat > "$WORK/netpol.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress
  namespace: $NS
spec:
  podSelector:
    matchLabels:
      app: rdp-jupyter
  policyTypes:
  - Egress
  egress: []
EOF
  kc apply -f "$WORK/netpol.yaml" >/dev/null 2>&1 && pass "pip-unreachable: deny-egress NetworkPolicy applied" || { bad "pip-unreachable: could not apply NetworkPolicy"; return; }
  sleep 5   # let Cilium program the policy before the pod starts
  deploy_app pipblock emptydir $'bigred:bigred' "$EXAMPLE_REQ" || { bad "pip-unreachable: apply"; return; }
  wait_ready && pass "pip-unreachable: pod becomes Ready despite blocked egress" || { bad "pip-unreachable: pod not Ready"; return; }

  # postStart install should fail and leave the FAILED marker
  wait_for 180 'kx "test -e /opt/jupyter/extra/FAILED" 2>/dev/null' \
    && pass "pip-unreachable: install-extra left the FAILED marker" || bad "pip-unreachable: no FAILED marker"
  k logs deploy/rdp-jupyter >"$OUT/pip-unreachable-logs.log" 2>&1
  grep -q 'install-extra.*install FAILED' "$OUT/pip-unreachable-logs.log" \
    && pass "pip-unreachable: kubectl logs shows the pip failure" || bad "pip-unreachable: no 'install FAILED' in logs"

  pf_start || { bad "pip-unreachable: port-forward"; return; }
  login pipblock bigred :95
  wait_for 60 'kx "pgrep -u bigred -x xmessage >/dev/null" 2>/dev/null' \
    && pass "pip-unreachable: xmessage shown after login" || bad "pip-unreachable: no xmessage within 60s"
  sleep 5
  shot pipblock :95 pip-unreachable
  clients_rm_all; pf_stop
}

scn_kernel_limit() {
  say "kernel-limit: defaults (2Gi), allocate 3GB -> MemoryError, pod does NOT restart"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  deploy_app kernlimit emptydir $'bigred:bigred' || { bad "kernel-limit: apply"; return; }
  wait_ready && pass "kernel-limit: pod Ready" || { bad "kernel-limit: pod not Ready"; return; }
  local before; before=$(restart_count)

  cat > "$WORK/klimit.py" <<'PY'
import nbformat
from nbformat.v4 import new_notebook, new_code_cell
from nbclient import NotebookClient
# 3 GiB of float64 (> the 2Gi RLIMIT_DATA) must raise MemoryError, and the
# kernel must stay alive for the next cell.
c1 = "import numpy as np\nbig = np.ones(3 * 1024**3 // 8)\nprint('ALLOC_OK', big.sum())\n"
c2 = "print('ALIVE')\n"
nb = new_notebook(cells=[new_code_cell(c1), new_code_cell(c2)])
NotebookClient(nb, timeout=120, kernel_name='python3', allow_errors=True).execute()
def outs(cell, t):
    return [o for o in cell.outputs if o.output_type == t]
err = outs(nb.cells[0], 'error')
print('CELL1_ERR=' + (err[0].ename if err else 'none'))
print('CELL2=' + ''.join(o.get('text', '') for o in outs(nb.cells[1], 'stream')).strip())
PY
  out=$(run_user_py "$WORK/klimit.py" klimit)
  printf '%s\n' "$out" | tee "$OUT/kernel-limit.log" | sed 's/^/  | /'
  [ "$(sed -n 's/^LIMIT_KB=//p' <<<"$out" | tail -1)" = 2097152 ] \
    && pass "kernel-limit: kernel RLIMIT_DATA is 2Gi" || bad "kernel-limit: RLIMIT_DATA unexpected"
  [ "$(sed -n 's/^CELL1_ERR=//p' <<<"$out" | tail -1)" = MemoryError ] \
    && pass "kernel-limit: 3GB allocation raised MemoryError" || bad "kernel-limit: no MemoryError"
  [ "$(sed -n 's/^CELL2=//p' <<<"$out" | tail -1)" = ALIVE ] \
    && pass "kernel-limit: kernel still alive after MemoryError" || bad "kernel-limit: kernel not alive"
  sleep 5
  local after; after=$(restart_count)
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" = "$before" ]; then
    pass "kernel-limit: pod did not restart (count still $before)"
  else
    bad "kernel-limit: restart count check failed (before='$before' after='$after')"
  fi
}

scn_oom() {
  say "oom (RECORD-ONLY): KERNEL_MEMORY_LIMIT=6Gi, limits 4Gi, allocate 5GB"
  reset_ns || { bad "reset_ns refused (namespace not owned); aborting scenario"; return; }
  deploy_app oom emptydir $'bigred:bigred' || { bad "oom: apply"; return; }
  k set env deploy/rdp-jupyter KERNEL_MEMORY_LIMIT=6Gi >/dev/null 2>&1
  k set resources deploy/rdp-jupyter --limits=memory=4Gi --requests=memory=2Gi >/dev/null 2>&1
  wait_ready || { bad "oom: pod not Ready after reconfigure"; return; }

  local oomgroup memmax before node spok
  oomgroup=$(kx 'cat /sys/fs/cgroup/memory.oom.group 2>/dev/null' | tr -d '[:space:]')
  memmax=$(kx 'cat /sys/fs/cgroup/memory.max 2>/dev/null' | tr -d '[:space:]')
  before=$(restart_count)
  # Read the live kubelet config of the node the pod runs on, rather than guessing.
  node=$(k get pod -l app=rdp-jupyter -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  spok=$(kc get --raw "/api/v1/nodes/$node/proxy/configz" 2>/dev/null \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["kubeletconfig"].get("singleProcessOOMKill","<unset>"))' 2>/dev/null)
  [ -n "$spok" ] || spok="<unreadable>"
  {
    echo "node=$node"
    echo "memory.oom.group=$oomgroup"
    echo "memory.max=$memmax"
    echo "restartCount.before=$before"
    echo "kubelet.singleProcessOOMKill=$spok"
  } | tee "$OUT/oom-cgroup.log"

  # Allocate 5 GB in a detached process under the venv (RLIMIT_DATA=6Gi, so no
  # MemoryError; the 4Gi cgroup limit is what bites). Detached so the result is
  # not confounded by the exec connection being torn down.
  cat > "$WORK/oomalloc.py" <<'PY'
import numpy as np, time
x = np.ones(5 * 1024**3 // 8)   # 5 GiB, all pages touched
x[:] = 1.0
open('/tmp/oom-touched', 'w').write(str(x.sum()))
time.sleep(600)
PY
  put_file "$WORK/oomalloc.py" /tmp/oomalloc.py
  kx 'install -d -o 1000 -g 1000 /tmp/oomw && cp /tmp/oomalloc.py /tmp/oomw/a.py && chown 1000:1000 /tmp/oomw/a.py &&
      setpriv --reuid 1000 --regid 1000 --clear-groups env -i HOME=/home/bigred PATH=/opt/jupyter/venv/bin:/usr/bin:/bin \
        setsid bash -c "cd /tmp/oomw; . /opt/jupyter/venv/bin/activate; nohup python -I a.py >/tmp/oomw/out.log 2>&1 &"; echo launched' >/dev/null 2>&1

  # Observe for up to 90s
  local result="undetermined" after reason
  wait_for 90 '[ "$(restart_count)" != "'"$before"'" ] || kx "test -e /tmp/oom-touched" 2>/dev/null || ! kx "test -e /tmp/oomw/a.py" 2>/dev/null'
  sleep 3
  after=$(restart_count); reason=$(last_oom)
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    # A restart only counts as an OOM kill when the kubelet recorded OOMKilled;
    # any other restart reason is logged as-is, not misattributed to the OOM test.
    case $reason in
      *OOMKilled*) result="WHOLE_POD_KILLED (restartCount $before -> $after, lastState=$reason)" ;;
      *)           result="UNKNOWN_RESTART (restartCount $before -> $after, reason=${reason:-<none>})" ;;
    esac
  elif kx 'test -e /tmp/oom-touched' 2>/dev/null; then
    result="NO_OOM (5GB allocation completed; cgroup limit not enforced as expected)"
  else
    result="PROCESS_ONLY (pod alive at restartCount $after, allocator gone)"
  fi
  {
    echo "restartCount.after=$after"
    echo "lastState.reason=$reason"
    echo "RESULT=$result"
  } | tee -a "$OUT/oom-cgroup.log"
  k describe pod -l app=rdp-jupyter >"$OUT/oom-describe.log" 2>&1
  k get events --sort-by=.lastTimestamp >"$OUT/oom-events.log" 2>&1
  say "oom RESULT: $result  (memory.oom.group=$oomgroup) -- recorded, not pass/fail"
}

cleanup() {
  clients_rm_all; pf_stop
  if [ "${E2E_KEEP:-0}" != 1 ]; then
    del_owned_ns "$NS" false
    del_owned_ns "$DATA_NS" false
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- image load + fixtures --------------------------------------------------
load_image() {
  say "load image onto nodes ($REF)"
  podman build -q -t "$CLIENT" test/e2e/client >/dev/null || { bad "client build"; finish; }
  podman image exists "$IMG" || { bad "image $IMG not found (build it first)"; finish; }
  podman save -o "$WORK/img.tar" "$IMG" >/dev/null 2>&1 || { bad "podman save"; finish; }
  local n st
  for n in $NODES; do
    st=/var/lib/containers/storage/volumes/$n-var/_data/lib/containers/storage
    if sudo test -d "$st/overlay-images"; then
      sudo skopeo copy -q "docker-archive:$WORK/img.tar" \
        "containers-storage:[overlay@$st+/run/rdp-jupyter-load-$n]$REF" \
        && pass "image loaded into $n" || { bad "image load into $n"; finish; }
    else
      bad "no container storage on $n ($st)"; finish
    fi
  done
  rm -f "$WORK/img.tar"
}

# wait_ns_gone <ns>: block while a namespace is still Terminating from a previous
# run (cleanup deletes with --wait=false), so a fresh apply does not race it.
wait_ns_gone() {
  wait_for 120 '! kc get ns "'"$1"'" >/dev/null 2>&1'
}

deploy_fixture() {
  say "deploy PostgreSQL fixture ($DATA_NS)"
  ns_ours "$DATA_NS" || { bad "fixture: namespace $DATA_NS exists but is not owned by this harness; refusing to touch it"; finish; }
  wait_ns_gone "$DATA_NS"
  kc apply -f test/e2e/fixtures/postgres.yaml >/dev/null 2>&1 && own_ns "$DATA_NS" || { bad "fixture apply"; finish; }
  kd rollout status deploy/pg --timeout=300s >/dev/null 2>&1 \
    && kd wait --for=condition=Available deploy/pg --timeout=120s >/dev/null 2>&1 \
    && pass "PostgreSQL ready" || { bad "PostgreSQL not ready"; kd describe pod -l app=pg >"$OUT/pg-describe.log" 2>&1; finish; }
}

load_image
case $MODE in
  stateless)       deploy_fixture; scn_stateless ;;
  requirements)    scn_requirements ;;
  stateful)        scn_stateful ;;
  pip-unreachable) scn_pip_unreachable ;;
  kernel-limit)    scn_kernel_limit ;;
  oom)             scn_oom ;;
  all)
    deploy_fixture
    scn_stateless
    scn_requirements
    scn_stateful
    scn_pip_unreachable
    scn_kernel_limit
    scn_oom
    ;;
  *) echo "usage: run.sh [stateless|requirements|stateful|pip-unreachable|kernel-limit|oom|all]" >&2; exit 2 ;;
esac

finish
