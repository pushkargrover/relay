#!/usr/bin/env python3
"""trigger.py - context-handoff plugin (mac/Linux; invoked via trigger.sh).

Mirrors scripts/trigger.ps1 exactly:
  UserPromptSubmit - read real token usage from the session transcript (JSONL)
                     and fire a handoff instruction at >= the threshold (default 90%).
  PreCompact       - backstop: fire unconditionally if no handoff was written yet.

Contract: hook input JSON on stdin; JSON with hookSpecificOutput.additionalContext
on stdout when firing, nothing otherwise. Always exit 0 - a monitoring hook must
never block the user's prompt.
"""
import json
import os
import sys
from datetime import datetime

TAIL_LINES = 100


def threshold():
    t = 0.90
    raw = os.environ.get("CONTEXT_HANDOFF_THRESHOLD")
    if raw:
        try:
            v = float(raw)
            if 0 < v <= 1:
                t = v
        except ValueError:
            pass
    return t


def read_usage(transcript_path):
    """Newest assistant usage record ~= full current context size."""
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()[-TAIL_LINES:]
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue  # tolerate a mid-write partial line
        msg = rec.get("message") or {}
        usage = msg.get("usage")
        if not usage:
            continue
        tokens = (
            int(usage.get("input_tokens") or 0)
            + int(usage.get("cache_read_input_tokens") or 0)
            + int(usage.get("cache_creation_input_tokens") or 0)
        )
        return tokens, msg.get("model") or ""
    return None, None


def context_limit(model):
    """Longest matching model prefix wins; '_default' is the fallback."""
    limits_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "context-limits.json")
    limit = 200000
    try:
        with open(limits_path, "r", encoding="utf-8") as f:
            limits = json.load(f).get("limits", {})
        best = ""
        for prefix in limits:
            if prefix != "_default" and model.startswith(prefix) and len(prefix) > len(best):
                best = prefix
        limit = int(limits[best]) if best else int(limits.get("_default", limit))
    except Exception:
        pass
    return limit


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError:
        return

    session_id = hook_input.get("session_id") or "unknown"
    transcript_path = hook_input.get("transcript_path")
    project_dir = hook_input.get("cwd")
    event_name = hook_input.get("hook_event_name")
    home = os.path.expanduser("~")
    if not project_dir or not os.path.isdir(project_dir):
        project_dir = os.getcwd()

    # Once-per-session lock: a session hovering at the threshold fires once.
    lock_dir = os.path.join(home, ".claude", "handoffs", ".locks")
    lock_file = os.path.join(lock_dir, session_id + ".lock")
    if os.path.exists(lock_file):
        return

    should_fire = False
    usage_pct = None

    if event_name == "PreCompact":
        should_fire = True  # compaction is about to erase context
    else:
        if not transcript_path or not os.path.isfile(transcript_path):
            return
        tokens, model = read_usage(transcript_path)
        if not tokens or tokens <= 0:
            return
        limit = context_limit(model)
        usage_pct = round(tokens / limit * 100, 1)
        if tokens / limit >= threshold():
            should_fire = True

    if not should_fire:
        return

    os.makedirs(lock_dir, exist_ok=True)
    with open(lock_file, "w", encoding="ascii") as f:
        f.write(datetime.now().isoformat())

    # Save inside the project when there is one; otherwise the central
    # ~/.claude/handoffs so we never litter the user's home directory.
    is_real_project = os.path.isdir(project_dir) and os.path.realpath(project_dir) != os.path.realpath(home)
    handoffs_dir = (
        os.path.join(project_dir, "handoffs") if is_real_project
        else os.path.join(home, ".claude", "handoffs")
    )

    timestamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    handoff_file = os.path.join(handoffs_dir, "handoff-" + timestamp + ".md")
    reason = (
        "Context compaction is imminent."
        if event_name == "PreCompact"
        else "Context usage has reached {}% of the window.".format(usage_pct)
    )

    instruction = """[context-handoff] {reason} Before continuing with the user's request, write a session handoff document so progress survives.

1. Create the directory if needed: {handoffs_dir}
2. Write the handoff to exactly: {handoff_file}

Required structure (fill every section from this conversation):

# Context Handoff
**Generated:** {generated}
**Project Directory:** {project_dir}

## Session Goal
## Decisions Made
(each with its rationale - the WHY)
## Work Completed
### Files Created or Modified
### Commands Run
## Current State
## Open Questions / Blockers
## Next Steps
(ordered, concrete)
## Key File Paths
## Instructions for Next Agent
(conventions, warnings, non-obvious context)

After writing it, tell the user: "Handoff saved to: {handoff_file}" and then continue with their request.
""".format(
        reason=reason,
        handoffs_dir=handoffs_dir,
        handoff_file=handoff_file,
        generated=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        project_dir=project_dir,
    )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": instruction,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a monitor must never break the session it monitors
    sys.exit(0)
