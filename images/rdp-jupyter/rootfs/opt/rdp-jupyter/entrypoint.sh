#!/usr/bin/env bash
# Started by tini as root: xrdp-sesman needs root for PAM and to switch to the
# login user. Ported from rdp-vscode without the ssh and font setup; sesman.ini
# is edited here at runtime (sesman-config.sh), not at build time.
set -eu

# MAX_SESSIONS: unset or empty means 3 silently; a set value that is not a
# positive integer warns on stderr and means 3. Leading zeros are normalized.
# The 12-digit cap keeps the arithmetic from overflowing; far above any real limit.
max_sessions=3
if [ -n "${MAX_SESSIONS:-}" ]; then
  if [ "${#MAX_SESSIONS}" -le 12 ] && [ -z "${MAX_SESSIONS//[0-9]/}" ] \
     && [ $((10#$MAX_SESSIONS)) -ge 1 ]; then
    max_sessions=$((10#$MAX_SESSIONS))
  else
    echo "[entrypoint] invalid MAX_SESSIONS: $MAX_SESSIONS" >&2
  fi
fi

users=$(/opt/rdp-jupyter/accounts.sh "${USERS_FILE:-/etc/rdp-jupyter/users}")
unset RDP_PASSWORD
echo "[entrypoint] accounts: $users"

# sesman starts sessions with a clean environment; startwm.sh and server-env.sh
# read this file. Sourcing it gives DISCONNECTED_TIMEOUT and the normalized JUPYTER_LOCALE.
install -d -m 755 /run/rdp-jupyter
/opt/rdp-jupyter/session-env.sh > /run/rdp-jupyter/session.env
chmod 644 /run/rdp-jupyter/session.env
# shellcheck disable=SC1091
. /run/rdp-jupyter/session.env

/opt/rdp-jupyter/sesman-config.sh /etc/xrdp/sesman.ini "$max_sessions" "$DISCONNECTED_TIMEOUT"

# JupyterLab's default UI locale; a user's own choice in the menu wins over it
install -d -m 755 /opt/jupyter/venv/share/jupyter/lab/settings
JUPYTER_LOCALE=$JUPYTER_LOCALE /opt/rdp-jupyter/lab-overrides.sh \
  > /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json
chmod 644 /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json

# Per-pod TLS certificate and RDP RSA keys (the Dockerfile removes the ones
# generated at build time); group xrdp may read them (the listener itself runs
# as root: Debian's xrdp 0.10.1 has no runtime_user)
cd /etc/xrdp
if [ ! -s key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)" \
    -keyout key.pem -out cert.pem 2>/dev/null
fi
[ -s rsakeys.ini ] || xrdp-keygen xrdp rsakeys.ini >/dev/null
chown root:xrdp key.pem cert.pem rsakeys.ini
chmod 640 key.pem cert.pem rsakeys.ini
cd /

rm -rf /run/xrdp/*.pid /var/run/xrdp/*.pid /tmp/.X*-lock /tmp/.X11-unix/X* /tmp/sess

# Per-session data lives under /tmp/sess (see startwm.sh); every account may
# create its own entries, the sticky bit keeps them from touching others'
install -d -m 1777 /tmp/sess

xrdp-sesman --nodaemon &
xrdp --nodaemon &

# Any daemon exiting stops the container so K8s restarts it
wait -n || true
echo "[entrypoint] a service exited, stopping container" >&2
exit 1
