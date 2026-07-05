# relay-recover.ps1 - Relay local-mode recovery (Windows)
#
# Generates a session handoff using a LOCAL model via Ollama - no Anthropic
# account, no internet, zero tokens. Built for the lockout case: run it in a
# terminal after Claude stops responding and still get a clean handoff.
#
# Usage:
#   relay-recover.ps1                 Recover the most recent session
#   relay-recover.ps1 -List           List recent sessions to pick from
#   relay-recover.ps1 2               Recover the 2nd most recent session
#   relay-recover.ps1 -Session <id>   Recover a specific session id
#   relay-recover.ps1 -Model <name>   Use a specific Ollama model
#   relay-recover.ps1 -Out <path>     Write the handoff to a specific path
#
# Config (env): RELAY_OLLAMA_MODEL, RELAY_OLLAMA_URL (default http://localhost:11434)

param(
    [Parameter(Position = 0)][string]$Selection,
    [switch]$List,
    [string]$Model,
    [string]$Out,
    [string]$Session,
    [string]$Transcript,
    [string]$LockFile,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$OllamaUrl   = if ($env:RELAY_OLLAMA_URL) { $env:RELAY_OLLAMA_URL.TrimEnd('/') } else { 'http://localhost:11434' }
$ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$MaxChars    = 12000   # transcript budget fed to the local model (keeps it fast + in-context)

# Log to a file so background/detached runs (auto-recovery) are diagnosable.
$script:RecLog = Join-Path $env:USERPROFILE '.claude\handoffs\.relay-recover.log'
function Write-RecLog($m) {
    try {
        $d = Split-Path $script:RecLog -Parent
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $script:RecLog -Value "$(Get-Date -Format o) $m"
    } catch {}
}
function Clear-LockOnFail { if ($LockFile -and (Test-Path $LockFile)) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } }
function Fail($m) { Write-Host $m -ForegroundColor Yellow; Write-RecLog "fail: $m"; Clear-LockOnFail; exit 1 }
# A failed recovery must clear the lock so the next hook fire retries.
trap { Write-RecLog "ERROR: $($_.Exception.Message)"; Clear-LockOnFail; break }

function Show-Usage {
    Get-Content $PSCommandPath | Select-Object -First 18 | ForEach-Object { $_ -replace '^# ?', '' }
}

function Get-Prop($obj, $name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

function Get-RecentTranscripts([int]$count = 15) {
    if (-not (Test-Path $ProjectsDir)) { return @() }
    Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $count
}

function Get-TextFromContent($content) {
    # content may be a plain string or an array of typed blocks.
    if ($null -eq $content) { return '' }
    if ($content -is [string]) { return $content }
    $parts = @()
    foreach ($block in $content) {
        $t = Get-Prop $block 'type'
        switch ($t) {
            'text'        { $parts += (Get-Prop $block 'text') }
            'tool_use'    { $parts += "[used tool: $(Get-Prop $block 'name')]" }
            'tool_result' {
                $c = Get-Prop $block 'content'
                $txt = if ($c -is [string]) { $c } else { (Get-TextFromContent $c) }
                if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) + '...' }
                $parts += "[tool result: $txt]"
            }
        }
    }
    return ($parts -join ' ')
}

function Get-TranscriptMeta($file) {
    $cwd = $null; $snippet = $null; $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $lines = Get-Content -Path $file.FullName -TotalCount 40 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        if (-not $cwd) { $c = Get-Prop $rec 'cwd'; if ($c) { $cwd = $c } }
        if (-not $snippet -and (Get-Prop $rec 'type') -eq 'user') {
            $msg = Get-Prop $rec 'message'
            $txt = (Get-TextFromContent (Get-Prop $msg 'content')).Trim()
            if ($txt -and $txt -notmatch '^\[tool result') {
                $snippet = if ($txt.Length -gt 60) { $txt.Substring(0, 60) + '...' } else { $txt }
            }
        }
        if ($cwd -and $snippet) { break }
    }
    $proj = if ($cwd) { Split-Path $cwd -Leaf } else { '(unknown)' }
    [pscustomobject]@{
        File = $file; SessionId = $sessionId; Cwd = $cwd
        Project = $proj; Snippet = $snippet; Modified = $file.LastWriteTime
    }
}

function Get-CleanConversation($file) {
    $lines = Get-Content -Path $file.FullName -ErrorAction Stop
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        $type = Get-Prop $rec 'type'
        if ($type -ne 'user' -and $type -ne 'assistant') { continue }
        $msg = Get-Prop $rec 'message'
        if (-not $msg) { continue }
        $txt = (Get-TextFromContent (Get-Prop $msg 'content')).Trim()
        if (-not $txt) { continue }
        [void]$sb.AppendLine("$($type.ToUpper()): $txt")
    }
    $full = $sb.ToString()
    # Transcripts can contain raw ANSI escape sequences and control bytes from
    # tool output. Strip them: they break JSON encoding and only confuse the model.
    $full = [regex]::Replace($full, '\x1B\[[0-9;?=]*[A-Za-z]', '')
    $full = [regex]::Replace($full, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    if ($full.Length -le $MaxChars) { return $full }
    # Keep the opening (the goal) and the most recent activity (current state).
    $head = $full.Substring(0, 1500)
    $tail = $full.Substring($full.Length - ($MaxChars - 1500))
    return "$head`n...[middle of session trimmed to fit local model]...`n$tail"
}

function Resolve-Model {
    if ($Model) { return $Model }
    if ($env:RELAY_OLLAMA_MODEL) { return $env:RELAY_OLLAMA_MODEL }
    # Auto-detect: use the first model Ollama has installed.
    try {
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method Get -TimeoutSec 10
        if ($tags.models -and $tags.models.Count -gt 0) { return $tags.models[0].name }
    } catch { }
    throw "No Ollama model found. Set RELAY_OLLAMA_MODEL or run: ollama pull gemma4"
}

function Invoke-Ollama($model, $prompt) {
    # Ollama defaults to a tiny ~4K context window regardless of what the model
    # supports, which starves the output on large transcripts (partial or empty
    # handoffs). Open the window explicitly so there is room for input + output.
    $numCtx = 8192
    if ($env:RELAY_OLLAMA_NUM_CTX) {
        $n = 0
        if ([int]::TryParse($env:RELAY_OLLAMA_NUM_CTX, [ref]$n) -and $n -gt 0) { $numCtx = $n }
    }
    $body = @{ model = $model; prompt = $prompt; stream = $false; options = @{ num_ctx = $numCtx } } | ConvertTo-Json -Depth 5
    # Send as explicit UTF-8 bytes: PS 5.1 encodes a string body as Latin-1,
    # which corrupts any non-ASCII content (emoji, box chars) and breaks the JSON.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $resp = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 600
    return $resp.response
}

function Build-Prompt($convo) {
    return @"
You are writing a session handoff so another AI agent can resume this work. Based ONLY on the conversation below, produce a markdown document with EXACTLY these 8 sections, in this order:

# Session Handoff
## Session Goal
## Decisions Made
## Work Completed
## Current State
## Open Questions / Blockers
## Next Steps
## Key File Paths
## Instructions for Next Agent

Be concise and specific. Use real details from the conversation. Output ONLY the markdown document, no preamble.

CONVERSATION:
$convo
"@
}

# ---- Main ------------------------------------------------------------------
if ($Help) { Show-Usage; exit 0 }

# Verify Ollama is reachable early, with a clear message.
try { Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method Get -TimeoutSec 10 | Out-Null }
catch { Fail "ERROR: Cannot reach Ollama at $OllamaUrl. Is it installed and running? (https://ollama.com)" }

$recent = Get-RecentTranscripts 15
if (-not $Transcript -and (-not $recent -or $recent.Count -eq 0)) { Write-Host "No session transcripts found under $ProjectsDir" -ForegroundColor Yellow; exit 1 }

if ($List) {
    Write-Host "Recent sessions (newest first):`n"
    for ($i = 0; $i -lt $recent.Count; $i++) {
        $m = Get-TranscriptMeta $recent[$i]
        $idx = ($i + 1).ToString().PadLeft(2)
        Write-Host ("  [{0}] {1}  {2}" -f $idx, $m.Modified.ToString('MM-dd HH:mm'), $m.Project) -ForegroundColor Cyan
        if ($m.Snippet) { Write-Host "       `"$($m.Snippet)`"" -ForegroundColor DarkGray }
    }
    Write-Host "`nRun 'relay-recover <number>' to recover one." -ForegroundColor Green
    exit 0
}

# Select which transcript.
$target = $null
if ($Transcript) {
    if (-not (Test-Path $Transcript)) { Fail "Transcript not found: $Transcript" }
    $target = Get-Item $Transcript   # recover this exact file (no session lookup)
} elseif ($Session) {
    $target = $recent | Where-Object { $_.BaseName -eq $Session } | Select-Object -First 1
    if (-not $target) { Fail "Session '$Session' not found in recent transcripts. Try -List." }
} elseif ($Selection) {
    $n = 0
    if (-not [int]::TryParse($Selection, [ref]$n) -or $n -lt 1 -or $n -gt $recent.Count) {
        Write-Host "Invalid selection '$Selection'. Use a number 1-$($recent.Count), or -List." -ForegroundColor Yellow; exit 1
    }
    $target = $recent[$n - 1]
} else {
    $target = $recent[0]   # most recent
}

$meta = Get-TranscriptMeta $target
Write-Host "Recovering session: $($meta.Project)  ($($meta.Modified.ToString('MM-dd HH:mm')))" -ForegroundColor Cyan
if ($meta.Snippet) { Write-Host "  `"$($meta.Snippet)`"" -ForegroundColor DarkGray }

# Resolve output path: current project's handoffs/, else central.
$cwd = (Get-Location).Path
if ($Out) {
    $handoffFile = $Out
    $od = Split-Path $handoffFile -Parent
    if ($od -and -not (Test-Path $od)) { New-Item -ItemType Directory -Force -Path $od | Out-Null }
} else {
    $isRealProject = ($cwd.TrimEnd('\') -ne $env:USERPROFILE.TrimEnd('\'))
    $handoffsDir = if ($isRealProject) { Join-Path $cwd 'handoffs' } else { Join-Path $env:USERPROFILE '.claude\handoffs' }
    if (-not (Test-Path $handoffsDir)) { New-Item -ItemType Directory -Force -Path $handoffsDir | Out-Null }
    $ts = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $handoffFile = Join-Path $handoffsDir "handoff-$ts-local.md"
}
Write-RecLog "start: session=$($meta.SessionId) -> $handoffFile"

$model = Resolve-Model
$convo = Get-CleanConversation $target
if (-not $convo.Trim()) { Fail "That transcript has no readable conversation content." }

Write-Host "Synthesizing with local model '$model' (this can take a couple of minutes)..." -ForegroundColor Cyan
$prompt = Build-Prompt $convo
$markdown = Invoke-Ollama $model $prompt
if (-not $markdown -or -not $markdown.Trim()) { Fail "The local model returned nothing." }

$header = "<!-- Generated locally by Relay via Ollama ($model). Source session: $($meta.SessionId) -->`n`n"
Set-Content -Path $handoffFile -Value ($header + $markdown) -Encoding utf8

Write-Host "`nHandoff saved to: $handoffFile" -ForegroundColor Green
Write-RecLog "ok: $handoffFile"
