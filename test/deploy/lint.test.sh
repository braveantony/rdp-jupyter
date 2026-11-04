#!/usr/bin/env bash
# Lint every kustomize overlay: bash test/deploy/lint.test.sh
# Runs kubeconform and kube-linter from PINNED podman images (no host install),
# then a server-side dry run into a throwaway namespace that enforces the
# Pod Security "baseline" profile. Needs podman, kubectl and a reachable cluster.
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh

KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.6.7
KUBE_LINTER_IMAGE=docker.io/stackrox/kube-linter:v0.7.1
K8S_VERSION=1.37.1
OVERLAYS="stateless stateful example/requirements"

command -v podman >/dev/null 2>&1 || { bad "podman not found"; finish; }
command -v kubectl >/dev/null 2>&1 || { bad "kubectl not found"; finish; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp .kube-linter.yaml "$TMP/.kube-linter.yaml"

say render
declare -A RENDERED=()
for o in $OVERLAYS; do
  name=${o//\//-}
  if kubectl kustomize "manifests/$o" > "$TMP/$name.yaml" 2>"$TMP/$name.err"; then
    pass "$o renders"
    RENDERED[$name]=1
  else
    bad "$o does not render: $(head -3 "$TMP/$name.err")"
  fi
done

say kubeconform
# -strict rejects unknown/duplicate fields; every object here is a core type.
for o in $OVERLAYS; do
  name=${o//\//-}
  [ -n "${RENDERED[$name]:-}" ] || { bad "kubeconform $o: not rendered"; continue; }
  out=$(podman run --rm -i "$KUBECONFORM_IMAGE" \
          -strict -summary -kubernetes-version "$K8S_VERSION" - \
          < "$TMP/$name.yaml" 2>&1) \
    && pass "kubeconform $o" \
    || bad "kubeconform $o: $out"
done

say kube-linter
# Exceptions (with reasons) live in .kube-linter.yaml; findings must be empty.
for o in $OVERLAYS; do
  name=${o//\//-}
  [ -n "${RENDERED[$name]:-}" ] || { bad "kube-linter $o: not rendered"; continue; }
  out=$(podman run --rm -v "$TMP:/data:ro" "$KUBE_LINTER_IMAGE" \
          lint --config /data/.kube-linter.yaml "/data/$name.yaml" 2>&1) \
    && pass "kube-linter $o" \
    || bad "kube-linter $o: $out"
done

say pod-security-baseline-dry-run
if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  bad "no reachable cluster for --dry-run=server (cannot verify Pod Security baseline)"
  finish
fi
ns="rdp-jupyter-lint-$$-${RANDOM}"
kubectl create namespace "$ns" >/dev/null 2>&1 \
  && kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=baseline >/dev/null 2>&1 \
  || { bad "cannot create throwaway namespace $ns"; finish; }
trap 'kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1; rm -rf "$TMP"' EXIT

for o in $OVERLAYS; do
  name=${o//\//-}
  [ -n "${RENDERED[$name]:-}" ] || { bad "dry-run $o: not rendered"; continue; }
  # Re-home objects into the labelled namespace and drop the nodePort so a
  # running deployment elsewhere cannot clash during the dry run.
  python3 -c '
import sys, yaml
ns = sys.argv[2]
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] != "Namespace"]
for d in docs:
    d["metadata"]["namespace"] = ns
    if d["kind"] == "Service":
        for port in d.get("spec", {}).get("ports", []):
            port.pop("nodePort", None)
yaml.safe_dump_all(docs, sys.stdout)
' "$TMP/$name.yaml" "$ns" > "$TMP/$name.psa.yaml"
  out=$(kubectl apply --dry-run=server -n "$ns" -f "$TMP/$name.psa.yaml" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -qiE 'warning|violat|forbidden|denied' <<<"$out"; then
    pass "baseline dry-run $o (no warnings or rejections)"
  else
    bad "baseline dry-run $o: $(tail -4 <<<"$out")"
  fi
done

finish
