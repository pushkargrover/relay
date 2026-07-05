#!/usr/bin/env python3
"""trigger.py - Relay plugin (mac/Linux; invoked via trigger.sh).

Mirrors scripts/trigger.ps1 exactly:
  UserPromptSubmit - fire a handoff once context reaches the token budget.
  PostToolUse      - mid-task safety at a higher emergency budget; throttled so it
                     does not run the full check after every single tool call.
  PreCompact       - reliable near-full backstop (Claude Code knows the true window).

Absolute token budgets, not "% of window": the real context window is not exposed
to hooks and varies by model, so dividing by a hardcoded limit gave wrong
percentages and mis-timed firing. PreCompact covers the true limit per model.

Contract: hook input JSON on stdin; JSON with hookSpecificOutput.additionalContext
on stdout when firing, nothing otherwise. Always exit 0.
"""
import json
import os
import sys
import time
from datetime import datetime

TAIL_LINES = 40
THROTTLE_SECONDS = 15


def budget_env(name, default):
    raw = os.environ.get(name)
    if raw:
        try:
            v = int(raw)
            if v > 0:
                return v
        except ValueError:
            pass
    return default


def token_threshold():
    return budget_env("RELAY_TOKEN_THRESHOLD", 150000)


def emergency_token_threshold():
    return budget_env("RELAY_EMERGENCY_TOKEN_THRESHOLD", 190000)


def plan_threshold():
    # Percent (0-100) of the 5-hour rolling plan limit that triggers a handoff.
    return budget_env("RELAY_PLAN_THRESHOLD", 90)


def read_context_tokens(transcript_path):
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
            continue
        usage = (rec.get("message") or {}).get("usage")
        if not usage:
            continue
        return (int(usage.get("input_tokens") or 0)
                + int(usage.get("cache_read_input_tokens") or 0)
                + int(usage.get("cache_creation_input_tokens") or 0))
    return None


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
    # The rich Stop/statusline payload uses workspace.current_dir instead of cwd.
    if not project_dir:
        project_dir = (hook_input.get("workspace") or {}).get("current_dir")
    if not project_dir or not os.path.isdir(project_dir):
        project_dir = os.getcwd()

    lock_dir = os.path.join(home, ".claude", "handoffs", ".locks")
    lock_file = os.path.join(lock_dir, session_id + ".lock")

    # Debug trace: log EVERY hook fire (before any exit) when RELAY_DEBUG is set.
    if os.environ.get("RELAY_DEBUG"):
        rl_pct = ((hook_input.get("rate_limits") or {}).get("five_hour") or {}).get("used_percentage")
        shown = rl_pct if rl_pct is not None else "absent"
        dbg_dir = os.path.join(home, ".claude", "handoffs")
        os.makedirs(dbg_dir, exist_ok=True)
        with open(os.path.join(dbg_dir, ".relay-plan-debug.txt"), "a", encoding="utf-8") as f:
            f.write("{} event={} five_hour={}\n".format(datetime.now().isoformat(), event_name, shown))

    # Once-per-session lock (cheap, before any file read).
    if os.path.exists(lock_file):
        return

    # Throttle the frequent PostToolUse check.
    if event_name == "PostToolUse":
        stamp_file = os.path.join(lock_dir, session_id + ".last")
        now = int(time.time())
        if os.path.exists(stamp_file):
            try:
                with open(stamp_file) as f:
                    last = int((f.read() or "0").strip() or "0")
                if now - last < THROTTLE_SECONDS:
                    return
            except (ValueError, OSError):
                pass
        os.makedirs(lock_dir, exist_ok=True)
        with open(stamp_file, "w", encoding="ascii") as f:
            f.write(str(now))

    should_fire = False
    context_tokens = None
    plan_pct = None

    if event_name == "PreCompact":
        should_fire = True
    elif event_name == "Stop":
        # Plan-usage check: read the 5-hour rolling limit from the payload.
        # Every level may be absent (non-Pro/Max, or before the first API response).
        pct = ((hook_input.get("rate_limits") or {}).get("five_hour") or {}).get("used_percentage")
        if pct is None:
            return
        if float(pct) >= plan_threshold():
            should_fire = True
            plan_pct = float(pct)
        else:
            return
    else:
        if not transcript_path or not os.path.isfile(transcript_path):
            return
        context_tokens = read_context_tokens(transcript_path)
        if not context_tokens or context_tokens <= 0:
            return
        budget = emergency_token_threshold() if event_name == "PostToolUse" else token_threshold()
        if context_tokens >= budget:
            should_fire = True

    if not should_fire:
        return

    os.makedirs(lock_dir, exist_ok=True)
    with open(lock_file, "w", encoding="ascii") as f:
        f.write(datetime.now().isoformat())

    is_real_project = os.path.isdir(project_dir) and os.path.realpath(project_dir) != os.path.realpath(home)
    handoffs_dir = (os.path.join(project_dir, "handoffs") if is_real_project
                    else os.path.join(home, ".claude", "handoffs"))

    timestamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    handoff_file = os.path.join(handoffs_dir, "handoff-" + timestamp + ".md")
    token_str = "{:,}".format(context_tokens) if context_tokens else "many"
    if event_name == "PreCompact":
        reason = "Context compaction is imminent."
    elif event_name == "Stop":
        reason = "Your 5-hour plan usage has reached {}% (Pro/Max limit).".format(round(plan_pct, 1))
    elif event_name == "PostToolUse":
        reason = "Context has reached {} tokens mid-task.".format(token_str)
    else:
        reason = "Context has reached {} tokens.".format(token_str)

    instruction = """[relay] {reason} Before continuing with the user's request, write a session handoff document so progress survives.

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
""".format(reason=reason, handoffs_dir=handoffs_dir, handoff_file=handoff_file,
           generated=datetime.now().strftime("%Y-%m-%d %H:%M:%S"), project_dir=project_dir)

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
        pass
    sys.exit(0)
