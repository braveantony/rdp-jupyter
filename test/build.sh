#!/usr/bin/env bash
# Build the image: bash test/build.sh [tag]   (default localhost/rdp-jupyter:dev)
# The build context is images/rdp-jupyter; the repo's VERSION file sits outside
# it, so its content is passed as the RDP_JUPYTER_VERSION build arg and the
# Dockerfile writes it to /opt/rdp-jupyter/VERSION (the build fails without it).
set -eu
cd "$(dirname "$0")/.."
tag=${1:-localhost/rdp-jupyter:dev}
version=$(tr -d '[:space:]' <VERSION)
podman build --build-arg "RDP_JUPYTER_VERSION=$version" -t "$tag" images/rdp-jupyter
