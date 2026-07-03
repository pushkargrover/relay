#!/bin/sh
# trigger.sh - context-handoff plugin (mac/Linux launcher).
# Finds a Python 3 interpreter and hands stdin straight to trigger.py.
# If none exists, exits 0 silently: a monitoring hook must never block the user.

# On Windows, PowerShell owns this hook (hooks.json registers both commands;
# the wrong one no-ops per OS). Bail out under Git Bash / MSYS / Cygwin so the
# handoff never double-fires.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    exec python3 "$DIR/trigger.py"
fi

# Some systems only have 'python' - accept it if it is Python 3.
if command -v python >/dev/null 2>&1; then
    if python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        exec python "$DIR/trigger.py"
    fi
fi

exit 0
