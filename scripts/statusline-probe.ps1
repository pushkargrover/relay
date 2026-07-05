# statusline-probe.ps1 - TEMPORARY diagnostic.
# Claude Code passes the rich session JSON (including rate_limits, for Pro/Max)
# to the statusLine command on stdin. This probe dumps that JSON to a file and
# prints the 5-hour plan % to the status bar, to confirm whether the DESKTOP APP
# actually provides rate_limits to statusline (hooks do not receive it).
$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
$dbgDir = Join-Path $env:USERPROFILE '.claude\handoffs'
if (-not (Test-Path $dbgDir)) { New-Item -ItemType Directory -Force -Path $dbgDir | Out-Null }
Set-Content -Path (Join-Path $dbgDir '.relay-statusline-dump.json') -Value $raw -Encoding utf8
try {
    $j = $raw | ConvertFrom-Json
    $pct = $j.rate_limits.five_hour.used_percentage
    if ($null -ne $pct) { Write-Output "relay probe: 5h plan = $pct%" }
    else { Write-Output "relay probe: rate_limits ABSENT in statusline too" }
} catch {
    Write-Output "relay probe: (could not parse stdin)"
}
