# trigger.ps1 - Relay plugin
#
# Runs on two hook events (routed via hooks.json):
#   UserPromptSubmit - every user turn: read real token usage from the session
#                      transcript (JSONL) and fire a handoff instruction at >=90%.
#   PreCompact       - backstop: if compaction is imminent and no handoff was
#                      written this session, fire unconditionally.
#
# Contract with Claude Code:
#   stdin  : JSON  { session_id, transcript_path, cwd, hook_event_name, ... }
#   stdout : JSON  { hookSpecificOutput.additionalContext } to inject context,
#            or nothing when there is nothing to do.
#   Exit 0 always — a monitoring hook must never block the user's prompt.

param()
$ErrorActionPreference = 'Stop'

# The threshold as a fraction of the model's context window.
# Override with env var RELAY_THRESHOLD (e.g. "0.80"), useful for
# users who want earlier handoffs and for end-to-end testing.
$Threshold = 0.90
if ($env:RELAY_THRESHOLD) {
    $parsed = 0.0
    if ([double]::TryParse($env:RELAY_THRESHOLD, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 1) {
        $Threshold = $parsed
    }
}
# Emergency threshold used ONLY for the mid-task PostToolUse check. It is higher
# so a long task is interrupted to write a handoff only when truly close to the
# wall. Override with env var RELAY_EMERGENCY_THRESHOLD (e.g. "0.97").
$EmergencyThreshold = 0.95
if ($env:RELAY_EMERGENCY_THRESHOLD) {
    $parsedE = 0.0
    if ([double]::TryParse($env:RELAY_EMERGENCY_THRESHOLD, [ref]$parsedE) -and $parsedE -gt 0 -and $parsedE -le 1) {
        $EmergencyThreshold = $parsedE
    }
}
# How many trailing transcript lines to scan for the newest usage record.
# Usage appears on every assistant message, so a small tail is always enough.
$TailLines = 100

function Get-Prop($obj, $name) {
    # Safe property access on PSCustomObject (works under any StrictMode).
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

    # ---- 2. Once-per-session lock -------------------------------------------
    # A session hovering around the threshold must not spam handoff files.
    $lockDir  = Join-Path $env:USERPROFILE '.claude\handoffs\.locks'
    $lockFile = Join-Path $lockDir "$sessionId.lock"
    if (Test-Path $lockFile) { exit 0 }

    # ---- 3. Decide whether to fire -------------------------------------------
    $shouldFire = $false
    $usagePct   = $null

    if ($eventName -eq 'PreCompact') {
        # Backstop: compaction is about to erase context. Always fire.
        $shouldFire = $true
    }
    else {
        # Per-turn check: read the newest assistant usage record.
        if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }

        $lines = Get-Content -Path $transcriptPath -Tail $TailLines -ErrorAction Stop
        $model = $null
        $contextTokens = $null

        # Scan newest-first; the latest assistant message's usage reflects the
        # full current context (each API request re-sends the whole conversation).
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if (-not $line -or -not $line.Trim()) { continue }
            try { $rec = $line | ConvertFrom-Json } catch { continue }  # tolerate a mid-write partial line

            $msg = Get-Prop $rec 'message'
            $usage = Get-Prop $msg 'usage'
            if ($null -eq $usage) { continue }

            $in    = Get-Prop $usage 'input_tokens'
            $cRead = Get-Prop $usage 'cache_read_input_tokens'
            $cNew  = Get-Prop $usage 'cache_creation_input_tokens'
            # [long]$null coerces to 0, so missing cache fields are safe.
            $contextTokens = [long]$in + [long]$cRead + [long]$cNew
            $model = Get-Prop $msg 'model'
            break
        }

        if ($null -eq $contextTokens -or $contextTokens -le 0) { exit 0 }

        # Resolve the context limit: longest matching model prefix wins.
        $limitsPath = Join-Path $PSScriptRoot 'context-limits.json'
        $limit = 200000
        if (Test-Path $limitsPath) {
            $cfg = (Get-Content $limitsPath -Raw | ConvertFrom-Json)
            $limits = Get-Prop $cfg 'limits'
            if ($limits) {
                $best = ''
                foreach ($p in $limits.PSObject.Properties) {
                    if ($p.Name -ne '_default' -and $model -and $model.StartsWith($p.Name) -and $p.Name.Length -gt $best.Length) {
                        $best = $p.Name
                    }
                }
                if ($best) { $limit = [long]$limits.PSObject.Properties[$best].Value }
                elseif ($limits.PSObject.Properties['_default']) { $limit = [long]$limits.PSObject.Properties['_default'].Value }
            }
        }

        $usagePct = [math]::Round(($contextTokens / $limit) * 100, 1)
        # PostToolUse is the mid-task check: use the higher emergency threshold so
        # we interrupt an in-progress task only when close to the wall. Every other
        # event (UserPromptSubmit) uses the normal turn-boundary threshold.
        $active = if ($eventName -eq 'PostToolUse') { $EmergencyThreshold } else { $Threshold }
        if (($contextTokens / $limit) -ge $active) { $shouldFire = $true }
    }

    if (-not $shouldFire) { exit 0 }

    # ---- 4. Fire: write the lock, then instruct Claude ----------------------
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
    Set-Content -Path $lockFile -Value (Get-Date -Format o) -Encoding ascii

    # Save inside the project when there is one; otherwise use the central
    # ~\.claude\handoffs so we never litter the user's home directory.
    $isRealProject = ($projectDir -and (Test-Path $projectDir) -and
                      ($projectDir.TrimEnd('\') -ne $env:USERPROFILE.TrimEnd('\')))
    if ($isRealProject) {
        $handoffsDir = Join-Path $projectDir 'handoffs'
    } else {
        $handoffsDir = Join-Path $env:USERPROFILE '.claude\handoffs'
    }
    $timestamp   = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $handoffFile = Join-Path $handoffsDir "handoff-$timestamp.md"
    $reason = if ($eventName -eq 'PreCompact') { 'Context compaction is imminent.' }
              elseif ($eventName -eq 'PostToolUse') { "Context usage has reached $usagePct% mid-task (emergency threshold)." }
              else { "Context usage has reached $usagePct% of the window." }

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
    # A monitor must never break the session it monitors.
    exit 0
}
