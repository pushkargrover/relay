---
description: Generate a structured session handoff document capturing current progress, decisions, and next steps. Use at any time to preserve context for another AI agent.
argument-hint: [output-path]
allowed-tools: [Write, Bash, PowerShell]
---

# /handoff Command

Generate a comprehensive session handoff document and save it to disk so work can be resumed by any AI agent.

## Instructions

**Step 1 — Determine the output path:**
- If `$ARGUMENTS` contains a file path, use it exactly.
- Otherwise, if the session is inside a project directory, use `<project-root>/handoffs/handoff-<timestamp>.md`.
- If the session has no project (working directory is the home directory), use `~/.claude/handoffs/handoff-<timestamp>.md`.
- Timestamp format: `yyyy-MM-dd-HHmmss`.
- Create the directory if it does not exist.

**Step 2 — Write the handoff document to the computed path with this exact structure:**

```markdown
# Context Handoff
**Generated:** [timestamp]
**Project Directory:** [current working directory]
**Handoff File:** [full path to this file]

## Session Goal
[What the user has been trying to accomplish — one to three sentences]

## Decisions Made
[Key decisions and their rationale — be specific about WHY, not just WHAT]

## Work Completed
### Files Created or Modified
[Each file changed, with a brief description of what changed and why]

### Commands Run
[Significant commands executed and their outcomes]

## Current State
[What is working right now. What the system looks like. Current task status.]

## Open Questions / Blockers
[Unresolved issues, ambiguous requirements, things needing investigation]

## Next Steps
[Ordered, concrete next actions in priority order]

## Key File Paths
[The most important files to read immediately when resuming this work]

## Instructions for Next Agent
[Special conventions, warnings, constraints, or context not obvious from the files alone]
```

**Step 3 — Confirm:**
After writing, output one line: `Handoff saved to: <full path>` so the user can share it with another agent.
