#!/usr/bin/env bash
# Print JupyterLab's overrides.json: the default UI locale (spec §5 語系).
# entrypoint.sh runs: lab-overrides.sh > /opt/jupyter/venv/share/jupyter/lab/settings/overrides.json
# JUPYTER_LOCALE is already normalized to zh_TW or en by session-env.sh. It reaches python through argv.
set -eu

locale=${JUPYTER_LOCALE:-zh_TW}

python3 -I -c '
import json, sys

overrides = {"@jupyterlab/translation-extension:plugin": {"locale": sys.argv[1]}}
json.dump(overrides, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
' "$locale"
