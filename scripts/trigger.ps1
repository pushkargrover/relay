# trigger.ps1 - Relay plugin
#
# Runs on three hook events (routed via hooks.json):
#   UserPromptSubmit - every user turn: fire a handoff once the session's context
#                      reaches the token budget.
#   PostToolUse      - mid-task safety: fire at a higher emergency budget. Throttled
#                      so it does not run the full check after every single tool call.
#   PreCompact       - backstop: fire unconditionally right before compaction. This
#                      is the RELIABLE near-full signal, since Claude Code knows the
#                      true (model-specific) window and we do not.
#
# Why absolute token budgets, not "% of window": the real context window is not
# exposed to hooks (not in the transcript, hook input, CLI, or API), and it varies
# by model (opus-4-8 alone is >400K). Dividing by a hardcoded limit produced wrong
# percentages (e.g. 214%) and mis-timed firing. A token budget is model-agnostic
# and honest; PreCompact covers the true limit for every model.
#
# Contract with Claude Code:
#   stdin  : JSON  { session_id, transcript_path, cwd, hook_event_name, ... }
#   stdout : JSON  { hookSpecificOutput.additionalContext } to inject context,
#            or nothing when there is nothing to do.
#   Exit 0 always - a monitoring hook must never block the user's prompt.

param()
$ErrorActionPreference = 'Stop'

function Get-BudgetEnv([string]$name, [long]$default) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val) {
        $n = 0L
        if ([long]::TryParse($val, [ref]$n) -and $n -gt 0) { return $n }
    }
    return $default
}

# Fire the turn-boundary handoff once context reaches this many tokens.
$TokenThreshold = Get-BudgetEnv 'RELAY_TOKEN_THRESHOLD' 150000
# Higher budget for the mid-task PostToolUse check (interrupt only when close).
$EmergencyTokenThreshold = Get-BudgetEnv 'RELAY_EMERGENCY_TOKEN_THRESHOLD' 190000
# Only scan the tail of the transcript; the newest usage record is near the end.
$TailLines = 40
# Do not run the expensive transcript read more than once per this many seconds
# on PostToolUse (which fires after every tool call).
$ThrottleSeconds = 15

function Get-Prop($obj, $name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

try {
    # ---- 1. Parse hook input from stdin -------------------------------------
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw -or -not $raw.Trim()) { exit 0 }
    try { $hookInput = $raw | ConvertFrom-Json } catch { exit 0 }

    $sessionId      = Get-Prop $hookInput 'session_id'
    $transcriptPath = Get-Prop $hookInput 'transcript_path'
    $projectDir     = Get-Prop $hookInput 'cwd'
    $eventName      = Get-Prop $hookInput 'hook_event_name'
    if (-not $sessionId) { $sessionId = 'unknown' }
    if (-not $projectDir -or -not (Test-Path $projectDir)) { $projectDir = (Get-Location).Path }

    $lockDir  = Join-Path $env:USERPROFILE '.claude\handoffs\.locks'
    $lockFile = Join-Path $lockDir "$sessionId.lock"

    # ---- 2. Once-per-session lock (cheap, before any file read) -------------
    if (Test-Path $lockFile) { exit 0 }

    # ---- 3. Throttle the frequent PostToolUse check -------------------------
    if ($eventName -eq 'PostToolUse') {
        $stampFile = Join-Path $lockDir "$sessionId.last"
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (Test-Path $stampFile) {
            $last = 0L
            [long]::TryParse((Get-Content $stampFile -Raw -ErrorAction SilentlyContinue).Trim(), [ref]$last) | Out-Null
            if (($now - $last) -lt $ThrottleSeconds) { exit 0 }
        }
        if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
        Set-Content -Path $stampFile -Value $now -Encoding ascii
    }

    # ---- 4. Decide whether to fire ------------------------------------------
    $shouldFire = $false
    $contextTokens = $null

    if ($eventName -eq 'PreCompact') {
        $shouldFire = $true   # reliable near-full backstop
    }
    else {
        if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }
        $lines = Get-Content -Path $transcriptPath -Tail $TailLines -ErrorAction Stop
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if (-not $line -or -not $line.Trim()) { continue }
            try { $rec = $line | ConvertFrom-Json } catch { continue }  # tolerate a partial line
            $usage = Get-Prop (Get-Prop $rec 'message') 'usage'
            if ($null -eq $usage) { continue }
            # [long]$null coerces to 0, so missing cache fields are safe.
            $contextTokens = [long](Get-Prop $usage 'input_tokens') +
                             [long](Get-Prop $usage 'cache_read_input_tokens') +
                             [long](Get-Prop $usage 'cache_creation_input_tokens')
            break
        }
        if ($null -eq $contextTokens -or $contextTokens -le 0) { exit 0 }
        $budget = if ($eventName -eq 'PostToolUse') { $EmergencyTokenThreshold } else { $TokenThreshold }
        if ($contextTokens -ge $budget) { $shouldFire = $true }
    }

    if (-not $shouldFire) { exit 0 }

    # ---- 5. Fire: write the lock, then instruct Claude ----------------------
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
    Set-Content -Path $lockFile -Value (Get-Date -Format o) -Encoding ascii

    $handoffsDir = Join-Path $projectDir 'handoffs'
    $isRealProject = ($projectDir -and (Test-Path $projectDir) -and
                      ($projectDir.TrimEnd('\') -ne $env:USERPROFILE.TrimEnd('\')))
    if (-not $isRealProject) { $handoffsDir = Join-Path $env:USERPROFILE '.claude\handoffs' }

    $timestamp   = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $handoffFile = Join-Path $handoffsDir "handoff-$timestamp.md"
    $tokenStr = if ($contextTokens) { "{0:N0}" -f $contextTokens } else { 'many' }
    $reason = if ($eventName -eq 'PreCompact') { 'Context compaction is imminent.' }
              elseif ($eventName -eq 'PostToolUse') { "Context has reached $tokenStr tokens mid-task." }
              else { "Context has reached $tokenStr tokens." }

    $instruction = @"
[relay] $reason Before continuing with the user's request, write a session handoff document so progress survives.

1. Create the directory if needed: $handoffsDir
2. Write the handoff to exactly: $handoffFile

Required structure (fill every section from this conversation):

# Context Handoff
**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Project Directory:** $projectDir

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

After writing it, tell the user: "Handoff saved to: $handoffFile" and then continue with their request.
"@

    $out = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = $eventName
            additionalContext = $instruction
        }
    } | ConvertTo-Json -Depth 4 -Compress
    Write-Output $out
    exit 0
}
catch {
    exit 0
}
