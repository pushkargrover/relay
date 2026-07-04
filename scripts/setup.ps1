# setup.ps1 - installs a 'relay-recover' shortcut into the PowerShell profile.
# Run once. Afterwards, 'relay-recover' works from any terminal and always
# resolves the latest installed Relay version (so plugin updates never break it).

$ErrorActionPreference = 'Stop'

$block = @'
# >>> relay-recover >>>
function relay-recover {
    $found = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.claude\plugins') -Recurse -Filter 'relay-recover.ps1' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { Write-Host 'relay: could not find relay-recover.ps1. Is Relay installed?' -ForegroundColor Yellow; return }
    & $found.FullName @args
}
# <<< relay-recover <<<
'@

$profilePath = $PROFILE.CurrentUserAllHosts
$dir = Split-Path $profilePath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$content = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }

# Replace an existing block (idempotent) instead of appending duplicates.
$pattern = '(?s)# >>> relay-recover >>>.*?# <<< relay-recover <<<'
if ($content -match $pattern) {
    $content = [regex]::Replace($content, $pattern, '').TrimEnd()
}
$new = (($content.TrimEnd()) + "`r`n`r`n" + $block + "`r`n").TrimStart()
Set-Content -Path $profilePath -Value $new -Encoding utf8

Write-Host "Installed 'relay-recover' into your PowerShell profile:" -ForegroundColor Green
Write-Host "  $profilePath"
Write-Host ""
Write-Host "Reopen your terminal (or run: . `$PROFILE), then use:" -ForegroundColor Cyan
Write-Host "  relay-recover -List"
Write-Host "  relay-recover"
