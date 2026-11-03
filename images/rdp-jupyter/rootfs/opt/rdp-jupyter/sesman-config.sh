#!/usr/bin/env bash
# Set xrdp's sesman.ini for this container: a reconnect gets the same desktop
# back (Policy=Default) and a disconnected desktop is killed after the timeout.
# Usage: sesman-config.sh <sesman.ini> <max_sessions> <disconnected_timeout>
# Runs on every container start; the file persists across restarts, so the
# edit must be idempotent. Values are validated by entrypoint.sh first.
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: sesman-config.sh <sesman.ini> <max_sessions> <disconnected_timeout>" >&2
  exit 1
fi
ini=$1
max_sessions=$2
disconnected=$3

if [ ! -f "$ini" ]; then
  echo "[sesman-config] no such file: $ini" >&2
  exit 1
fi

# Check every key before editing, so a file missing one is left as it was
for key in Policy KillDisconnected DisconnectedTimeLimit MaxSessions; do
  if ! grep -q "^$key=" "$ini"; then
    echo "[sesman-config] missing $key in $ini" >&2
    exit 1
  fi
done

# ^ anchors each key to the line start, so commented ;Key= and #... lines are left alone
sed -i \
  -e 's/^Policy=.*/Policy=Default/' \
  -e 's/^KillDisconnected=.*/KillDisconnected=true/' \
  -e "s/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=$disconnected/" \
  -e "s/^MaxSessions=.*/MaxSessions=$max_sessions/" \
  "$ini"
