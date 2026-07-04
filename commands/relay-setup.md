---
description: One-time setup that installs a short 'relay-recover' terminal command, so lockout recovery is a single word instead of a long script path.
allowed-tools: [Bash, PowerShell, Glob]
---

# /relay-setup Command

Install the `relay-recover` shortcut into the user's shell profile, so that after a lockout they can just type `relay-recover` in any terminal (no long path, and it auto-resolves the latest installed version).

## Instructions

1. **Locate the setup script** in this plugin's `scripts/` directory. Prefer `${CLAUDE_PLUGIN_ROOT}/scripts/`. If unavailable, glob: `~/.claude/plugins/cache/grove-plugins/relay/*/scripts/setup.*`

2. **Run the OS-appropriate one:**
   - Windows: `powershell -NoProfile -File "<path>\setup.ps1"`
   - macOS/Linux: `sh "<path>/setup.sh"`

3. **Relay the script's output** to the user, including the reminder to **reopen their terminal** (or re-source their profile) before the `relay-recover` command becomes available.

## After setup

The user can then run, in any terminal:
```
relay-recover --list     # or -List on PowerShell
relay-recover            # recover the most recent session
```

This is only needed once per machine. Recovery still requires Ollama installed (see the README / local mode).
