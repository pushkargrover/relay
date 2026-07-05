#!/bin/sh
# run-tests.sh - unit tests for scripts/trigger.py (token-budget triggering).
# Mirrors tests/run-tests.ps1 case-for-case. Usage: sh tests/run-tests.sh

# Pin the environment: a leaked budget override corrupts boundary asserts.
unset RELAY_TOKEN_THRESHOLD
unset RELAY_EMERGENCY_TOKEN_THRESHOLD
unset RELAY_PLAN_THRESHOLD
unset RELAY_DEBUG
unset RELAY_AUTO_RECOVER
unset RELAY_NO_SPAWN
unset RELAY_OLLAMA_URL

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
clearlock() { rm -f "$LOCKDIR/$1.lock" "$LOCKDIR/$1.last" "$LOCKDIR/$1.recovered"; }
fixture429() { # name -> transcript whose last record is a 429 lockout
    f="$FIXTURES/$1"
    {
        echo '{"type":"user","message":{"role":"user","content":"hello"}}'
        echo '{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","message":{"role":"assistant","content":"rate limited"}}'
    } > "$f"
    echo "$f"
}

# Builds the rich Stop-hook payload. Args: session five_hour_pct [cwd] [has_rl 1/0] [has_5h 1/0] [use_workspace 1/0]
stopinput() {
    "$PY" - "$@" <<'PYEOF'
import json, sys
session = sys.argv[1]; pct = sys.argv[2]
cwd = sys.argv[3] if len(sys.argv) > 3 else "/tmp"
has_rl = (sys.argv[4] if len(sys.argv) > 4 else "1") == "1"
has_5h = (sys.argv[5] if len(sys.argv) > 5 else "1") == "1"
use_ws = (sys.argv[6] if len(sys.argv) > 6 else "0") == "1"
h = {"session_id": session, "hook_event_name": "Stop", "transcript_path": "x"}
if use_ws:
    h["workspace"] = {"current_dir": cwd}
else:
    h["cwd"] = cwd
if has_rl:
    rl = {}
    if has_5h:
        rl["five_hour"] = {"used_percentage": float(pct), "resets_at": 1738425600}
    rl["seven_day"] = {"used_percentage": 41.2, "resets_at": 1738857600}
    h["rate_limits"] = rl
print(json.dumps(h))
PYEOF
}

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

# ---- Plan-usage trigger (Stop hook reads rate_limits.five_hour.used_percentage) ----

s=sp-below; clearlock $s
out=$(invoke "$(stopinput $s 85 "$FIXTURES")"); [ -z "$out" ]; assert $? "plan 85% stays silent (below 90)"; clearlock $s

s=sp-90; clearlock $s
out=$(invoke "$(stopinput $s 90 "$FIXTURES")")
[ -n "$out" ]; assert $? "plan 90% fires (inclusive)"
echo "$out" | grep -qi 'plan'; assert $? "message names the plan limit"
echo "$out" | grep -q '90'; assert $? "message reports the plan percentage"; clearlock $s

s=sp-925; clearlock $s
out=$(invoke "$(stopinput $s 92.5 "$FIXTURES")")
[ -n "$out" ]; assert $? "plan 92.5% fires"
echo "$out" | grep -q '92'; assert $? "fractional percentage reported"; clearlock $s

s=sp-none; clearlock $s
out=$(invoke "$(stopinput $s 99 "$FIXTURES" 0)"); [ -z "$out" ]; assert $? "no rate_limits stays silent (graceful)"; clearlock $s

s=sp-no5h; clearlock $s
out=$(invoke "$(stopinput $s 99 "$FIXTURES" 1 0)"); [ -z "$out" ]; assert $? "missing five_hour window stays silent"; clearlock $s

s=sp-env; clearlock $s
out=$(printf '%s' "$(stopinput $s 60 "$FIXTURES")" | RELAY_PLAN_THRESHOLD=50 "$PY" "$TRIGGER")
[ -n "$out" ]; assert $? "RELAY_PLAN_THRESHOLD override fires at 60% when lowered to 50"; clearlock $s

s=sp-lock; clearlock $s
invoke "$(stopinput $s 95 "$FIXTURES")" >/dev/null
out=$(invoke "$(stopinput $s 95 "$FIXTURES")"); [ -z "$out" ]; assert $? "second plan crossing stays silent (lock)"; clearlock $s

s=sp-workspace; clearlock $s
out=$(invoke "$(stopinput $s 95 "$FIXTURES" 1 1 1)")
[ -n "$out" ]; assert $? "plan fires using workspace.current_dir when cwd absent"
echo "$out" | grep -qF 'handoffs'; assert $? "workspace.current_dir used for handoff path"; clearlock $s

# ---- Lockout auto-recovery (429 in transcript -> spawn a LOCAL handoff) ----
export RELAY_NO_SPAWN=1

s=r-429; clearlock $s
t=$(fixture429 lockout1.jsonl)
invoke "$(hookinput "$t" $s UserPromptSubmit)" >/dev/null
[ -f "$LOCKDIR/$s.recovered" ]; assert $? "429 in transcript triggers local recovery"
grep -q 'handoffs' "$LOCKDIR/$s.recovered" 2>/dev/null; assert $? "recover-lock records the handoff output path"
clearlock $s

s=r-normal; clearlock $s
t=$(fixture r-no429.jsonl 50000)
invoke "$(hookinput "$t" $s UserPromptSubmit)" >/dev/null
[ ! -f "$LOCKDIR/$s.recovered" ]; assert $? "no 429 -> no recovery"
clearlock $s

s=r-stop; clearlock $s
t=$(fixture429 lockout2.jsonl)
invoke "$(hookinput "$t" $s Stop)" >/dev/null
[ -f "$LOCKDIR/$s.recovered" ]; assert $? "429 detected on Stop event too"
clearlock $s

s=r-idem; clearlock $s
mkdir -p "$LOCKDIR"; echo existing > "$LOCKDIR/$s.recovered"
t=$(fixture429 lockout3.jsonl)
invoke "$(hookinput "$t" $s UserPromptSubmit)" >/dev/null
[ "$(cat "$LOCKDIR/$s.recovered")" = "existing" ]; assert $? "already-recovered session does not re-trigger"
clearlock $s

s=r-off; clearlock $s
t=$(fixture429 lockout4.jsonl)
printf '%s' "$(hookinput "$t" $s UserPromptSubmit)" | RELAY_AUTO_RECOVER=0 "$PY" "$TRIGGER" >/dev/null
[ ! -f "$LOCKDIR/$s.recovered" ]; assert $? "RELAY_AUTO_RECOVER=0 disables recovery"
clearlock $s

# --- Hardening: precise detection (success after 429 = already recovered) ---
s=r-recovered; clearlock $s
fp="$FIXTURES/lockout-recovered.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"hi"}}'
  echo '{"type":"assistant","apiErrorStatus":429,"error":"rate_limit","message":{"content":"limited"}}'
  echo '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":100,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}'
} > "$fp"
invoke "$(hookinput "$fp" $s UserPromptSubmit)" >/dev/null
[ ! -f "$LOCKDIR/$s.recovered" ]; assert $? "success after 429 = recovered -> no recovery (precise detection)"
clearlock $s

# --- Hardening: broadened detection (rate_limit_error type) ---
s=r-rlerr; clearlock $s
fp="$FIXTURES/lockout-type.jsonl"
{ echo '{"type":"user","message":{"content":"hi"}}'; echo '{"type":"rate_limit_error","message":{"content":"limited"}}'; } > "$fp"
invoke "$(hookinput "$fp" $s UserPromptSubmit)" >/dev/null
[ -f "$LOCKDIR/$s.recovered" ]; assert $? "type=rate_limit_error triggers recovery (broadened detection)"
clearlock $s

# --- Hardening: broadened detection (over_quota) ---
s=r-quota; clearlock $s
fp="$FIXTURES/lockout-quota.jsonl"
{ echo '{"type":"user","message":{"content":"hi"}}'; echo '{"type":"assistant","error":"over_quota","message":{"content":"limited"}}'; } > "$fp"
invoke "$(hookinput "$fp" $s UserPromptSubmit)" >/dev/null
[ -f "$LOCKDIR/$s.recovered" ]; assert $? "error=over_quota triggers recovery (broadened detection)"
clearlock $s

# --- Hardening: Ollama unreachable at lockout -> no lock (retries later) ---
s=r-nollama; clearlock $s
fp=$(fixture429 lockout-nollama.jsonl)
unset RELAY_NO_SPAWN
printf '%s' "$(hookinput "$fp" $s UserPromptSubmit)" | RELAY_OLLAMA_URL=http://127.0.0.1:9 "$PY" "$TRIGGER" >/dev/null
export RELAY_NO_SPAWN=1
[ ! -f "$LOCKDIR/$s.recovered" ]; assert $? "Ollama unreachable at lockout -> no lock (will retry)"
clearlock $s

unset RELAY_NO_SPAWN

echo "--------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
