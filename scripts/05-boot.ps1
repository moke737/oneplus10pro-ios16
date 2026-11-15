#Requires -Version 5.1
<#
  05-boot.ps1 - one-shot, non-destructive UniXNU boot test.

  `fastboot boot` loads the image into RAM and starts it. It does NOT write the
  boot partition, so a failed test is undone with a power cycle.

  Run:
    powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1
    powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1 -CheckOnly
    powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1 -Image dist\boot.img
#>
[CmdletBinding()]
param(
    [string]$Image,
    [switch]$CheckOnly,
    [switch]$SkipDeviceCheck
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

function Find-Tool([string]$Name) {
    $candidates = @()
    if ($env:ANDROID_TOOLS) { $candidates += (Join-Path $env:ANDROID_TOOLS $Name) }
    $candidates += @((Join-Path (Join-Path $PSScriptRoot '..\platform-tools') $Name), (Join-Path 'C:\platform-tools' $Name))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$fastboot = Find-Tool 'fastboot.exe'
if (-not $fastboot) { Write-Host "[FAIL] fastboot.exe not found" -ForegroundColor Red; exit 2 }

if (-not $Image) {
    foreach ($candidate in @('dist\boot_a.img', 'dist\boot.img')) {
        $p = Join-Path $root $candidate
        if (Test-Path -LiteralPath $p) { $Image = $p; break }
    }
    if (-not $Image) { $Image = Join-Path $root 'dist\boot_a.img' }
}
if (-not (Test-Path -LiteralPath $Image)) {
    Write-Host "[FAIL] image not found: $Image" -ForegroundColor Red
    Write-Host "       build it first: run-wsl.ps1 -Script 04-build.sh" -ForegroundColor Yellow
    exit 2
}
$sizeMB = [math]::Round((Get-Item -LiteralPath $Image).Length / 1MB, 1)
$hash = (Get-FileHash -LiteralPath $Image -Algorithm SHA256).Hash

Write-Host ""
Write-Host "UniXNU non-destructive boot test" -ForegroundColor Cyan
Write-Host ("=" * 60)
Write-Host "image : $Image"
Write-Host "size  : $sizeMB MB"
Write-Host "sha256: $hash"
if ($sizeMB -lt 1) { Write-Host "[FAIL] image is suspiciously small" -ForegroundColor Red; exit 2 }

# --- sanity: Android boot image magic at offset 0 ------------------------
try {
    $fs = [System.IO.File]::OpenRead($Image)
    $buf = New-Object byte[] 48
    $null = $fs.Read($buf, 0, 48)
    $fs.Close()
    $magic = [System.Text.Encoding]::ASCII.GetString($buf, 0, 8)
    $hdrVersion = [BitConverter]::ToUInt32($buf, 40)
    if ($magic -eq 'ANDROID!') {
        Write-Host "header: ANDROID! v$hdrVersion boot image"
    } else {
        Write-Host "[WARN] no 'ANDROID!' magic at offset 0 (found '$magic')" -ForegroundColor Yellow
        Write-Host "       the phone will probably reject it" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] could not read the header: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "This writes NOTHING: no boot_a, no vendor_boot_a, no vbmeta, no userdata." -ForegroundColor Cyan

if ($CheckOnly) { Write-Host "`n[check only] not touching the phone."; exit 0 }

# --- device --------------------------------------------------------------
if (-not $SkipDeviceCheck) {
    Write-Host "`n[info] looking for a device in fastboot mode..." -ForegroundColor Cyan
    $devices = @(& $fastboot devices 2>&1 | Where-Object { $_ -match '\S' })
    if ($devices.Count -eq 0) {
        Write-Host "[FAIL] no fastboot device." -ForegroundColor Red
        Write-Host "       Power off, then hold Volume Down + Volume Up + Power until the" -ForegroundColor Yellow
        Write-Host "       bootloader screen appears (OnePlus: 'fastboot mode')." -ForegroundColor Yellow
        Write-Host "       Do not use fastbootd here - this must be the bootloader." -ForegroundColor Yellow
        exit 2
    }
    Write-Host "       $($devices -join ' | ')"
}

Write-Host "`n[info] fastboot boot (nothing is flashed)" -ForegroundColor Cyan
Write-Host "       expect: UniXNU menu -> XNU -> kernel log or SpringBoard"
Write-Host "       recovery: hold Power ~10 s to force off, then boot Android normally"
Write-Host ""

& $fastboot boot $Image
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "[OK] image handed to the bootloader." -ForegroundColor Green
    Write-Host "     If the screen stays black for >2 min, power-cycle and capture logs" -ForegroundColor Yellow
    Write-Host "     (see the log-capture section in README-*.md)." -ForegroundColor Yellow
} else {
    Write-Host "[FAIL] fastboot boot returned $code" -ForegroundColor Red
    Write-Host "       'Flashing is not allowed' -> bootloader is locked." -ForegroundColor Yellow
    Write-Host "       'unknown command'          -> you are in fastbootd, reboot to bootloader." -ForegroundColor Yellow
}
exit $code
