# rdp-jupyter: JupyterLab Desktop over RDP (xrdp kiosk) in a Kubernetes Pod.
# Build with test/build.sh: it passes RDP_JUPYTER_VERSION from the repo's VERSION
# file, which is outside this build context.

# Base images are pinned by digest (multi-arch index); the tag is for humans.
FROM ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490 AS uv

# ---------------------------------------------------------------------------
# builder: unpack and patch JupyterLab Desktop, build the locked venv
# ---------------------------------------------------------------------------
FROM docker.io/library/debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS builder

ARG JLD_VERSION=4.6.3-1
ARG JLD_SHA256=447210fe8128ab4fa2d792aec31fbb8e080c4abdacd74f87666146fd4131378a
# The last @electron/asar release that runs on Debian's nodejs 20 (4.x needs node 22)
ARG ASAR_VERSION=3.4.1

# python3 here and in the final stage is the same Debian package, so the venv's
# bin/python symlink (/usr/bin/python3.13) resolves after the copy.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl python3 nodejs npm \
 && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /usr/local/bin/uv

# JupyterLab Desktop from the official release, verified by SHA-256. Dropped:
# the bundled conda environment (env_installer, ~305 MB; the image brings its
# own venv) and every Chromium locale except en-US and zh-TW. The Chromium
# license file moves to /usr/share/doc, gzipped (19.5 MB -> ~2 MB).
RUN curl -fsSLo /tmp/jlab.deb \
      "https://github.com/jupyterlab/jupyterlab-desktop/releases/download/v${JLD_VERSION}/JupyterLab-Setup-Debian-x64.deb" \
 && echo "${JLD_SHA256}  /tmp/jlab.deb" | sha256sum -c - \
 && dpkg-deb -x /tmp/jlab.deb /tmp/deb \
 && mv /tmp/deb/opt/JupyterLab /opt/JupyterLab \
 && rm -rf /tmp/jlab.deb /tmp/deb /opt/JupyterLab/resources/env_installer \
 && find /opt/JupyterLab/locales -name '*.pak' ! -name en-US.pak ! -name zh-TW.pak -delete \
 && install -d /usr/share/doc/jupyterlab-desktop \
 && mv /opt/JupyterLab/LICENSES.chromium.html /usr/share/doc/jupyterlab-desktop/ \
 && gzip -9n /usr/share/doc/jupyterlab-desktop/LICENSES.chromium.html

# Token patch (spec section 6, D5): the server token goes through the
# environment instead of the command line. token-env.sh fails the build if
# upstream code no longer matches. Upstream's TypeScript sources (src/), tests
# and .eslintcache ride along in the asar but are never loaded (runtime code
# and assets live under build/); they are dropped so no unpatched copy of the
# token argument remains.
COPY patches/token-env.sh /tmp/token-env.sh
RUN cd /opt/JupyterLab/resources \
 && npx --yes "@electron/asar@${ASAR_VERSION}" extract app.asar /tmp/app \
 && bash /tmp/token-env.sh /tmp/app \
 && rm -rf /tmp/app/src /tmp/app/test /tmp/app/.eslintcache \
 && npx --yes "@electron/asar@${ASAR_VERSION}" pack /tmp/app app.asar \
 && rm -rf /tmp/app /tmp/token-env.sh /root/.npm

# The venv: Debian's python3 plus the hash-locked requirements. No python3-*
# Debian packages are installed, so --system-site-packages adds nothing but
# lets users `pip install --user` (spec section 8).
ENV UV_PYTHON_DOWNLOADS=never UV_NO_CACHE=1 UV_LINK_MODE=copy
COPY requirements.lock /tmp/requirements.lock
RUN uv venv --python /usr/bin/python3 --system-site-packages /opt/jupyter/venv \
 && uv pip sync --python /opt/jupyter/venv/bin/python --require-hashes /tmp/requirements.lock \
 && site=/opt/jupyter/venv/lib/python3.13/site-packages \
 && find "$site" -depth -type d \( -name tests -o -name test \) -exec rm -rf {} + \
 && /opt/jupyter/venv/bin/python -m compileall -q -j 0 "$site" \
 && printf '%s\n' /opt/jupyter/extra/current > "$site/rdp-jupyter-extra.pth" \
 && printf '\n%s\n' '. /opt/rdp-jupyter/server-env.sh' >> /opt/jupyter/venv/bin/activate \
 && grep -E '^[A-Za-z0-9]' /tmp/requirements.lock | sed 's/ .*//' > /opt/jupyter/constraints.txt \
 && install -d -m 755 /opt/jupyter/extra \
 && chmod -R go-w /opt/jupyter /opt/JupyterLab

# ---------------------------------------------------------------------------
# final
# ---------------------------------------------------------------------------
FROM docker.io/library/debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

LABEL org.opencontainers.image.source="https://github.com/braveantony/rdp-jupyter" \
      org.opencontainers.image.description="Full-screen JupyterLab Desktop over RDP, running in Kubernetes" \
      org.opencontainers.image.licenses="Apache-2.0"

# xrdp + xorgxrdp: every RDP login gets its own Xorg (xrdpdev driver), no VNC.
# xauth is only a Recommends, but without it sesman cannot write the session's
# MIT cookie and Xorg runs with no access control.
# x11-utils: xmessage for notify-extra.sh. procps: pkill for startwm.sh.
# The second group is the Depends of the JupyterLab Desktop .deb, plus
# libasound2t64, which the Electron binary links but the .deb does not declare.
#
# Size (spec section 9, docs/spike-notes.md section 6):
# - dpkg skips Noto Serif CJK (only Sans is used) and docs other than copyright
#   (the slim base already excludes those; repeated here so it stays true)
# - Xorg's libgbm1/libegl-mesa0/libglx-mesa0 hard-depend on mesa-libgallium,
#   which pulls libllvm19 and libz3-4 (~196 MB). Nothing here renders with
#   Mesa: no /dev/dri in the pod, xorgxrdp draws in software and Electron runs
#   with --disable-gpu. Those and the Mesa EGL/GLX vendor libraries are removed
#   with --force-depends; what still references them (libgbm's dri backend,
#   Xorg's glamor and glx modules) only dlopens them and falls back to software.
#   Consequence: apt sees broken dependencies in the final image, so never
#   apt-get install on top of it (build a new image instead).
# - locale-gen runs here, and the locale sources (/usr/share/i18n) go once the
#   archive is built. C.UTF-8 is built in; startwm.sh picks zh_TW.UTF-8 or
#   C.UTF-8 per JUPYTER_LOCALE.
RUN printf '%s\n' \
      'path-exclude=/usr/share/fonts/opentype/noto/NotoSerifCJK*' \
      'path-exclude=/usr/share/doc/*' \
      'path-include=/usr/share/doc/*/copyright' \
      > /etc/dpkg/dpkg.cfg.d/rdp-jupyter-excludes \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xrdp xorgxrdp xauth openbox dbus-x11 x11-utils procps \
      fonts-noto-cjk fonts-dejavu-core locales tini openssl ca-certificates python3 \
      libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 \
      libuuid1 libsecret-1-0 libasound2t64 \
 && dpkg --purge --force-depends libgl1-mesa-dri mesa-libgallium libllvm19 libz3-4 \
      libegl-mesa0 libglx-mesa0 \
 && sed -i 's/^# *zh_TW.UTF-8 UTF-8/zh_TW.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /usr/share/i18n /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    TZ=Asia/Taipei

# xrdp.ini: keep only the Xorg session type; no drive redirection (D9: no RDP
#           file transfer, no FUSE) and no sound
# sesman.ini: no root login. Policy, MaxSessions and the disconnect keys keep
#             Debian's defaults; sesman-config.sh rewrites them at startup.
# Keys and certs are generated at startup, never baked into the image.
RUN sed -i '/^\[Xvnc\]/,$d' /etc/xrdp/xrdp.ini \
 && sed -i -e 's/^rdpdr=true/rdpdr=false/' \
           -e 's/^rdpsnd=true/rdpsnd=false/' /etc/xrdp/xrdp.ini \
 && grep -qx 'rdpdr=false' /etc/xrdp/xrdp.ini \
 && sed -i 's/^AllowRootLogin=true/AllowRootLogin=false/' /etc/xrdp/sesman.ini \
 && rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem /etc/xrdp/rsakeys.ini

COPY --from=uv /uv /usr/local/bin/uv
COPY --from=builder /usr/share/doc/jupyterlab-desktop /usr/share/doc/jupyterlab-desktop
COPY --from=builder /opt/JupyterLab /opt/JupyterLab
COPY --from=builder /opt/jupyter /opt/jupyter
RUN ln -s /opt/JupyterLab/jupyterlab-desktop /usr/bin/jupyterlab-desktop

COPY --chmod=755 rootfs/opt/rdp-jupyter/ /opt/rdp-jupyter/
COPY --chmod=755 rootfs/etc/xrdp/startwm.sh /etc/xrdp/startwm.sh
# Kiosk window rules, root-owned so users cannot edit kiosk mode away;
# startwm.sh passes it to openbox with --config-file
COPY --chmod=644 rootfs/etc/rdp-jupyter/openbox-rc.xml /etc/rdp-jupyter/openbox-rc.xml

ARG RDP_JUPYTER_VERSION
RUN test -n "${RDP_JUPYTER_VERSION}" \
 && printf '%s\n' "${RDP_JUPYTER_VERSION}" > /opt/rdp-jupyter/VERSION \
 && chmod 644 /opt/rdp-jupyter/VERSION /opt/rdp-jupyter/server-env.sh

EXPOSE 3389

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/rdp-jupyter/entrypoint.sh"]
