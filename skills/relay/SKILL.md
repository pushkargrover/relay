---
name: relay
description: Use this skill when the user says "handoff", "create a handoff", "save session context", "generate a handoff document", "I need to switch agents", "context is getting full", "prepare for compaction", "summarize session for handoff", "save my progress", "export session", or asks how to resume work with another AI agent (Claude, Codex, Gemini, Copilot, etc.). Also use when the user asks where handoff files are saved, how the automatic 90% handoff works, or how to change the threshold. This skill belongs to the Relay plugin.
version: 1.0.0
---

# Relay Skill

Relay generates structured session handoff documents so work can be resumed seamlessly by any AI agent.

## Automatic Behavior

The plugin checks context usage on **every user turn** by reading real token counts from the session transcript. When usage reaches **90% of the model's context window**, it instructs Claude to write a handoff document before continuing, once per session.

For long single turns that never return to a prompt boundary, a **mid-task check runs after each tool call** and fires at a higher emergency threshold (**95%** by default), so an in-progress task is interrupted only when genuinely close to the limit. A `PreCompact` backstop also fires if compaction ever arrives first.

Save locations:
- Inside a project: `<project-root>/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`
- Session without a project (cwd is the home directory): `~/.claude/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`

## Changing the Threshold

Set `RELAY_THRESHOLD` (turn-boundary check, default `0.90`) and/or `RELAY_EMERGENCY_THRESHOLD` (mid-task check, default `0.95`) to a fraction between 0 and 1. Keep the emergency value higher than the normal one. Set per-machine in settings.json:

```json
{ "env": { "RELAY_THRESHOLD": "0.80", "RELAY_EMERGENCY_THRESHOLD": "0.97" } }
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

## Resuming From a Handoff

Tell any AI agent:

```
Read handoffs/handoff-2026-07-03-143022.md and continue the work described there.
```

The handoff format is agent-agnostic. It works with Claude Code, Codex, Gemini, Copilot, or any LLM-based coding assistant.
