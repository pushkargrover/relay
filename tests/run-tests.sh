#!/bin/sh
# run-tests.sh - unit tests for scripts/trigger.py (token-budget triggering).
# Mirrors tests/run-tests.ps1 case-for-case. Usage: sh tests/run-tests.sh

# Pin the environment: a leaked budget override corrupts boundary asserts.
unset RELAY_TOKEN_THRESHOLD
unset RELAY_EMERGENCY_TOKEN_THRESHOLD

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TRIGGER="$DIR/../scripts/trigger.py"
FIXTURES="$DIR/fixtures"
mkdir -p "$FIXTURES"

PY=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then PY=python
else echo "SKIP: no Python 3 available"; exit 0; fi

HOMEDIR=$("$PY" -c "import os;print(os.path.expanduser('~'))")
LOCKDIR="$HOMEDIR/.claude/handoffs/.locks"
PASS=0; FAIL=0

invoke() { printf '%s' "$1" | "$PY" "$TRIGGER"; }
assert() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "  PASS  $2"; else FAIL=$((FAIL+1)); echo "  FAIL  $2"; fi; }

fixture() { # name total_tokens [extra_line]
    f="$FIXTURES/$1"; inp=$(( $2 - 2000 ))
    {
        echo '{"type":"user","message":{"role":"user","content":"hello"}}'
        echo '{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":'"$inp"',"cache_read_input_tokens":1000,"cache_creation_input_tokens":1000,"output_tokens":500}}}'
        [ -n "$3" ] && echo "$3"
    } > "$f"
    echo "$f"
}
hookinput() { cwd="${4:-$FIXTURES}"; "$PY" -c "import json,sys;print(json.dumps({'session_id':sys.argv[2],'transcript_path':sys.argv[1],'cwd':sys.argv[4],'hook_event_name':sys.argv[3]}))" "$1" "$2" "$3" "$cwd"; }
clearlock() { rm -f "$LOCKDIR/$1.lock" "$LOCKDIR/$1.last"; }

echo "relay trigger.py tests (token budgets: normal=150000 emergency=190000)"
echo "--------------------------------"

s=s-below; clearlock $s
t=$(fixture tok-100k.jsonl 100000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)"); [ -z "$out" ]; assert $? "100k tokens stays silent"; clearlock $s

s=s-149; clearlock $s
t=$(fixture tok-149k.jsonl 149000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)"); [ -z "$out" ]; assert $? "149k stays silent (just below budget)"; clearlock $s

s=s-150; clearlock $s
t=$(fixture tok-150k.jsonl 150000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)"); [ -n "$out" ]; assert $? "exactly 150k fires (inclusive)"; clearlock $s

s=s-151; clearlock $s
t=$(fixture tok-151k.jsonl 151000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)")
[ -n "$out" ]; assert $? "151k fires"
echo "$out" | grep -q '151,000 tokens'; assert $? "message reports token count (not a percentage)"
echo "$out" | grep -q 'handoff-20'; assert $? "message contains a timestamped handoff path"
echo "$out" | grep -q '%'; [ $? -ne 0 ]; assert $? "message contains no bogus percentage"

t=$(fixture tok-200k.jsonl 200000)
out=$(invoke "$(hookinput "$t" s-151 UserPromptSubmit)"); [ -z "$out" ]; assert $? "second crossing stays silent (lock)"; clearlock s-151

s=s-precompact; clearlock $s
t=$(fixture tok-low.jsonl 20000)
out=$(invoke "$(hookinput "$t" $s PreCompact)"); [ -n "$out" ]; assert $? "PreCompact fires even at low tokens"; clearlock $s

s=s-midwrite; clearlock $s
t=$(fixture tok-midwrite.jsonl 151000 '{"type":"assistant","message":{"usage":{"input_tokens":')
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit)"); [ -n "$out" ]; assert $? "truncated last line skipped, prior record used"; clearlock $s

s=s-ptu-quiet; clearlock $s
t=$(fixture tok-160k.jsonl 160000)
out=$(invoke "$(hookinput "$t" $s PostToolUse)"); [ -z "$out" ]; assert $? "PostToolUse silent at 160k (below 190k emergency)"; clearlock $s

s=s-ptu-fire; clearlock $s
t=$(fixture tok-195k.jsonl 195000)
out=$(invoke "$(hookinput "$t" $s PostToolUse)")
[ -n "$out" ]; assert $? "PostToolUse fires at 195k"
echo "$out" | grep -q 'mid-task'; assert $? "emergency message labelled mid-task"; clearlock $s

s=s-throttle; clearlock $s
mkdir -p "$LOCKDIR"; date +%s > "$LOCKDIR/$s.last"
t=$(fixture tok-throttle.jsonl 200000)
out=$(invoke "$(hookinput "$t" $s PostToolUse)"); [ -z "$out" ]; assert $? "PostToolUse throttled when checked recently"
rm -f "$LOCKDIR/$s.last"
out=$(invoke "$(hookinput "$t" $s PostToolUse)"); [ -n "$out" ]; assert $? "PostToolUse fires once throttle window passes"; clearlock $s

s=s-env; clearlock $s
t=$(fixture tok-60k.jsonl 60000)
out=$(printf '%s' "$(hookinput "$t" $s UserPromptSubmit)" | RELAY_TOKEN_THRESHOLD=50000 "$PY" "$TRIGGER")
[ -n "$out" ]; assert $? "RELAY_TOKEN_THRESHOLD override fires at 60k when budget lowered to 50k"; clearlock $s

s=s-home; clearlock $s
t=$(fixture tok-home.jsonl 151000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit "$HOMEDIR")")
echo "$out" | grep -qF '.claude'; assert $? "home-dir session saves to central .claude/handoffs"; clearlock $s

s=s-proj; clearlock $s
t=$(fixture tok-proj.jsonl 151000)
out=$(invoke "$(hookinput "$t" $s UserPromptSubmit "$FIXTURES")")
echo "$out" | grep -qF 'handoffs'; assert $? "project session saves to project-local handoffs"; clearlock $s

s=s-notx; clearlock $s
out=$(invoke "$(hookinput /does/not/exist.jsonl $s UserPromptSubmit)"); rc=$?
[ -z "$out" ]; assert $? "missing transcript stays silent"
[ "$rc" = "0" ]; assert $? "missing transcript exits 0"
out=$(printf 'not-json' | "$PY" "$TRIGGER"); rc=$?
[ -z "$out" ]; assert $? "garbage stdin stays silent"
[ "$rc" = "0" ]; assert $? "garbage stdin exits 0"

echo "--------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
