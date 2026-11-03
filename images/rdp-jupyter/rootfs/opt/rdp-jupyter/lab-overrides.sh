#!/usr/bin/env bash
# Print JupyterLab's overrides.json: the default UI locale (spec §5 語系), and
# no "notified about official Jupyter news?" prompt (fetchNews is a string enum
# "true"/"false"/"none" in apputils-extension's notification schema).
# entrypoint.sh runs: lab-overrides.sh > /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json
# JUPYTER_LOCALE is already normalized to zh_TW or en by session-env.sh. It reaches python through argv.
set -eu

locale=${JUPYTER_LOCALE:-zh_TW}

python3 -I -c '
import json, sys

overrides = {
    "@jupyterlab/translation-extension:plugin": {"locale": sys.argv[1]},
    "@jupyterlab/apputils-extension:notification": {"fetchNews": "false"},
}
json.dump(overrides, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
' "$locale"
