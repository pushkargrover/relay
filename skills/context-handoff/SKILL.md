---
name: context-handoff
description: Use this skill when the user says "handoff", "create a handoff", "save session context", "generate a handoff document", "I need to switch agents", "context is getting full", "prepare for compaction", "summarize session for handoff", "save my progress", "export session", or asks how to resume work with another AI agent (Claude, Codex, Gemini, Copilot, etc.). Also use when the user asks where handoff files are saved, how the automatic 90% handoff works, or how to change the threshold.
version: 1.0.0
---

# Context Handoff Skill

Generates structured session handoff documents so work can be resumed seamlessly by any AI agent.

## Automatic Behavior

The plugin checks context usage on **every user turn** by reading real token counts from the session transcript. When usage reaches **90% of the model's context window**, it instructs Claude to write a handoff document before continuing — once per session. A `PreCompact` backstop also fires if compaction ever arrives first.

Save locations:
- Inside a project: `<project-root>/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`
- Session without a project (cwd is the home directory): `~/.claude/handoffs/handoff-YYYY-MM-DD-HHMMSS.md`

## Changing the Threshold

Set the `CONTEXT_HANDOFF_THRESHOLD` environment variable to a fraction between 0 and 1 (e.g. `0.80` for 80%). This can be set per-machine in settings.json:

```json
{ "env": { "CONTEXT_HANDOFF_THRESHOLD": "0.80" } }
```

## Manual Invocation

Run `/handoff` at any time, optionally with a custom output path:

```
/handoff
/handoff path/to/my-handoff.md
```

## Handoff Document Sections

Every handoff contains these 8 sections:

1. **Session Goal** — what was being accomplished
2. **Decisions Made** — choices with rationale (the WHY)
3. **Work Completed** — files changed, commands run
4. **Current State** — what works right now
5. **Open Questions / Blockers** — unresolved issues
6. **Next Steps** — ordered, concrete next actions
7. **Key File Paths** — files to read immediately when resuming
8. **Instructions for Next Agent** — conventions, warnings, non-obvious context

## Resuming From a Handoff

Tell any AI agent:

```
Read handoffs/handoff-2026-07-03-143022.md and continue the work described there.
```

The handoff format is agent-agnostic — it works with Claude Code, Codex, Gemini, Copilot, or any LLM-based coding assistant.
