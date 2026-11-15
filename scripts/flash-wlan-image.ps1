#Requires -Version 5.1
<#
  flash-wlan-image.ps1 - flash the root image that carries the WLAN firmware area.

  What it writes: ONLY the `userdata` partition (11.3 GB sparse, about 6 minutes).
  The iOS boot chain (boot_a / vendor_boot_a / vbmeta_a) is left untouched.

  Before writing it checks `partition-size:userdata` against the block count the
  image was built for (N = 58672399), because the firmware areas live at fixed
  blocks relative to the end of userdata.

  Usage (phone in bootloader fastboot):
    powershell -ExecutionPolicy Bypass -File scripts\flash-wlan-image.ps1
    powershell -ExecutionPolicy Bypass -File scripts\flash-wlan-image.ps1 -Image D:\op10\ios16-root-wlan.simg
#>
[CmdletBinding()]
param(
    [string]$Image = 'D:\op10\ios16-root-wlan.simg',
    [long]$ExpectedBlocks = 58672399
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

function Find-Tool([string]$Name) {
    $cands = @()
    if ($env:ANDROID_TOOLS) { $cands += (Join-Path $env:ANDROID_TOOLS $Name) }
    $cands += @((Join-Path (Join-Path $PSScriptRoot '..\platform-tools') $Name), (Join-Path 'C:\platform-tools' $Name))
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$fastboot = Find-Tool 'fastboot.exe'
if (-not $fastboot) { Write-Host '[FAIL] fastboot.exe not found' -ForegroundColor Red; exit 2 }
if (-not (Test-Path -LiteralPath $Image)) { Write-Host "[FAIL] image not found: $Image" -ForegroundColor Red; exit 2 }

$sizeGB = [math]::Round((Get-Item -LiteralPath $Image).Length / 1GB, 2)
Write-Host "image : $Image ($sizeGB GB)"

$dev = & $fastboot devices 2>&1
if ($dev -notmatch '\S') {
    Write-Host '[FAIL] no fastboot device. Power off, then hold Volume Up + Volume Down + Power.' -ForegroundColor Red
    exit 2
}
Write-Host "device: $(($dev -join ' ').Trim())"

$raw = & $fastboot getvar partition-size:userdata 2>&1 | Out-String
$hex = ([regex]'0x[0-9a-fA-F]+').Match($raw).Value
if (-not $hex) { Write-Host "[WARN] cannot read partition-size:userdata:" -ForegroundColor Yellow; Write-Host $raw.Trim() }
else {
    $bytes = [Convert]::ToInt64($hex, 16)
    $blocks = [math]::Floor($bytes / 4096)
    Write-Host ("userdata: {0} bytes = {1} blocks (image built for {2})" -f $bytes, $blocks, $ExpectedBlocks)
    if ($blocks -ne $ExpectedBlocks) {
        Write-Host '[FAIL] block count differs - the firmware area would land at the wrong offset.' -ForegroundColor Red
        Write-Host '       Rebuild the image with USERDATA_BLOCKS set to the value above.' -ForegroundColor Yellow
        exit 3
    }
    Write-Host '[OK] block count matches' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Flashing userdata (this rewrites the iOS root + WLAN area, ~6 min)...' -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& $fastboot flash userdata $Image 2>&1 | Out-Host
$rc = $LASTEXITCODE
Write-Host ("elapsed: {0:N1} min, rc={1}" -f $sw.Elapsed.TotalMinutes, $rc)

if ($rc -eq 0) {
    Write-Host ''
    Write-Host 'Done. Boot it:' -ForegroundColor Green
    Write-Host '  fastboot reboot'
    Write-Host 'Then watch for NEGRONI WLAN lines in the kernel log / on screen.'
}
exit $rc
