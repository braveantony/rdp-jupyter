#!/usr/bin/env bash
# Run by launcher.pl as the requesting account, with DISPLAY and XAUTHORITY
# set: start JupyterLab Desktop the way a session does, minus the desktop itself.
export RDP_ATTACHED=1
exec /etc/xrdp/startwm.sh
