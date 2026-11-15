#Requires -Version 5.1
<#
  90-backup-userdata.ps1 - capture the pieces you cannot rebuild before touching
  the partition table. Run this from TWRP (root adb), not from Android.

  Modes:
    -Mode Gpt    (default) GPT primary + backup regions + sizes. Fast, seconds.
    -Mode Full   userdata + metadata block images. Slow (hours) and big.
    -Mode Both

  Run:
    powershell -ExecutionPolicy Bypass -File scripts\90-backup-userdata.ps1
    powershell -ExecutionPolicy Bypass -File scripts\90-backup-userdata.ps1 -Mode Full -Force

  Why cmd.exe redirection: PowerShell's ">" is text and corrupts binary data.
  cmd.exe ">" is byte-safe.
#>
[CmdletBinding()]
param(
    [ValidateSet('Gpt', 'Full', 'Both')][string]$Mode = 'Gpt',
    [string]$OutDir,
    [string]$Serial,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

function Find-Tool([string]$Name) {
    $candidates = @()
    if ($env:ANDROID_TOOLS) { $candidates += (Join-Path $env:ANDROID_TOOLS $Name) }
    $candidates += @((Join-Path $PSScriptRoot '..\platform-tools' $Name), (Join-Path 'C:\platform-tools' $Name))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Shell([string]$Command) {
    $args = @()
    if ($Serial) { $args += @('-s', $Serial) }
    $args += @('shell', $Command)
    return (& $script:adb @args 2>&1) -join "`n"
}

function Get-RemoteSize([string]$DevicePath) {
    $out = Invoke-Shell "blockdev --getsize64 $DevicePath 2>/dev/null || stat -c %s $DevicePath"
    $digits = ($out -replace '[^0-9]', '')
    if ($digits) { return [int64]$digits }
    return -1
}

function Copy-BlockRange {
    param([string]$Device, [string]$Target, [int64]$SkipSectors = 0, [int64]$CountSectors = 0, [int]$BlockSize = 512)
    $dd = "dd if=$Device bs=$BlockSize"
    if ($SkipSectors -gt 0) { $dd += " skip=$SkipSectors" }
    if ($CountSectors -gt 0) { $dd += " count=$CountSectors" }
    $dd += ' 2>/dev/null'
    $cmdLine = '"{0}" {1}exec-out "{2}" > "{3}"' -f $script:adb, $(if ($Serial) { "-s $Serial " } else { '' }), $dd, $Target
    & cmd.exe /c $cmdLine
    return $LASTEXITCODE
}

$adb = Find-Tool 'adb.exe'
if (-not $adb) { Write-Host "[FAIL] adb.exe not found" -ForegroundColor Red; exit 2 }
$script:adb = $adb

if (-not $OutDir) {
    $OutDir = Join-Path $root ('backup\negroni-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

Write-Host ""
Write-Host "Partition backup before any repartitioning" -ForegroundColor Cyan
Write-Host ("=" * 64)

# --- device --------------------------------------------------------------
$devices = @(& $adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
if ($devices.Count -eq 0) {
    Write-Host "[FAIL] no adb device. Boot TWRP first (adb must be rooted)." -ForegroundColor Red
    exit 2
}
if ($devices.Count -gt 1 -and -not $Serial) {
    Write-Host "[FAIL] several devices attached; pass -Serial <serial>:" -ForegroundColor Red
    $devices | ForEach-Object { Write-Host "       $_" }
    exit 2
}
$ids = @()
foreach ($line in $devices) { $ids += ($line -split '\s+')[0] }
if (-not $Serial) { $Serial = $ids[0] }
Write-Host "device: $Serial"

$whoami = Invoke-Shell 'id'
if ($whoami -notmatch 'uid=0') {
    Write-Host "[FAIL] adb is not root inside recovery. Enable root/adb in TWRP." -ForegroundColor Red
    Write-Host "       id -> $whoami" -ForegroundColor Yellow
    exit 2
}
Write-Host "shell as root: yes"

# --- partition facts -----------------------------------------------------
$userdataDev = (Invoke-Shell 'readlink -f /dev/block/by-name/userdata').Trim()
$metadataDev = (Invoke-Shell 'readlink -f /dev/block/by-name/metadata').Trim()
if (-not $userdataDev) { Write-Host "[FAIL] cannot resolve /dev/block/by-name/userdata" -ForegroundColor Red; exit 2 }
$diskDev = $userdataDev -replace '\d+$', ''

Write-Host "userdata: $userdataDev"
Write-Host "metadata: $metadataDev"
Write-Host "disk    : $diskDev"

$udSize = Get-RemoteSize $userdataDev
$mdSize = if ($metadataDev) { Get-RemoteSize $metadataDev } else { 0 }
$diskGB = if ($udSize -gt 0) { [math]::Round($udSize / 1GB, 1) } else { -1 }
Write-Host "userdata size: $diskGB GB"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Write-Host "output: $OutDir"

# --- free space ----------------------------------------------------------
$drive = (Get-Item -LiteralPath $OutDir).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 1)
Write-Host "free on $($drive.Name): $freeGB GB"

if ($Mode -ne 'Gpt') {
    $needGB = [math]::Round(($udSize + $mdSize) / 1GB, 1)
    Write-Host "full backup needs ~$needGB GB"
    if ($freeGB -lt $needGB + 2) {
        Write-Host "[FAIL] not enough free space for a full backup ($freeGB GB free, $needGB GB needed)" -ForegroundColor Red
        exit 2
    }
    $hours = [math]::Round(($udSize / 1GB) / 25.0 / 60.0, 1)
    Write-Host "estimated dd time: ~$hours h at 25 MB/s" -ForegroundColor Yellow
    if (-not $Force) {
        Write-Host "[STOP] full backup not started. Re-run with -Force to confirm." -ForegroundColor Yellow
        Write-Host "       Consider -Mode Gpt first: it is what actually lets you roll back." -ForegroundColor Yellow
        exit 3
    }
}

# --- GPT -----------------------------------------------------------------
if ($Mode -eq 'Gpt' -or $Mode -eq 'Both') {
    Write-Host "`n[gpt] reading partition table" -ForegroundColor Cyan
    $diskSectorsOut = Invoke-Shell "blockdev --getsz $diskDev"
    $diskSectors = [int64](($diskSectorsOut -replace '[^0-9]', ''))
    if ($diskSectors -le 0) { Write-Host "[FAIL] cannot read sector count of $diskDev" -ForegroundColor Red; exit 2 }
    Write-Host "disk sectors: $diskSectors"

    $primary = Join-Path $OutDir 'gpt-primary.bin'
    $backup = Join-Path $OutDir 'gpt-backup.bin'
    $null = Copy-BlockRange -Device $diskDev -Target $primary -SkipSectors 0 -CountSectors 34
    $skip = $diskSectors - 34
    $null = Copy-BlockRange -Device $diskDev -Target $backup -SkipSectors $skip -CountSectors 34

    foreach ($f in @($primary, $backup)) {
        if (Test-Path -LiteralPath $f) {
            $len = (Get-Item -LiteralPath $f).Length
            Write-Host ("  {0}  {1} bytes  {2}" -f (Split-Path -Leaf $f), $len, (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash)
        } else {
            Write-Host "  [FAIL] $f was not created" -ForegroundColor Red
        }
    }

    Invoke-Shell 'cat /proc/partitions' | Set-Content -LiteralPath (Join-Path $OutDir 'proc-partitions.txt') -Encoding UTF8
    Invoke-Shell "cat /proc/mounts" | Set-Content -LiteralPath (Join-Path $OutDir 'proc-mounts.txt') -Encoding UTF8
    "userdata=$userdataDev`nmetadata=$metadataDev`ndisk=$diskDev`ndisk_sectors=$diskSectors`nuserdata_bytes=$udSize`nmetadata_bytes=$mdSize" |
        Set-Content -LiteralPath (Join-Path $OutDir 'sizes.txt') -Encoding UTF8
    Write-Host "  [OK] sizes.txt / proc-partitions.txt / proc-mounts.txt" -ForegroundColor Green
}

# --- full block copy -----------------------------------------------------
if ($Mode -eq 'Full' -or $Mode -eq 'Both') {
    Write-Host "`n[full] dumping userdata (this takes hours)" -ForegroundColor Cyan
    $udFile = Join-Path $OutDir 'userdata.img'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Copy-BlockRange -Device $userdataDev -Target $udFile -BlockSize 1048576
    $sw.Stop()
    if (Test-Path -LiteralPath $udFile) {
        $len = (Get-Item -LiteralPath $udFile).Length
        Write-Host ("  userdata.img {0} bytes in {1:N1} min" -f $len, $sw.Elapsed.TotalMinutes)
        if ($udSize -gt 0 -and $len -ne $udSize) { Write-Host "  [FAIL] size mismatch (expected $udSize)" -ForegroundColor Red }
        else { Write-Host "  [OK] size matches" -ForegroundColor Green }
    } else { Write-Host "  [FAIL] userdata.img not created" -ForegroundColor Red }

    if ($metadataDev) {
        Write-Host "`n[full] dumping metadata" -ForegroundColor Cyan
        $mdFile = Join-Path $OutDir 'metadata.img'
        $null = Copy-BlockRange -Device $metadataDev -Target $mdFile -BlockSize 1048576
        if (Test-Path -LiteralPath $mdFile) {
            $len = (Get-Item -LiteralPath $mdFile).Length
            Write-Host ("  metadata.img {0} bytes" -f $len)
            if ($mdSize -gt 0 -and $len -ne $mdSize) { Write-Host "  [FAIL] size mismatch (expected $mdSize)" -ForegroundColor Red }
            else { Write-Host "  [OK] size matches" -ForegroundColor Green }
        }
    }
}

Write-Host ""
Write-Host "Backup written to $OutDir" -ForegroundColor Green
Write-Host "Keep it on a different physical disk than the phone's own storage." -ForegroundColor Yellow
Write-Host "Restoring the GPT alone does NOT undo an F2FS shrink - see the docs." -ForegroundColor Yellow
