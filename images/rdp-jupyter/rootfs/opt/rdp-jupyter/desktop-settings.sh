#!/usr/bin/env bash
# Print the JupyterLab Desktop settings.json for one desktop session (spec §5).
# startwm.sh runs: desktop-settings.sh "$HOME" > $S/xdg/jupyterlab-desktop/settings.json
# Values reach python through argv, never through its source, so a path is written
# literally. The numbers go through int(), so a bad value fails here instead of
# splitting serverArgs into extra arguments.
set -eu

home=${1:?usage: desktop-settings.sh <home>}
cull=${KERNEL_CULL_IDLE_TIMEOUT:-3600}
mem_kb=${KERNEL_MEMORY_LIMIT_KB:-2097152}

python3 -I -c '
import json, sys

home, cull, mem_kb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
server_args = " ".join([
    "--MappingKernelManager.cull_idle_timeout=%d" % cull,
    "--MappingKernelManager.cull_interval=300",
    "--ResourceUseDisplay.mem_limit=%d" % (mem_kb * 1024),
])
settings = {
    "pythonPath": "/opt/jupyter/venv/bin/python",
    "startupMode": "new-local-session",
    "checkForUpdatesAutomatically": False,
    "installUpdatesAutomatically": False,
    "notifyOnBundledEnvUpdates": False,
    "showNewsFeed": False,
    "defaultWorkingDirectory": home,
    "serverArgs": server_args,
}
json.dump(settings, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
' "$home" "$cull" "$mem_kb"
