#!/usr/bin/env python3
"""relay-recover.py - Relay local-mode recovery (mac/Linux; mirrors relay-recover.ps1).

Generates a session handoff using a LOCAL model via Ollama - no Anthropic
account, no internet, zero tokens. Built for the lockout case: run it in a
terminal after Claude stops responding and still get a clean handoff.

Usage:
  relay-recover.py                 Recover the most recent session
  relay-recover.py --list          List recent sessions to pick from
  relay-recover.py 2               Recover the 2nd most recent session
  relay-recover.py --session <id>  Recover a specific session id
  relay-recover.py --model <name>  Use a specific Ollama model
  relay-recover.py --out <path>    Write the handoff to a specific path

Config (env): RELAY_OLLAMA_MODEL, RELAY_OLLAMA_URL (default http://localhost:11434)
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.request

OLLAMA_URL = os.environ.get("RELAY_OLLAMA_URL", "http://localhost:11434").rstrip("/")
PROJECTS_DIR = os.path.join(os.path.expanduser("~"), ".claude", "projects")
MAX_CHARS = 12000

_ANSI = re.compile(r"\x1b\[[0-9;?=]*[A-Za-z]")
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _rec_log(msg):
    # Log to a file so background/detached auto-recovery runs are diagnosable.
    try:
        p = os.path.join(os.path.expanduser("~"), ".claude", "handoffs", ".relay-recover.log")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write("{} {}\n".format(datetime.datetime.now().isoformat(), msg))
    except OSError:
        pass


_LOCKFILE = None


def _clear_lock():
    # A failed recovery must clear the lock so the next hook fire retries.
    if _LOCKFILE and os.path.exists(_LOCKFILE):
        try:
            os.remove(_LOCKFILE)
        except OSError:
            pass


def _fail(msg):
    print(msg, file=sys.stderr)
    _rec_log("fail: " + msg)
    _clear_lock()
    return 1


def recent_transcripts(count=15):
    items = []
    if not os.path.isdir(PROJECTS_DIR):
        return items
    for root, _dirs, files in os.walk(PROJECTS_DIR):
        for name in files:
            if name.endswith(".jsonl"):
                p = os.path.join(root, name)
                try:
                    items.append((p, os.path.getmtime(p)))
                except OSError:
                    pass
    items.sort(key=lambda t: t[1], reverse=True)
    return items[:count]


def text_from_content(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        t = block.get("type")
        if t == "text":
            parts.append(block.get("text") or "")
        elif t == "tool_use":
            parts.append("[used tool: {}]".format(block.get("name")))
        elif t == "tool_result":
            c = block.get("content")
            txt = c if isinstance(c, str) else text_from_content(c)
            if len(txt) > 200:
                txt = txt[:200] + "..."
            parts.append("[tool result: {}]".format(txt))
    return " ".join(parts)


def _iter_records(path, limit=None):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            if limit is not None and i >= limit:
                break
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def transcript_meta(path):
    cwd = None
    snippet = None
    session_id = os.path.splitext(os.path.basename(path))[0]
    for rec in _iter_records(path, limit=40):
        if not cwd and rec.get("cwd"):
            cwd = rec.get("cwd")
        if not snippet and rec.get("type") == "user":
            txt = text_from_content((rec.get("message") or {}).get("content")).strip()
            if txt and not txt.startswith("[tool result"):
                snippet = (txt[:60] + "...") if len(txt) > 60 else txt
        if cwd and snippet:
            break
    project = os.path.basename(cwd.rstrip("/\\")) if cwd else "(unknown)"
    return {"path": path, "session_id": session_id, "cwd": cwd,
            "project": project, "snippet": snippet}


def clean_conversation(path):
    lines = []
    for rec in _iter_records(path):
        t = rec.get("type")
        if t not in ("user", "assistant"):
            continue
        msg = rec.get("message")
        if not msg:
            continue
        txt = text_from_content(msg.get("content")).strip()
        if not txt:
            continue
        lines.append("{}: {}".format(t.upper(), txt))
    full = "\n".join(lines)
    # Strip ANSI escape sequences and control bytes from tool output.
    full = _ANSI.sub("", full)
    full = _CTRL.sub("", full)
    if len(full) <= MAX_CHARS:
        return full
    head = full[:1500]
    tail = full[-(MAX_CHARS - 1500):]
    return head + "\n...[middle of session trimmed to fit local model]...\n" + tail


def resolve_model(model_arg):
    if model_arg:
        return model_arg
    if os.environ.get("RELAY_OLLAMA_MODEL"):
        return os.environ["RELAY_OLLAMA_MODEL"]
    try:
        with urllib.request.urlopen(OLLAMA_URL + "/api/tags", timeout=10) as r:
            tags = json.loads(r.read())
        models = tags.get("models") or []
        if models:
            return models[0]["name"]
    except Exception:
        pass
    raise RuntimeError("No Ollama model found. Set RELAY_OLLAMA_MODEL or run: ollama pull gemma4")


def invoke_ollama(model, prompt):
    # Ollama defaults to a tiny ~4K context window regardless of what the model
    # supports, which starves the output on large transcripts (partial or empty
    # handoffs). Open the window explicitly so there is room for input + output.
    num_ctx = 8192
    raw = os.environ.get("RELAY_OLLAMA_NUM_CTX")
    if raw and raw.isdigit() and int(raw) > 0:
        num_ctx = int(raw)
    body = json.dumps({"model": model, "prompt": prompt, "stream": False,
                       "options": {"num_ctx": num_ctx}}).encode("utf-8")
    req = urllib.request.Request(OLLAMA_URL + "/api/generate", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read()).get("response", "")


def build_prompt(convo):
    return (
        "You are writing a session handoff so another AI agent can resume this work. "
        "Based ONLY on the conversation below, produce a markdown document with EXACTLY "
        "these 8 sections, in this order:\n\n"
        "# Session Handoff\n## Session Goal\n## Decisions Made\n## Work Completed\n"
        "## Current State\n## Open Questions / Blockers\n## Next Steps\n## Key File Paths\n"
        "## Instructions for Next Agent\n\n"
        "Be concise and specific. Use real details from the conversation. "
        "Output ONLY the markdown document, no preamble.\n\nCONVERSATION:\n" + convo
    )


def ollama_reachable():
    try:
        with urllib.request.urlopen(OLLAMA_URL + "/api/tags", timeout=10) as r:
            r.read()
        return True
    except Exception:
        return False


def main(argv=None):
    p = argparse.ArgumentParser(add_help=True, description="Relay local-mode recovery via Ollama.")
    p.add_argument("selection", nargs="?", help="index of a recent session (1 = most recent)")
    p.add_argument("--list", action="store_true", help="list recent sessions")
    p.add_argument("--model", help="Ollama model name")
    p.add_argument("--out", help="output path for the handoff")
    p.add_argument("--session", help="recover a specific session id")
    p.add_argument("--transcript", help="recover this exact transcript file (no session lookup)")
    p.add_argument("--lockfile", help="lock file to remove on failure (enables retry)")
    args = p.parse_args(argv)

    global _LOCKFILE
    _LOCKFILE = args.lockfile

    if not ollama_reachable():
        return _fail("ERROR: Cannot reach Ollama at {}. Is it installed and running? "
                     "(https://ollama.com)".format(OLLAMA_URL))

    recent = recent_transcripts(15)
    if not args.transcript and not recent:
        print("No session transcripts found under " + PROJECTS_DIR, file=sys.stderr)
        return 1

    if args.list:
        print("Recent sessions (newest first):\n")
        for i, (path, mtime) in enumerate(recent):
            m = transcript_meta(path)
            ts = datetime.datetime.fromtimestamp(mtime).strftime("%m-%d %H:%M")
            print("  [{:>2}] {}  {}".format(i + 1, ts, m["project"]))
            if m["snippet"]:
                print('       "{}"'.format(m["snippet"]))
        print("\nRun 'relay-recover <number>' to recover one.")
        return 0

    # Select transcript.
    if args.transcript:
        if not os.path.isfile(args.transcript):
            return _fail("Transcript not found: " + args.transcript)
        target = args.transcript   # recover this exact file (no session lookup)
    elif args.session:
        match = [pth for (pth, _mt) in recent if os.path.splitext(os.path.basename(pth))[0] == args.session]
        if not match:
            return _fail("Session '{}' not found in recent transcripts. Try --list.".format(args.session))
        target = match[0]
    elif args.selection:
        if not args.selection.isdigit() or not (1 <= int(args.selection) <= len(recent)):
            print("Invalid selection '{}'. Use a number 1-{}, or --list.".format(args.selection, len(recent)), file=sys.stderr)
            return 1
        target = recent[int(args.selection) - 1][0]
    else:
        target = recent[0][0]

    meta = transcript_meta(target)
    print("Recovering session: {}".format(meta["project"]))
    if meta["snippet"]:
        print('  "{}"'.format(meta["snippet"]))

    # Output path.
    cwd = os.getcwd()
    home = os.path.expanduser("~")
    if args.out:
        handoff_file = args.out
        od = os.path.dirname(handoff_file)
        if od:
            os.makedirs(od, exist_ok=True)
    else:
        is_real_project = os.path.realpath(cwd) != os.path.realpath(home)
        handoffs_dir = os.path.join(cwd, "handoffs") if is_real_project else os.path.join(home, ".claude", "handoffs")
        os.makedirs(handoffs_dir, exist_ok=True)
        ts = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        handoff_file = os.path.join(handoffs_dir, "handoff-{}-local.md".format(ts))
    _rec_log("start: session={} -> {}".format(meta["session_id"], handoff_file))

    model = resolve_model(args.model)
    convo = clean_conversation(target)
    if not convo.strip():
        return _fail("That transcript has no readable conversation content.")

    print("Synthesizing with local model '{}' (this can take a couple of minutes)...".format(model))
    markdown = invoke_ollama(model, build_prompt(convo))
    if not markdown or not markdown.strip():
        return _fail("The local model returned nothing.")

    header = "<!-- Generated locally by Relay via Ollama ({}). Source session: {} -->\n\n".format(model, meta["session_id"])
    with open(handoff_file, "w", encoding="utf-8") as f:
        f.write(header + markdown)

    print("\nHandoff saved to: " + handoff_file)
    _rec_log("ok: " + handoff_file)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # log failures from detached runs
        _rec_log("ERROR: {}".format(e))
        _clear_lock()
        sys.exit(1)
