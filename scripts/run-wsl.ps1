#Requires -Version 5.1
<#
  run-wsl.ps1 - run one of the bash scripts in this folder inside WSL.

  Why a wrapper: bash refuses CRLF files ("$'\r': command not found"). This
  copies the script to %TEMP% with LF endings and runs that copy, so you can
  keep editing the originals on Windows without breaking them.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 02-setup-repos.sh
    powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 04-build.sh -ScriptArgs "--steps","kernel package firmware"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string[]]$ScriptArgs = @(),
    [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    exit 2
}

$source = Join-Path $PSScriptRoot $Script
if (-not (Test-Path -LiteralPath $source)) { Fail "script not found: $source" }

$wsl = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
if (-not $wsl) { Fail "wsl.exe not found - run 01-install-wsl.ps1 first" }

# Is the distro installed?  wsl.exe writes UTF-16, so redirect to a file and
# read it back as Unicode instead of parsing the console stream.
$listFile = Join-Path $env:TEMP ('wsl-list-' + [guid]::NewGuid().ToString('N') + '.txt')
& cmd.exe /c "`"$wsl`" -l -q > `"$listFile`" 2>nul" | Out-Null
$dists = @()
if (Test-Path -LiteralPath $listFile) {
    $dists = @(Get-Content -LiteralPath $listFile -Encoding Unicode |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^\s*$' })
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
}
if ($dists -notcontains $Distro) {
    Write-Host "[FAIL] WSL distro '$Distro' not found." -ForegroundColor Red
    Write-Host "       installed: $(if ($dists.Count) { $dists -join ', ' } else { '(none)' })" -ForegroundColor Yellow
    Write-Host "       run 01-install-wsl.ps1 first, then reboot." -ForegroundColor Yellow
    exit 2
}

# Copy with LF endings, UTF-8 without BOM.
$text = [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"

$tempSh = Join-Path $env:TEMP ('unixnu-' + [guid]::NewGuid().ToString('N') + '.sh')
[System.IO.File]::WriteAllText($tempSh, $text, (New-Object System.Text.UTF8Encoding($false)))

$wslPath = (& $wsl -d $Distro -- wslpath -a "$tempSh" 2>$null | Select-Object -First 1)
if (-not $wslPath) {
    Remove-Item -LiteralPath $tempSh -Force -ErrorAction SilentlyContinue
    Fail "could not translate path for WSL: $tempSh"
}
$wslPath = $wslPath.Trim()

Write-Host "[wsl] $Distro :: bash $wslPath $($ScriptArgs -join ' ')" -ForegroundColor Cyan
& $wsl -d $Distro -- bash $wslPath @ScriptArgs
$code = $LASTEXITCODE

Remove-Item -LiteralPath $tempSh -Force -ErrorAction SilentlyContinue
exit $code
