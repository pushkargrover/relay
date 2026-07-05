---
name: relay
description: Use this skill when the user says "handoff", "create a handoff", "save session context", "generate a handoff document", "I need to switch agents", "context is getting full", "prepare for compaction", "summarize session for handoff", "save my progress", "export session", or asks how to resume work with another AI agent (Claude, Codex, Gemini, Copilot, etc.). Also use when the user asks where handoff files are saved, how the automatic 90% handoff works, or how to change the threshold. This skill belongs to the Relay plugin.
version: 1.0.0
---

# Relay Skill

Relay generates structured session handoff documents so work can be resumed seamlessly by any AI agent.

## Automatic Behavior

The plugin checks context on **every user turn** by reading the real token count from the session transcript. When it reaches the **token budget** (default 150,000 tokens), it instructs Claude to write a handoff document before continuing, once per session. Relay uses an absolute token budget rather than a percentage because the true context window isn't exposed to hooks and varies by model.

For long single turns that never return to a prompt boundary, a **throttled mid-task check runs after tool calls** and fires at a higher emergency budget (default 190,000 tokens). A `PreCompact` backstop also fires right before compaction — this is the reliable near-full signal for any model, since Claude Code knows the true window.

On **Pro/Max** accounts, Relay also watches your **5-hour plan usage**: at the end of each turn it reads `rate_limits.five_hour.used_percentage` from the `Stop`-hook payload and writes a handoff when it reaches `RELAY_PLAN_THRESHOLD` (default 90%), so a rate-limit lockout never catches you without a handoff. If the user asks about tracking their plan/subscription usage or the 5-hour limit, this is the relevant feature.

Save locations:
- Inside a project: `<project-root>/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`
- Session without a project (cwd is the home directory): `~/.claude/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`

## Changing the Threshold

Set `RELAY_TOKEN_THRESHOLD` (turn-boundary budget, default `150000` tokens) and/or `RELAY_EMERGENCY_TOKEN_THRESHOLD` (mid-task budget, default `190000`). Keep the emergency value higher. On a big-window model, raise both. Set per-machine in settings.json:

```json
{ "env": { "RELAY_TOKEN_THRESHOLD": "120000", "RELAY_EMERGENCY_TOKEN_THRESHOLD": "180000" } }
```

## Manual Invocation

Run `/handoff` at any time, optionally with a custom output path:

```
/handoff
/handoff path/to/my-handoff.md
```

## Handoff Document Sections

Every handoff contains these 8 sections:

1. **Session Goal**: what was being accomplished
2. **Decisions Made**: choices with rationale (the WHY)
3. **Work Completed**: files changed, commands run
4. **Current State**: what works right now
5. **Open Questions / Blockers**: unresolved issues
6. **Next Steps**: ordered, concrete next actions
7. **Key File Paths**: files to read immediately when resuming
8. **Instructions for Next Agent**: conventions, warnings, non-obvious context

## Local Mode (Ollama) — Lockout Recovery

Relay can also generate a handoff with a **local** model via Ollama, using zero Anthropic tokens — useful when the account is rate-limited/locked out and Claude can't write the handoff itself.

- **Automatic on lockout**: if Relay sees a rate-limit `429` in the transcript, it spawns `relay-recover` in the background so the local model writes the handoff without any user action (requires Ollama; disable with `RELAY_AUTO_RECOVER=0`).
- **After a lockout (manual)**, the user runs the standalone script in a terminal (no Claude needed): `relay-recover.ps1` (Windows) or `relay-recover.py` (mac/Linux). Flags: `--list`, a bare index, `--session <id>`, `--model <name>`, `--out <path>`.
- **Before a lockout**, the `/handoff-local` command does the same local synthesis on demand.
- Requires Ollama installed with a model pulled (e.g. `ollama pull gemma4`). Model via `RELAY_OLLAMA_MODEL`, endpoint via `RELAY_OLLAMA_URL`.

If the user asks how to recover work after hitting their limit, or how to make a handoff without spending tokens, point them to local mode.

## Resuming From a Handoff

Tell any AI agent:

```
Read handoffs/handoff-2026-07-03-143022.md and continue the work described there.
```

The handoff format is agent-agnostic. It works with Claude Code, Codex, Gemini, Copilot, or any LLM-based coding assistant.
