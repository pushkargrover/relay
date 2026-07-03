# context-handoff

**Never lose your session progress again.** A Claude Code plugin that monitors your context usage live and automatically writes a structured handoff document at 90% — before compaction erases your work. The handoff is plain markdown any AI agent can resume from: Claude, Codex, Gemini, Copilot, anything.

## Install (2 commands, zero dependencies)

Inside Claude Code:

```
/plugin marketplace add pushkargrover/context-handoff
/plugin install context-handoff@grove-plugins
```

Restart Claude Code (hooks load at session start). Done — no npm, no pip, no runtime to install.

## What it does

- **Every turn**, a lightweight hook reads the *real* token counts from your session transcript (no estimation) and compares them to your model's context window.
- **At ≥90%**, it instructs Claude to write a complete handoff document — once per session — then your conversation continues normally.
- **If compaction ever arrives first**, a `PreCompact` backstop fires the same handoff.
- **On demand**: run `/handoff` any time.

## Where handoffs are saved

| Session type | Location |
|---|---|
| Inside a project | `<project-root>/handoffs/handoff-YYYY-MM-DD-HHMMSS.md` |
| No project (home-directory session) | `~/.claude/handoffs/handoff-YYYY-MM-DD-HHMMSS.md` |

## The handoff document

Eight sections, designed to be read by humans and ingested by any AI agent:

1. **Session Goal** — what was being accomplished
2. **Decisions Made** — choices with their rationale
3. **Work Completed** — files changed, commands run
4. **Current State** — what works right now
5. **Open Questions / Blockers**
6. **Next Steps** — ordered and concrete
7. **Key File Paths** — read these first when resuming
8. **Instructions for Next Agent** — conventions and warnings

Resume in any agent with one line:

```
Read handoffs/handoff-2026-07-03-143022.md and continue the work described there.
```

## Configuration

Change the threshold (default 0.90) via environment variable, e.g. in `settings.json`:

```json
{ "env": { "CONTEXT_HANDOFF_THRESHOLD": "0.80" } }
```

Extend model context limits in `scripts/context-limits.json` (longest model-ID prefix wins; `_default` covers unknown models conservatively).

## How it works (for the curious)

Claude Code writes each session as a JSONL transcript where every assistant message records exact token usage. On each `UserPromptSubmit`, a tiny script (PowerShell on Windows, sh + Python 3 on mac/Linux — both already on your machine) tails that file, sums `input + cache_read + cache_creation` tokens from the newest record, and divides by the model's context limit. At the threshold it emits `additionalContext` telling Claude to write the handoff. The script only *detects* — Claude does the *synthesizing*, because only the model can explain its own decisions and next steps.

Design principles:
- **The monitor never breaks the session it monitors** — every failure path exits 0 silently.
- **Fires exactly once per session** — a lockfile keyed by session ID.
- **Zero dependencies** — no daemon, no runtime, nothing to keep running.

## Platform support

| Platform | Status |
|---|---|
| Windows (PowerShell 5.1+) | ✅ |
| macOS / Linux (sh + Python 3) | ✅ |
| Plain claude.ai chat | ❌ — no hook/filesystem support there (platform limit) |

## Running the tests

```powershell
# Windows
powershell -NoProfile -File tests\run-tests.ps1
```

```sh
# mac/Linux
sh tests/run-tests.sh
```

Both suites assert the same contract: boundary behavior at 89/90/91%, once-per-session locking, the PreCompact backstop, mid-write transcript tolerance, unknown-model fallback, and save-location rules.

## License

MIT
