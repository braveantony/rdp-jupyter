#!/usr/bin/env bash
# Tests for install.sh without a cluster: bash test/unit/install.test.sh
# A fake kubectl renders what install.sh applies with the real `kubectl kustomize`
# and answers the read-only queries; manifests come from this checkout (file://).
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts run later
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
REAL_KUBECTL=$(command -v kubectl) || { bad "kubectl not found"; finish; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$TMP/calls"
case "\$*" in
  version*) exit 0 ;;
  "apply -k "*) "$REAL_KUBECTL" kustomize "\$3" > "$TMP/applied.yaml" ;;
  *"get deploy rdp-jupyter"*) echo rdp-jupyter-users-abc ;;
  *"get secret -o name"*) printf 'secret/rdp-jupyter-users-abc\nsecret/rdp-jupyter-users-old\n' ;;
  *"get svc rdp-jupyter"*) echo 30391 ;;
  "get nodes"*) echo "10.0.0.1 10.0.0.2 " ;;
esac
FAKE
chmod +x "$TMP/bin/kubectl"

check() {  # check <description> <python expression over docs>
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
kind = lambda k: [d for d in docs if d["kind"] == k]
ctr = kind("Deployment")[0]["spec"]["template"]["spec"]["containers"][0]
vols = {v["name"]: v for v in kind("Deployment")[0]["spec"]["template"]["spec"]["volumes"]}
mounts = {m["mountPath"]: m["name"] for m in ctr["volumeMounts"]}
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$TMP/applied.yaml" "$2" && pass "$1" || bad "$1"
}
install() { PATH="$TMP/bin:$PATH" RDP_JUPYTER_RAW="file://$PWD" "$@" bash install.sh; }

say quick-start
rm -f "$TMP/calls" "$TMP/applied.yaml"
out=$(install env 2>&1); rc=$?
[ "$rc" = 0 ] && pass "install.sh exits 0" || bad "install.sh rc=$rc: $out"
check "namespace rdp-jupyter" 'all(d["metadata"].get("namespace") == "rdp-jupyter" for d in docs if d["kind"] != "Namespace")'
check "users Secret holds bigred:bigred" '__import__("base64").b64decode(kind("Secret")[0]["data"]["users"]).decode().strip() == "bigred:bigred"'
check "/home is an emptyDir" '"emptyDir" in vols[mounts["/home"]]'
check "/opt/jupyter/extra is an emptyDir" '"emptyDir" in vols[mounts["/opt/jupyter/extra"]]'
check "/dev/shm is a Memory emptyDir" 'vols[mounts["/dev/shm"]]["emptyDir"]["medium"] == "Memory"'
check "image from manifests/base" 'ctr["image"] == "ghcr.io/braveantony/rdp-jupyter:" + open("VERSION").read().strip()'
grep -q "delete secret/rdp-jupyter-users-old" "$TMP/calls" && pass "old users Secret deleted" || bad "old Secret not deleted"
grep -q "delete secret/rdp-jupyter-users-abc" "$TMP/calls" && bad "current Secret deleted" || pass "current Secret kept"
grep -qF "10.0.0.1:30391" <<<"$out" && grep -qF "10.0.0.2:30391" <<<"$out" && pass "prints node addresses" || bad "no node addresses in: $out"

say image-override
for spec in "localhost/rdp-jupyter:dev|localhost/rdp-jupyter:dev" "registry.local:5000/rdp-jupyter|registry.local:5000/rdp-jupyter:VERSIONTAG"; do
  img=${spec%%|*} want=${spec#*|}
  want=${want/VERSIONTAG/$(cat VERSION)}
  install env RDP_JUPYTER_IMAGE="$img" >/dev/null 2>&1
  check "RDP_JUPYTER_IMAGE=$img -> $want" "ctr[\"image\"] == \"$want\""
done

say no-cluster
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
out=$(install env 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q "cannot reach a cluster" <<<"$out" && pass "fails clearly without a cluster" || bad "no-cluster: rc=$rc $out"

finish
