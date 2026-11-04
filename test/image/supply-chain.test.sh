#!/usr/bin/env bash
# Supply-chain checks on the built image: bash test/image/supply-chain.test.sh [image]
# Generates an SBOM with syft and runs a trivy vulnerability scan, both from
# PINNED podman images (no host install, like test/deploy/lint.test.sh). The
# image is scanned from a reproducible `podman save` archive, not the podman
# socket. Evidence is written to test/e2e/out/ (gitignored): sbom.spdx.json and
# trivy.txt. trivy downloads its vulnerability DB over the network on first run
# and caches it outside the repo.
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh

IMG=${1:-localhost/rdp-jupyter:dev}
SYFT_IMAGE=docker.io/anchore/syft:v1.56.0
TRIVY_IMAGE=docker.io/aquasec/trivy:0.76.1
# The three packages the SBOM must prove are present (Python app, data stack, RDP).
WANT_PKGS="jupyterlab pandas xrdp"

OUT=$PWD/test/e2e/out
SBOM=$OUT/sbom.spdx.json
TRIVY_TXT=$OUT/trivy.txt
# trivy's vuln DB lives outside the repo so it survives between runs; override
# with TRIVY_CACHE_DIR. The scan archive is scratch, removed on exit.
TRIVY_CACHE=${TRIVY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/rdp-jupyter-trivy}

command -v podman >/dev/null 2>&1 || { bad "podman not found"; finish; }
podman image exists "$IMG" || { bad "image $IMG not found"; finish; }
mkdir -p "$OUT" "$TRIVY_CACHE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TAR=$TMP/image.tar

say save
# Reproducible input: scan the saved archive, not the live podman store.
if podman save "$IMG" -o "$TAR" 2>"$TMP/save.err"; then
  pass "podman save $IMG -> archive ($(stat -c %s "$TAR") bytes)"
else
  bad "podman save failed: $(tail -2 "$TMP/save.err")"
  finish
fi

say sbom
# syft reads the docker-archive and writes SPDX JSON to stdout.
if podman run --rm -v "$TAR:/image.tar:ro" "$SYFT_IMAGE" \
     docker-archive:/image.tar -o spdx-json >"$SBOM" 2>"$TMP/syft.err"; then
  pass "syft produced $SBOM ($(stat -c %s "$SBOM") bytes)"
else
  bad "syft failed: $(tail -3 "$TMP/syft.err")"
  finish
fi
[ -s "$SBOM" ] && pass "SBOM is non-empty" || bad "SBOM is empty"
for p in $WANT_PKGS; do
  # SPDX package entries are {"name":"<pkg>",...}; tolerate optional whitespace.
  if grep -Eq "\"name\": *\"$p\"" "$SBOM"; then
    pass "SBOM contains package: $p"
  else
    bad "SBOM is missing package: $p"
  fi
done

say trivy
# Exact scan contract: HIGH,CRITICAL only, fail on any un-ignored finding, honour
# .trivyignore. FATAL on stderr (e.g. a failed vuln-DB download) is a concern, not
# a clean pass, so it is reported separately from "findings present".
TRIVY_ERR=$TMP/trivy.err
podman run --rm \
  -v "$TAR:/image.tar:ro" \
  -v "$PWD/.trivyignore:/.trivyignore:ro" \
  -v "$TRIVY_CACHE:/root/.cache/trivy:Z" \
  "$TRIVY_IMAGE" image --input /image.tar \
  --severity HIGH,CRITICAL --exit-code 1 --ignorefile /.trivyignore \
  >"$TRIVY_TXT" 2>"$TRIVY_ERR"
rc=$?
if grep -q 'FATAL' "$TRIVY_ERR"; then
  bad "trivy error (e.g. vuln DB download) - not a clean pass: $(grep FATAL "$TRIVY_ERR" | head -1)"
elif [ "$rc" -eq 0 ]; then
  pass "trivy: no un-ignored HIGH/CRITICAL (see test/e2e/out/trivy.txt)"
elif [ "$rc" -eq 1 ]; then
  bad "trivy found un-ignored HIGH/CRITICAL (see test/e2e/out/trivy.txt): $(grep -E '^Total:' "$TRIVY_TXT" | tail -1)"
else
  bad "trivy exited $rc: $(tail -2 "$TRIVY_ERR")"
fi

finish
