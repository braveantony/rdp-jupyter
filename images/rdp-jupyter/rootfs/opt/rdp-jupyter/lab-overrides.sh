#!/usr/bin/env bash
# Print JupyterLab's overrides.json: the default UI locale (spec §5 語系), no
# "notified about official Jupyter news?" prompt (fetchNews is a string enum
# "true"/"false"/"none" in apputils-extension's notification schema), and no
# "a newer version of JupyterLab is available" toast (checkForUpdates, a boolean
# in the same schema; the front end checks it on its own, whatever fetchNews is).
# Upgrading the image is the admin's job; users cannot act on that toast.
# entrypoint.sh runs: lab-overrides.sh > /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json
# JUPYTER_LOCALE is already normalized to zh_TW or en by session-env.sh. It reaches python through argv.
set -eu

locale=${JUPYTER_LOCALE:-zh_TW}

python3 -I -c '
import json, sys

overrides = {
    "@jupyterlab/translation-extension:plugin": {"locale": sys.argv[1]},
    "@jupyterlab/apputils-extension:notification": {
        "fetchNews": "false",
        "checkForUpdates": False,
    },
}
json.dump(overrides, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
' "$locale"
