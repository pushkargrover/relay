<div align="center">

<img src="assets/banner.svg" alt="Relay: save your session before the context window fills" width="820">

<br>

![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-3fb950?style=flat-square&labelColor=0b0e14)
![License](https://img.shields.io/badge/license-MIT-58a6ff?style=flat-square&labelColor=0b0e14)
![Dependencies](https://img.shields.io/badge/dependencies-zero-3fb950?style=flat-square&labelColor=0b0e14)
![Tests](https://img.shields.io/badge/tests-43%20passing-3fb950?style=flat-square&labelColor=0b0e14)
![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-d29922?style=flat-square&labelColor=0b0e14)

**Never lose your session progress again.** Relay monitors your context usage live and automatically writes a structured handoff document at 90%, before compaction erases your work. Resume in any AI agent: Claude, Codex, Gemini, Copilot.

</div>

---

## Install

Type these **inside Claude Code** (not a terminal; they are `/` slash commands):

```text
/plugin marketplace add pushkargrover/relay
/plugin install relay@grove-plugins
```

Then restart Claude Code so hooks load at session start. No npm, no pip, no runtime.

---

## What it does

```console
every turn        ==>  read real token usage from the session transcript
     |
     v
 >= 90% ?         ==>  instruct Claude to write an 8-section handoff (once per session)
     |
     v
 mid-task >= 95%  ==>  emergency check after each tool call, for long single turns
     |
     v
 compaction       ==>  PreCompact backstop fires the same handoff, just in case
```

- **Real counts, not estimates.** Relay reads the exact token usage that every assistant message records in the transcript.
- **Covers long single turns.** The per-turn check runs at turn boundaries; a separate mid-task check (after each tool call, at a higher 95% threshold) catches a long agentic task before it hits the wall.
- **Zero dependencies.** No daemon, nothing to keep running. The check rides on a hook that already fires each turn.
- **Never breaks your session.** Every failure path exits silently. A monitor must not harm what it monitors.
- **Free to run.** The check reads a local file and does arithmetic. No API call, no tokens, no impact on your usage limits.
- **On demand.** Run `/handoff` any time.

---

## Where handoffs are saved

| Session type | Location |
| --- | --- |
| Inside a project | `<project-root>/handoffs/handoff-YYYY-MM-DD-HHMMSS.md` |
| No project (home-directory session) | `~/.claude/handoffs/handoff-YYYY-MM-DD-HHMMSS.md` |

---

## The handoff document

Eight sections, readable by humans and ingestible by any AI agent:

```text
1. Session Goal              5. Open Questions / Blockers
2. Decisions Made            6. Next Steps
3. Work Completed            7. Key File Paths
4. Current State             8. Instructions for Next Agent
```

Resume in any agent with one line:

```text
Read handoffs/handoff-2026-07-04-143022.md and continue the work described there.
```

---

## Configuration

Change the thresholds via environment variables in `settings.json`:

```json
{ "env": { "RELAY_THRESHOLD": "0.80", "RELAY_EMERGENCY_THRESHOLD": "0.97" } }
```

- `RELAY_THRESHOLD` (default `0.90`) is the turn-boundary check.
- `RELAY_EMERGENCY_THRESHOLD` (default `0.95`) is the mid-task check that runs after each tool call. Keep it higher than `RELAY_THRESHOLD` so long tasks are interrupted only when genuinely close to the limit.

Add or adjust model context windows in [`scripts/context-limits.json`](scripts/context-limits.json). The longest model-ID prefix wins, and `_default` covers unknown models conservatively.

---

<details>
<summary><b>How it works</b> (for the curious)</summary>

<br>

Claude Code writes each session as a JSONL transcript where every assistant message records exact token usage. On each `UserPromptSubmit`, a tiny script (PowerShell on Windows, `sh` + Python 3 on macOS/Linux, both already on your machine) tails that file, sums `input + cache_read + cache_creation` tokens from the newest record, and divides by the model's context limit. At the threshold it emits `additionalContext` telling Claude to write the handoff.

The script only **detects**. Claude does the **synthesizing**, because only the model can explain its own decisions and next steps.

**Design principles**

- The monitor never breaks the session it monitors. Every failure path exits `0` silently.
- Fires exactly once per session, using a lockfile keyed by session ID.
- Zero dependencies. No daemon, no runtime, nothing to keep running.

</details>

---

## Platform support

| Platform | Status |
| --- | --- |
| Windows (PowerShell 5.1+) | Supported |
| macOS / Linux (`sh` + Python 3) | Supported |
| Plain claude.ai chat | Not supported (no hook or filesystem access there) |

---

## Running the tests

```console
# Windows
$ powershell -NoProfile -File tests\run-tests.ps1

# macOS / Linux
$ sh tests/run-tests.sh
```

Both suites assert the same contract: boundary behavior at 89 / 90 / 91%, once-per-session locking, the `PreCompact` backstop, mid-write transcript tolerance, unknown-model fallback, and save-location rules.

---

<div align="center">

MIT &copy; <a href="https://github.com/pushkargrover">Pushkar Grover</a>

</div>
