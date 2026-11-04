#!/bin/bash
# Run in the background by startwm.sh. If the admin package install failed
# (install-extra.sh left $EXTRA_DIR/FAILED), tell the user in a dialog.
# Always exits 0: a missing or failing xmessage must never affect the session.
set -u
EXTRA_DIR=${EXTRA_DIR:-/opt/jupyter/extra}

if [ -e "$EXTRA_DIR/FAILED" ]; then
  # The first line is user-facing UI copy (zh_TW with the English in brackets)
  msg=$(printf '額外套件安裝失敗（Extra packages failed to install）\n'; cat "$EXTRA_DIR/FAILED" 2>/dev/null)
  "${XMESSAGE:-xmessage}" -center "$msg" >/dev/null 2>&1 || true
fi
exit 0
