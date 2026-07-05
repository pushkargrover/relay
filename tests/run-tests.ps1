# run-tests.ps1 - unit tests for scripts/trigger.ps1 (token-budget triggering)
# Usage:  powershell -NoProfile -File tests\run-tests.ps1
# Exit code 0 = all pass, 1 = failures.

$ErrorActionPreference = 'Stop'
# Pin the environment: a leaked budget override would corrupt boundary asserts.
foreach ($v in 'RELAY_TOKEN_THRESHOLD','RELAY_EMERGENCY_TOKEN_THRESHOLD') {
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
    foreach ($ext in 'lock','last') {
        $f = Join-Path $lockDir "$session.$ext"
        if (Test-Path $f) { Remove-Item $f -Force -Confirm:$false }
    }
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

Write-Host "-----------------------------"
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
