# run-tests.ps1 — unit tests for scripts/trigger.ps1
# Usage:  powershell -NoProfile -File tests\run-tests.ps1
# Exit code 0 = all pass, 1 = failures.

$ErrorActionPreference = 'Stop'
# Pin the environment: a leaked threshold override would corrupt every
# boundary assertion below. Tests own their inputs.
if (Test-Path env:RELAY_THRESHOLD) { Remove-Item env:RELAY_THRESHOLD }
if (Test-Path env:RELAY_EMERGENCY_THRESHOLD) { Remove-Item env:RELAY_EMERGENCY_THRESHOLD }
$trigger  = Join-Path $PSScriptRoot '..\scripts\trigger.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$lockDir  = Join-Path $env:USERPROFILE '.claude\handoffs\.locks'
if (-not (Test-Path $fixtures)) { New-Item -ItemType Directory -Force -Path $fixtures | Out-Null }

$script:passed = 0; $script:failed = 0

function Invoke-Trigger([string]$hookInputJson) {
    # Pipe hook input to the script exactly as Claude Code would.
    return ($hookInputJson | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger)
}

function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:passed++; Write-Host "  PASS  $name" }
    else       { $script:failed++; Write-Host "  FAIL  $name" -ForegroundColor Red }
}

function New-Fixture([string]$name, [long]$inputTok, [long]$cacheRead, [long]$cacheNew, [string]$model, [string[]]$extraLines) {
    # Builds a minimal but realistic session JSONL: a user line, an assistant
    # line with usage, and any extra lines the test wants appended after it.
    $path = Join-Path $fixtures $name
    $lines = @(
        '{"type":"user","message":{"role":"user","content":"hello"}}'
        ('{"type":"assistant","message":{"model":"' + $model + '","usage":{"input_tokens":' + $inputTok + ',"cache_read_input_tokens":' + $cacheRead + ',"cache_creation_input_tokens":' + $cacheNew + ',"output_tokens":500}}}')
    ) + $extraLines
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8
    return $path
}

function New-HookInput([string]$transcript, [string]$session, [string]$event, [string]$cwd = $env:TEMP) {
    return ([ordered]@{
        session_id      = $session
        transcript_path = $transcript
        cwd             = $cwd
        hook_event_name = $event
    } | ConvertTo-Json -Compress)
}

function Clear-Lock([string]$session) {
    $f = Join-Path $lockDir "$session.lock"
    if (Test-Path $f) { Remove-Item $f -Force -Confirm:$false }
}

Write-Host "relay trigger tests"
Write-Host "-----------------------------"

# --- Case 1: 50% usage -> silent ---------------------------------------------
$s = "test-50pct"; Clear-Lock $s
$t = New-Fixture 'usage-50.jsonl' 3000 94000 3000 'claude-opus-4-8' @()   # 100,000 / 200,000
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
Assert (-not $out) "50% usage stays silent"
Clear-Lock $s

# --- Case 2: 89.0% usage -> silent (boundary, below) -------------------------
$s = "test-89pct"; Clear-Lock $s
$t = New-Fixture 'usage-89.jsonl' 3000 172000 3000 'claude-opus-4-8' @()  # 178,000 = 89.0%
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
Assert (-not $out) "89% usage stays silent"
Clear-Lock $s

# --- Case 3: 91% usage -> fires (boundary, above) -----------------------------
$s = "test-91pct"; Clear-Lock $s
$t = New-Fixture 'usage-91.jsonl' 3000 176000 3000 'claude-opus-4-8' @()  # 182,000 = 91.0%
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "91% usage fires"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '91') "fire message reports the percentage"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match 'handoff-\d{4}') "fire message contains a timestamped handoff path"

# --- Case 4: exact 90% -> fires (>= threshold, not >) -------------------------
$s = "test-90pct"; Clear-Lock $s
$t = New-Fixture 'usage-90.jsonl' 3000 174000 3000 'claude-opus-4-8' @()  # 180,000 = 90.0%
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
Assert ([bool]$out) "exactly 90% fires (inclusive threshold)"
Clear-Lock $s

# --- Case 5: lock prevents second fire ----------------------------------------
# Reuse test-91pct's session: its lock was written by case 3.
$t = New-Fixture 'usage-91b.jsonl' 3000 180000 3000 'claude-opus-4-8' @()
$out = Invoke-Trigger (New-HookInput $t 'test-91pct' 'UserPromptSubmit')
Assert (-not $out) "second crossing in same session stays silent (lock)"
Clear-Lock 'test-91pct'

# --- Case 6: PreCompact backstop always fires ---------------------------------
$s = "test-precompact"; Clear-Lock $s
$t = New-Fixture 'usage-low.jsonl' 3000 40000 3000 'claude-opus-4-8' @()  # only 23%
$out = Invoke-Trigger (New-HookInput $t $s 'PreCompact')
Assert ([bool]$out) "PreCompact fires even at low usage"
Clear-Lock $s

# --- Case 7: malformed trailing line (mid-write) is tolerated ------------------
$s = "test-midwrite"; Clear-Lock $s
$t = New-Fixture 'usage-midwrite.jsonl' 3000 176000 3000 'claude-opus-4-8' @('{"type":"assistant","message":{"usage":{"input_tokens":')
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
Assert ([bool]$out) "truncated last line skipped, prior record used"
Clear-Lock $s

# --- Case 8: unknown model falls back to default limit -------------------------
$s = "test-unknown-model"; Clear-Lock $s
$t = New-Fixture 'usage-unknown.jsonl' 3000 176000 3000 'totally-new-model-9000' @()  # 91% of default
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit')
Assert ([bool]$out) "unknown model uses _default limit and still fires"
Clear-Lock $s

# --- Case 9: missing transcript -> silent, exit 0 -------------------------------
$s = "test-notranscript"; Clear-Lock $s
$out = Invoke-Trigger (New-HookInput 'C:\does\not\exist.jsonl' $s 'UserPromptSubmit')
Assert (-not $out) "missing transcript stays silent"
Assert ($LASTEXITCODE -eq 0) "missing transcript exits 0 (never blocks the user)"

# --- Case 9b: PostToolUse stays silent below the emergency threshold ----------
# 91% is past the 90% turn-boundary bar but below the 95% mid-task bar, so a
# mid-task check must NOT interrupt here.
$s = "test-posttool-quiet"; Clear-Lock $s
$t = New-Fixture 'usage-ptu-91.jsonl' 3000 176000 3000 'claude-opus-4-8' @()  # 91%
$out = Invoke-Trigger (New-HookInput $t $s 'PostToolUse')
Assert (-not $out) "PostToolUse stays silent at 91% (below 95% emergency)"
Clear-Lock $s

# --- Case 9c: PostToolUse fires at/above the emergency threshold --------------
$s = "test-posttool-fire"; Clear-Lock $s
$t = New-Fixture 'usage-ptu-96.jsonl' 3000 189000 3000 'claude-opus-4-8' @()  # 192,000 = 96%
$out = Invoke-Trigger (New-HookInput $t $s 'PostToolUse')
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($null -ne $json) "PostToolUse fires at 96% (mid-task emergency)"
Assert ($json -and $json.hookSpecificOutput.additionalContext -match 'mid-task') "emergency message is labelled mid-task"
Clear-Lock $s

# --- Case 9d: RELAY_EMERGENCY_THRESHOLD override --------------------------------
$s = "test-posttool-env"; Clear-Lock $s
$t = New-Fixture 'usage-ptu-91b.jsonl' 3000 176000 3000 'claude-opus-4-8' @()  # 91%
$env:RELAY_EMERGENCY_THRESHOLD = '0.90'
$out = $(New-HookInput $t $s 'PostToolUse') | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger
Remove-Item env:RELAY_EMERGENCY_THRESHOLD
Assert ([bool]$out) "PostToolUse honors RELAY_EMERGENCY_THRESHOLD override (0.90 fires at 91%)"
Clear-Lock $s

# --- Case 10: no-project session (cwd = home) -> central .claude\handoffs -------
$s = "test-homedir"; Clear-Lock $s
$t = New-Fixture 'usage-home.jsonl' 3000 176000 3000 'claude-opus-4-8' @()
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit' $env:USERPROFILE)
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($json -and $json.hookSpecificOutput.additionalContext -match '\.claude\\handoffs') "home-dir session saves to central .claude\handoffs"
Assert ($json -and $json.hookSpecificOutput.additionalContext -notmatch [regex]::Escape("$env:USERPROFILE\handoffs")) "home-dir session does not litter the home folder"
Clear-Lock $s

# --- Case 11: project session -> project-local handoffs -------------------------
$s = "test-projdir"; Clear-Lock $s
$t = New-Fixture 'usage-proj.jsonl' 3000 176000 3000 'claude-opus-4-8' @()
$out = Invoke-Trigger (New-HookInput $t $s 'UserPromptSubmit' $env:TEMP)
$json = $null; try { $json = $out | ConvertFrom-Json } catch {}
Assert ($json -and $json.hookSpecificOutput.additionalContext -match [regex]::Escape((Join-Path $env:TEMP 'handoffs'))) "project session saves to project-local handoffs"
Clear-Lock $s

# --- Case 12: garbage stdin -> silent, exit 0 -----------------------------------
$out = 'not-json-at-all' | powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $trigger
Assert (-not $out) "garbage stdin stays silent"
Assert ($LASTEXITCODE -eq 0) "garbage stdin exits 0"

Write-Host "-----------------------------"
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
