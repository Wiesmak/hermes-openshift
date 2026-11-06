#!/bin/sh
set -eu

# Initialize only the operator's long-running gateway. CLI commands such as
# --version and explicitly selected profiles retain upstream's normal behavior.
if [ "${1:-}" = gateway ] && [ "${2:-}" = run ]; then
    umask 077
    export HOME="$HERMES_HOME"
    test -w "$HERMES_HOME" || {
        echo "Hermes cannot write $HERMES_HOME as UID $(id -u)" >&2
        exit 1
    }
    export XDG_RUNTIME_DIR
    XDG_RUNTIME_DIR="$(mktemp -d /tmp/hermes-runtime.XXXXXXXX)"
    if [ ! -e "$HERMES_HOME/SOUL.md" ] && [ ! -L "$HERMES_HOME/SOUL.md" ]; then
        cp -n /opt/hermes/docker/SOUL.md "$HERMES_HOME/SOUL.md"
    fi
    if [ -n "${API_SERVER_KEY:-}" ] && [ -f "$HERMES_HOME/.env" ]; then
        "$HERMES_PYTHON" - <<'PY'
import os
from pathlib import Path

from hermes_cli.env_loader import _parse_dotenv_file

for key, value in _parse_dotenv_file(Path(os.environ["HERMES_HOME"]) / ".env"):
    if key == "API_SERVER_KEY" and value is not None:
        raise SystemExit("Remove API_SERVER_KEY from the PVC .env; it can override the operator Secret")
PY
    fi
    "$HERMES_PYTHON" /opt/hermes/tools/skills_sync.py ||
        echo "Warning: bundled skills synchronization failed" >&2

    # Web UI profile selection can persist in active_profile. The one host
    # gateway must stay rooted at the default profile for multiplexing.
    set -- --profile default "$@"
fi

exec /opt/hermes/.venv/bin/hermes "$@"
