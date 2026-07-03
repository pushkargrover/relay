#!/bin/sh
# run-tests.sh - unit tests for scripts/trigger.py (the mac/Linux implementation).
# Mirrors tests/run-tests.ps1 case-for-case so both platforms honor one contract.
# Usage: sh tests/run-tests.sh          Exit 0 = all pass, 1 = failures.

# Pin the environment: a leaked threshold override corrupts boundary asserts.
unset CONTEXT_HANDOFF_THRESHOLD

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TRIGGER="$DIR/../scripts/trigger.py"
FIXTURES="$DIR/fixtures"
mkdir -p "$FIXTURES"

# Find Python 3 the same way trigger.sh does (python3 may be a broken stub on
# Windows Git Bash, so verify it actually runs).
PY=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    PY=python
else
    echo "SKIP: no Python 3 available"; exit 0
fi

HOMEDIR=$("$PY" -c "import os; print(os.path.expanduser('~'))")
LOCKDIR="$HOMEDIR/.claude/handoffs/.locks"
PASS=0; FAIL=0

invoke() { printf '%s' "$1" | "$PY" "$TRIGGER"; }

assert() { # $1 = condition result (0/1 as exit code semantics via test), $2 = name
    if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  PASS  $2"
    else FAIL=$((FAIL+1)); echo "  FAIL  $2"; fi
}

fixture() { # name input_tok cache_read cache_new model [extra_line]
    f="$FIXTURES/$1"
    {
        echo '{"type":"user","message":{"role":"user","content":"hello"}}'
        echo '{"type":"assistant","message":{"model":"'"$4"'","usage":{"input_tokens":'"$2"',"cache_read_input_tokens":'"$3"',"cache_creation_input_tokens":'"$5"',"output_tokens":500}}}'
        [ -n "$6" ] && echo "$6"
    } > "$f"
    echo "$f"
}

hookinput() { # transcript session event [cwd]
    cwd="${4:-$FIXTURES}"
    "$PY" -c "import json,sys; print(json.dumps({'session_id':sys.argv[2],'transcript_path':sys.argv[1],'cwd':sys.argv[4],'hook_event_name':sys.argv[3]}))" "$1" "$2" "$3" "$cwd"
}

clearlock() { rm -f "$LOCKDIR/$1.lock"; }

echo "context-handoff trigger.py tests"
echo "--------------------------------"

# 1: 50% silent
s=sh-50pct; clearlock $s
t=$(fixture usage-50.jsonl 3000 94000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -z "$out" ]; assert $? "50% usage stays silent"; clearlock $s

# 2: 89% silent
s=sh-89pct; clearlock $s
t=$(fixture usage-89.jsonl 3000 172000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -z "$out" ]; assert $? "89% usage stays silent"; clearlock $s

# 3: 91% fires + content checks
s=sh-91pct; clearlock $s
t=$(fixture usage-91.jsonl 3000 176000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -n "$out" ]; assert $? "91% usage fires"
echo "$out" | grep -q '91'; assert $? "fire message reports the percentage"
echo "$out" | grep -q 'handoff-20'; assert $? "fire message contains a timestamped handoff path"

# 4: exactly 90% fires
s=sh-90pct; clearlock $s
t=$(fixture usage-90.jsonl 3000 174000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -n "$out" ]; assert $? "exactly 90% fires (inclusive threshold)"; clearlock $s

# 5: lock prevents second fire (sh-91pct lock written by case 3)
t=$(fixture usage-91b.jsonl 3000 180000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" sh-91pct UserPromptSubmit)")
[ -z "$out" ]; assert $? "second crossing in same session stays silent (lock)"; clearlock sh-91pct

# 6: PreCompact backstop
s=sh-precompact; clearlock $s
t=$(fixture usage-low.jsonl 3000 40000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s PreCompact)")
[ -n "$out" ]; assert $? "PreCompact fires even at low usage"; clearlock $s

# 7: truncated last line tolerated
s=sh-midwrite; clearlock $s
t=$(fixture usage-midwrite.jsonl 3000 176000 claude-opus-4-8 3000 '{"type":"assistant","message":{"usage":{"input_tokens":')
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -n "$out" ]; assert $? "truncated last line skipped, prior record used"; clearlock $s

# 8: unknown model -> default limit
s=sh-unknown; clearlock $s
t=$(fixture usage-unknown.jsonl 3000 176000 totally-new-model-9000 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -n "$out" ]; assert $? "unknown model uses _default limit and still fires"; clearlock $s

# 9: missing transcript -> silent, exit 0
s=sh-notranscript; clearlock $s
out=$(invoke "$(hookinput /does/not/exist.jsonl $s UserPromptSubmit)"); rc=$?
[ -z "$out" ]; assert $? "missing transcript stays silent"
[ "$rc" = "0" ]; assert $? "missing transcript exits 0 (never blocks the user)"

# 10: home-dir session -> central .claude/handoffs
s=sh-homedir; clearlock $s
t=$(fixture usage-home.jsonl 3000 176000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit "$HOMEDIR")")
echo "$out" | grep -qF '.claude'; assert $? "home-dir session saves to central .claude/handoffs"
clearlock $s

# 11: project session -> project-local handoffs
s=sh-projdir; clearlock $s
t=$(fixture usage-proj.jsonl 3000 176000 claude-opus-4-8 3000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit "$FIXTURES")")
echo "$out" | grep -qF 'handoffs'; assert $? "project session saves to project-local handoffs"
echo "$out" | grep -qF "$HOMEDIR/.claude/handoffs/handoff" ; [ $? -ne 0 ]; assert $? "project session does not use the central dir"
clearlock $s

# 12: garbage stdin -> silent, exit 0
out=$(printf 'not-json-at-all' | "$PY" "$TRIGGER"); rc=$?
[ -z "$out" ]; assert $? "garbage stdin stays silent"
[ "$rc" = "0" ]; assert $? "garbage stdin exits 0"

# 13: threshold env override honored
s=sh-envthresh; clearlock $s
t=$(fixture usage-env.jsonl 3000 94000 claude-opus-4-8 3000)   # 50%
out=$(printf '%s' "$(hookinput "$t" $s UserPromptSubmit)" | CONTEXT_HANDOFF_THRESHOLD=0.40 "$PY" "$TRIGGER")
[ -n "$out" ]; assert $? "env threshold override (0.40) fires at 50%"; clearlock $s

echo "--------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
