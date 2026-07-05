# run-tests.ps1 - unit tests for scripts/trigger.ps1 (token-budget triggering)
# Usage:  powershell -NoProfile -File tests\run-tests.ps1
# Exit code 0 = all pass, 1 = failures.

$ErrorActionPreference = 'Stop'
# Pin the environment: a leaked budget override would corrupt boundary asserts.
foreach ($v in 'RELAY_TOKEN_THRESHOLD','RELAY_EMERGENCY_TOKEN_THRESHOLD','RELAY_PLAN_THRESHOLD','RELAY_DEBUG','RELAY_AUTO_RECOVER','RELAY_NO_SPAWN') {
    if (Test-Path "env:$v") { Remove-Item "env:$v" }
}
$trigger  = Join-Path $PSScriptRoot '..\scripts\trigger.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$lockDir  = Join-Path $env:USERPROFILE '.claude\handoffs\.locks'
if (-not (Test-Path $fixtures)) { New-Item -ItemType Directory -Force -Path $fixtures | Out-Null }

# Defaults the trigger uses (mirror them here for readable assertions).
$NORMAL = 150000
$EMERG  = 190000

$script:passed = 0; $script:failed = 0

function Invoke-Trigger([string]$hookInputJson) {
    return ($hookInputJson | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger)
}
function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:passed++; Write-Host "  PASS  $name" }
    else       { $script:failed++; Write-Host "  FAIL  $name" -ForegroundColor Red }
}

function New-Fixture([string]$name, [long]$totalTokens, [string[]]$extraLines) {
    # Splits totalTokens across input + cache fields so the trigger's sum matches.
    $path = Join-Path $fixtures $name
    $inp = [Math]::Max(0, $totalTokens - 2000)
    $lines = @(
        '{"type":"user","message":{"role":"user","content":"hello"}}'
        ('{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":' + $inp + ',"cache_read_input_tokens":1000,"cache_creation_input_tokens":1000,"output_tokens":500}}}')
    ) + $extraLines
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8
    return $path
}
function New-HookInput([string]$transcript, [string]$session, [string]$event, [string]$cwd = $env:TEMP) {
    return ([ordered]@{ session_id = $session; transcript_path = $transcript; cwd = $cwd; hook_event_name = $event } | ConvertTo-Json -Compress)
}
function Clear-Lock([string]$session) {
    foreach ($ext in 'lock','last','recovered') {
        $f = Join-Path $lockDir "$session.$ext"
        if (Test-Path $f) { Remove-Item $f -Force -Confirm:$false }
    }
}
function New-Fixture429([string]$name) {
    # Transcript whose most recent record is a rate-limit / 429 lockout error.
    $path = Join-Path $fixtures $name
    $lines = @(
        '{"type":"user","message":{"role":"user","content":"hello"}}'
        '{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","message":{"role":"assistant","content":"rate limited"}}'
    )
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8
    return $path
}
function RecLock([string]$session) { Join-Path $lockDir "$session.recovered" }
function New-StopInput([string]$session, $fiveHourPct, [string]$cwd = $env:TEMP,
                       [bool]$hasRateLimits = $true, [bool]$hasFiveHour = $true, [bool]$useWorkspace = $false) {
    # Builds the rich Stop-hook payload (per official Claude Code statusline schema).
    $h = [ordered]@{ session_id = $session; hook_event_name = 'Stop'; transcript_path = 'x' }
    if ($useWorkspace) { $h.workspace = @{ current_dir = $cwd } } else { $h.cwd = $cwd }
    if ($hasRateLimits) {
        $rl = [ordered]@{}
        if ($hasFiveHour) { $rl.five_hour = @{ used_percentage = $fiveHourPct; resets_at = 1738425600 } }
        $rl.seven_day = @{ used_percentage = 41.2; resets_at = 1738857600 }
        $h.rate_limits = $rl
    }
    return ($h | ConvertTo-Json -Depth 6 -Compress)
}

Write-Host "relay trigger tests (token budgets: normal=$NORMAL emergency=$EMERG)"
Write-Host "-----------------------------"

# 1: below the normal budget -> silent
$s='t-below'; Clear-Lock $s
$t = New-Fixture 'tok-100k.jsonl' 100000 @()
Assert (-not (Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit'))) "100k tokens stays silent"; Clear-Lock $s

# 2: just below (boundary) -> silent
$s='t-149'; Clear-Lock $s
$t = New-Fixture 'tok-149k.jsonl' 149000 @()
Assert (-not (Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit'))) "149k stays silent (just below budget)"; Clear-Lock $s

# 3: exactly at budget -> fires (inclusive)
$s='t-150'; Clear-Lock $s
$t = New-Fixture 'tok-150k.jsonl' 150000 @()
Assert ([bool](Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit'))) "exactly 150k fires (inclusive)"; Clear-Lock $s

# 4: above budget -> fires, message reports the token count + handoff path
$s='t-151'; Clear-Lock $s
$t = New-Fixture 'tok-151k.jsonl' 151000 @()
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "151k fires"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '151,000 tokens') "message reports token count (not a percentage)"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match 'handoff-\d{4}') "message contains a timestamped handoff path"
Assert ($json -and $json.hookSpecificOutput.additionalContext -notmatch '%') "message contains no bogus percentage"

# 5: lock prevents a second fire
$t = New-Fixture 'tok-200k.jsonl' 200000 @()
Assert (-not (Invoke-Trigger (New-HookInput $t 't-151' 'UserPromptSubmit'))) "second crossing stays silent (lock)"; Clear-Lock 't-151'

# 6: PreCompact backstop fires even at low tokens
$s='t-precompact'; Clear-Lock $s
$t = New-Fixture 'tok-low.jsonl' 20000 @()
Assert ([bool](Invoke-Trigger (New-HookInput $t $s 'PreCompact'))) "PreCompact fires even at low tokens"; Clear-Lock $s

# 7: truncated last line tolerated
$s='t-midwrite'; Clear-Lock $s
$t = New-Fixture 'tok-midwrite.jsonl' 151000 @('{"type":"assistant","message":{"usage":{"input_tokens":')
Assert ([bool](Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit'))) "truncated last line skipped, prior record used"; Clear-Lock $s

# 8: PostToolUse stays silent between normal and emergency budgets (KEY)
$s='t-ptu-quiet'; Clear-Lock $s
$t = New-Fixture 'tok-160k.jsonl' 160000 @()   # above 150k, below 190k
Assert (-not (Invoke-Trigger (New-HookInput $t $s 'PostToolUse'))) "PostToolUse silent at 160k (below 190k emergency)"; Clear-Lock $s

# 9: PostToolUse fires at/above emergency budget, labelled mid-task
$s='t-ptu-fire'; Clear-Lock $s
$t = New-Fixture 'tok-195k.jsonl' 195000 @()
$out = Invoke-Trigger (New-HookInput $t $s 'PostToolUse')
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "PostToolUse fires at 195k"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match 'mid-task') "emergency message labelled mid-task"; Clear-Lock $s

# 10: PostToolUse throttle - a recent check is skipped
$s='t-throttle'; Clear-Lock $s
if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Set-Content -Path (Join-Path $lockDir "$s.last") -Value $now -Encoding ascii
$t = New-Fixture 'tok-throttle.jsonl' 200000 @()
Assert (-not (Invoke-Trigger (New-HookInput $t $s 'PostToolUse'))) "PostToolUse throttled when checked recently"
# clear the stamp -> now it fires
Remove-Item (Join-Path $lockDir "$s.last") -Force
Assert ([bool](Invoke-Trigger (New-HookInput $t $s 'PostToolUse'))) "PostToolUse fires once throttle window passes"; Clear-Lock $s

# 11: RELAY_TOKEN_THRESHOLD override
$s='t-env'; Clear-Lock $s
$t = New-Fixture 'tok-60k.jsonl' 60000 @()
$env:RELAY_TOKEN_THRESHOLD = '50000'
$out = $(New-HookInput $t $s 'UserPromptSubmit') | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger
Remove-Item env:RELAY_TOKEN_THRESHOLD
Assert ([bool]$out) "RELAY_TOKEN_THRESHOLD override fires at 60k when budget lowered to 50k"; Clear-Lock $s

# 12: home-dir session -> central .claude\handoffs
$s='t-home'; Clear-Lock $s
$t = New-Fixture 'tok-home.jsonl' 151000 @()
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit' $env:USERPROFILE)
$json = $out | ConvertFrom-Json
Assert ($json.hookSpecificOutput.additionalContext -match '\.claude\\handoffs') "home-dir session saves to central .claude\handoffs"; Clear-Lock $s

# 13: project session -> project-local handoffs
$s='t-proj'; Clear-Lock $s
$t = New-Fixture 'tok-proj.jsonl' 151000 @()
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit' $env:TEMP)
$json = $out | ConvertFrom-Json
Assert ($json.hookSpecificOutput.additionalContext -match [regex]::Escape((Join-Path $env:TEMP 'handoffs'))) "project session saves to project-local handoffs"; Clear-Lock $s

# 14: missing transcript / garbage stdin -> silent, exit 0
$s='t-notx'; Clear-Lock $s
$out = Invoke-Trigger (New-HookInput 'C:\does\not\exist.jsonl' $s 'UserPromptSubmit')
Assert (-not $out) "missing transcript stays silent"
Assert ($LASTEXITCODE -eq 0) "missing transcript exits 0"
$out = 'not-json' | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger
Assert (-not $out) "garbage stdin stays silent"
Assert ($LASTEXITCODE -eq 0) "garbage stdin exits 0"

# ---- Plan-usage trigger (Stop hook reads rate_limits.five_hour.used_percentage) ----

# P1: below the plan threshold -> silent
$s='p-below'; Clear-Lock $s
Assert (-not (Invoke-Trigger (New-StopInput $s 85))) "plan 85% stays silent (below 90)"; Clear-Lock $s

# P2: exactly at threshold -> fires (inclusive), message names the 5-hour plan limit
$s='p-90'; Clear-Lock $s
$out = Invoke-Trigger (New-StopInput $s 90)
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "plan 90% fires (inclusive)"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '(?i)plan') "message names the plan limit"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '90') "message reports the plan percentage"; Clear-Lock $s

# P3: fractional percentage above threshold -> fires
$s='p-925'; Clear-Lock $s
$out = Invoke-Trigger (New-StopInput $s 92.5)
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "plan 92.5% fires"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '92') "fractional percentage reported"; Clear-Lock $s

# P4: rate_limits absent (not Pro/Max, or before first API response) -> silent
$s='p-none'; Clear-Lock $s
Assert (-not (Invoke-Trigger (New-StopInput $s 99 $env:TEMP $false))) "no rate_limits stays silent (graceful)"; Clear-Lock $s

# P5: rate_limits present but five_hour window absent -> silent
$s='p-no5h'; Clear-Lock $s
Assert (-not (Invoke-Trigger (New-StopInput $s 99 $env:TEMP $true $false))) "missing five_hour window stays silent"; Clear-Lock $s

# P6: RELAY_PLAN_THRESHOLD override
$s='p-env'; Clear-Lock $s
$env:RELAY_PLAN_THRESHOLD = '50'
$out = $(New-StopInput $s 60) | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger
Remove-Item env:RELAY_PLAN_THRESHOLD
Assert ([bool]$out) "RELAY_PLAN_THRESHOLD override fires at 60% when lowered to 50"; Clear-Lock $s

# P7: fires once per session (shared lock)
$s='p-lock'; Clear-Lock $s
Invoke-Trigger (New-StopInput $s 95) | Out-Null
Assert (-not (Invoke-Trigger (New-StopInput $s 95))) "second plan crossing stays silent (lock)"; Clear-Lock $s

# P8: falls back to workspace.current_dir when cwd is absent
$s='p-workspace'; Clear-Lock $s
$out = Invoke-Trigger (New-StopInput $s 95 $env:TEMP $true $true $true)
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "plan fires using workspace.current_dir when cwd absent"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match [regex]::Escape((Join-Path $env:TEMP 'handoffs'))) "workspace.current_dir used for handoff path"; Clear-Lock $s

# ---- Lockout auto-recovery (429 in transcript -> spawn a LOCAL handoff) ----
# RELAY_NO_SPAWN=1 lets us verify the decision without launching Ollama.
$env:RELAY_NO_SPAWN = '1'

# R1: a 429 in the transcript triggers local recovery (recover-lock written)
$s='r-429'; Clear-Lock $s
$t = New-Fixture429 'lockout1.jsonl'
Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit') | Out-Null
Assert (Test-Path (RecLock $s)) "429 in transcript triggers local recovery"
Assert ((Test-Path (RecLock $s)) -and ((Get-Content (RecLock $s) -Raw) -match 'handoffs')) "recover-lock records the handoff output path"
Clear-Lock $s

# R2: a normal transcript (no 429) does not trigger recovery
$s='r-normal'; Clear-Lock $s
$t = New-Fixture 'r-no429.jsonl' 50000 @()
Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit') | Out-Null
Assert (-not (Test-Path (RecLock $s))) "no 429 -> no recovery"
Clear-Lock $s

# R3: the 429 is also detected on the Stop event
$s='r-stop'; Clear-Lock $s
$t = New-Fixture429 'lockout2.jsonl'
Invoke-Trigger (New-HookInput $t $s 'Stop') | Out-Null
Assert (Test-Path (RecLock $s)) "429 detected on Stop event too"
Clear-Lock $s

# R4: a session already recovered does not re-trigger (idempotent)
$s='r-idem'; Clear-Lock $s
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
Set-Content (RecLock $s) 'existing' -Encoding ascii
$t = New-Fixture429 'lockout3.jsonl'
Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit') | Out-Null
Assert ((Test-Path (RecLock $s)) -and (((Get-Content (RecLock $s) -Raw).Trim()) -eq 'existing')) "already-recovered session does not re-trigger"
Clear-Lock $s

# R5: RELAY_AUTO_RECOVER=0 disables auto-recovery
$s='r-off'; Clear-Lock $s
$t = New-Fixture429 'lockout4.jsonl'
$env:RELAY_AUTO_RECOVER = '0'
$(New-HookInput $t $s 'UserPromptSubmit') | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger | Out-Null
Remove-Item env:RELAY_AUTO_RECOVER
Assert (-not (Test-Path (RecLock $s))) "RELAY_AUTO_RECOVER=0 disables recovery"
Clear-Lock $s

Remove-Item env:RELAY_NO_SPAWN -ErrorAction SilentlyContinue

Write-Host "-----------------------------"
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
