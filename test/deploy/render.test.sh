#!/usr/bin/env bash
# Render every kustomize overlay and check it: bash test/deploy/render.test.sh
# Needs kubectl (with a reachable cluster for the server-side dry run) and PyYAML.
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# check <overlay> <python expression over docs>: docs is the list of rendered objects
check() {
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kind = lambda k: [d for d in docs if d["kind"] == k]
dep = (kind("Deployment") or [{}])[0]
pod = dep.get("spec", {}).get("template", {}).get("spec", {})
ctr = (pod.get("containers") or [{}])[0]
mounts = {m["mountPath"]: m for m in ctr.get("volumeMounts", [])}
vols = {v["name"]: v for v in pod.get("volumes", [])}
vol_at = lambda p: vols.get(mounts.get(p, {}).get("name"), {})
env = {e["name"]: e.get("value") for e in ctr.get("env", [])}
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$TMP/$1.yaml" "$2"
}
expect() {  # expect <overlay> <description> <python expression>
  check "$1" "$3" && pass "$1: $2" || bad "$1: $2"
}

for o in stateless stateful example/requirements; do
  name=${o//\//-}
  if kubectl kustomize "manifests/$o" > "$TMP/$name.yaml" 2>"$TMP/$name.err"; then
    pass "$o renders"
  else
    bad "$o does not render: $(head -3 "$TMP/$name.err")"; continue
  fi
  expect "$name" "all namespaced objects in rdp-jupyter" \
    'all(d["metadata"].get("namespace") == "rdp-jupyter" for d in docs if d["kind"] != "Namespace") and kind("Namespace")[0]["metadata"]["name"] == "rdp-jupyter"'
  expect "$name" "NodePort 30391" 'kind("Service")[0]["spec"]["ports"][0]["nodePort"] == 30391'
  expect "$name" "limits 4 / 8Gi" 'ctr["resources"]["limits"] == {"cpu": "4", "memory": "8Gi"}'
  expect "$name" "requests 1 / 2Gi" 'ctr["resources"]["requests"] == {"cpu": "1", "memory": "2Gi"}'
  expect "$name" "/dev/shm is a 1Gi Memory emptyDir" 'vol_at("/dev/shm").get("emptyDir") == {"medium": "Memory", "sizeLimit": "1Gi"}'
  expect "$name" "image is ghcr.io/braveantony/rdp-jupyter:0.1" \
    'ctr["image"] == "ghcr.io/braveantony/rdp-jupyter:" + open("VERSION").read().strip()'
  expect "$name" "named port rdp maps to containerPort 3389" \
    'ctr["ports"][0]["name"] == "rdp" and ctr["ports"][0]["containerPort"] == 3389'
  expect "$name" "users Secret at /etc/rdp-jupyter/users, defaultMode 0400" \
    'vol_at("/etc/rdp-jupyter/users")["secret"]["secretName"].startswith("rdp-jupyter-users") and vol_at("/etc/rdp-jupyter/users")["secret"]["defaultMode"] == 256 and mounts["/etc/rdp-jupyter/users"]["subPath"] == "users" and any(s["metadata"]["name"].startswith("rdp-jupyter-users") and "users" in s["data"] for s in kind("Secret"))'
  expect "$name" "optional requirements ConfigMap at /etc/rdp-jupyter/requirements" \
    'vol_at("/etc/rdp-jupyter/requirements")["configMap"]["name"].startswith("rdp-jupyter-requirements") and vol_at("/etc/rdp-jupyter/requirements")["configMap"]["optional"] is True'
  expect "$name" "postStart runs install-extra.sh" \
    'ctr["lifecycle"]["postStart"]["exec"]["command"] == ["/opt/rdp-jupyter/install-extra.sh"]'
  expect "$name" "allowPrivilegeEscalation false" \
    'ctr["securityContext"]["allowPrivilegeEscalation"] is False'
  expect "$name" "readiness and liveness via TCP 3389" \
    'ctr["readinessProbe"]["tcpSocket"]["port"] in ("rdp", 3389) and ctr["livenessProbe"]["tcpSocket"]["port"] in ("rdp", 3389)'
  expect "$name" "env defaults" \
    'env == {"USERS_FILE": "/etc/rdp-jupyter/users", "MAX_SESSIONS": "3", "DISCONNECTED_TIMEOUT": "28800", "KERNEL_MEMORY_LIMIT": "2Gi", "KERNEL_THREADS": "2", "KERNEL_CULL_IDLE_TIMEOUT": "3600", "JUPYTER_LOCALE": "zh-tw", "PIP_INDEX_URL": "", "INSTALL_TIMEOUT": "900"}'
  expect "$name" "strategy Recreate" 'dep["spec"]["strategy"]["type"] == "Recreate"'
done

expect stateless "/home is an emptyDir" '"emptyDir" in vol_at("/home")'
expect stateless "/opt/jupyter/extra is an emptyDir" '"emptyDir" in vol_at("/opt/jupyter/extra")'
expect stateless "no PVC" 'not kind("PersistentVolumeClaim")'
expect stateful "/home is PVC rdp-jupyter-home" 'vol_at("/home")["persistentVolumeClaim"]["claimName"] == "rdp-jupyter-home"'
expect stateful "/opt/jupyter/extra is PVC rdp-jupyter-extra" 'vol_at("/opt/jupyter/extra")["persistentVolumeClaim"]["claimName"] == "rdp-jupyter-extra"'
expect stateful "home PVC 10Gi RWO without storageClassName" \
  '[p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-home"][0]["spec"]["resources"]["requests"]["storage"] == "10Gi" and [p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-home"][0]["spec"]["accessModes"] == ["ReadWriteOnce"] and "storageClassName" not in [p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-home"][0]["spec"]'
expect stateful "extra PVC 5Gi RWO without storageClassName" \
  '[p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-extra"][0]["spec"]["resources"]["requests"]["storage"] == "5Gi" and [p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-extra"][0]["spec"]["accessModes"] == ["ReadWriteOnce"] and "storageClassName" not in [p for p in kind("PersistentVolumeClaim") if p["metadata"]["name"] == "rdp-jupyter-extra"][0]["spec"]'
expect example-requirements "generated hash-suffixed ConfigMap rdp-jupyter-requirements-<hash> with key requirements.txt" \
  'any(__import__("re").fullmatch(r"rdp-jupyter-requirements-[a-z0-9]{8,}", c["metadata"]["name"]) and "requirements.txt" in c["data"] for c in kind("ConfigMap"))'
expect example-requirements "Deployment references the exact generated ConfigMap name" \
  'vol_at("/etc/rdp-jupyter/requirements")["configMap"]["name"] in [c["metadata"]["name"] for c in kind("ConfigMap") if __import__("re").fullmatch(r"rdp-jupyter-requirements-[a-z0-9]{8,}", c["metadata"]["name"])]'
expect example-requirements "/home is an emptyDir (built on stateless)" '"emptyDir" in vol_at("/home")'

for o in stateless stateful; do
  grep -q '^# .*password' "manifests/$o/users.txt" 2>/dev/null && pass "$o users.txt warns to change the password" || bad "$o users.txt has no password warning"
done

say server-dry-run
# The rdp-jupyter namespace may not exist yet, and a dry run never creates it,
# so validate the objects in the existing "default" namespace instead. The
# nodePort is dropped (checked above) so a running deployment does not clash.
for o in stateless stateful example-requirements; do
  [ -f "$TMP/$o.yaml" ] || { bad "dry-run $o: nothing rendered"; continue; }
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] != "Namespace"]
for d in docs:
    d["metadata"]["namespace"] = "default"
    for port in d.get("spec", {}).get("ports", []) if d["kind"] == "Service" else []:
        port.pop("nodePort", None)
yaml.safe_dump_all(docs, sys.stdout)
' "$TMP/$o.yaml" > "$TMP/$o.default.yaml"
  out=$(kubectl apply --dry-run=server -f "$TMP/$o.default.yaml" 2>&1) && pass "dry-run $o" || bad "dry-run $o: $(tail -2 <<<"$out")"
done

finish
