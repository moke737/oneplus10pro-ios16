#Requires -Version 5.1
<#
  00-check-env.ps1 - read-only readiness check for building UniXNU on this PC.
  Changes nothing on disk. Run:

    powershell -ExecutionPolicy Bypass -File scripts\00-check-env.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$script:rows = New-Object System.Collections.ArrayList

function Add-Row {
    param([string]$Item, [string]$State, [string]$Detail)
    [void]$script:rows.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail })
}

function Test-Port {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 4000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($Target, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { $client.Close(); return $true }
        $client.Close()
        return $false
    } catch { return $false }
}

function Get-FreeGB {
    param([string]$Drive)
    try {
        $d = Get-PSDrive -Name $Drive -ErrorAction Stop
        if ($null -eq $d.Free) { return -1 }
        return [math]::Round($d.Free / 1GB, 1)
    } catch { return -1 }
}

Write-Host ""
Write-Host "UniXNU / OnePlus 10 Pro (negroni, SM8450) - host readiness check" -ForegroundColor Cyan
Write-Host ("=" * 68)

# --- 1. privileges -------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Add-Row 'Administrator shell' 'OK' '01-install-wsl.ps1 can run' }
else { Add-Row 'Administrator shell' 'WARN' 'needed for 01-install-wsl.ps1 (right-click > Run as administrator)' }

# --- 2. Windows build ----------------------------------------------------
$build = [Environment]::OSVersion.Version.Build
if ($build -ge 19041) { Add-Row 'Windows build' 'OK' "$build (WSL2 supported)" }
else { Add-Row 'Windows build' 'FAIL' "$build - WSL2 needs 19041+ (Win10 2004 / Win11)" }

# --- 3. RAM --------------------------------------------------------------
$ramGB = -1
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
} catch { }
if ($ramGB -lt 0) { Add-Row 'RAM' 'WARN' 'could not read (run as administrator to confirm)' }
elseif ($ramGB -ge 16) { Add-Row 'RAM' 'OK' "$ramGB GB" }
elseif ($ramGB -ge 8) { Add-Row 'RAM' 'WARN' "$ramGB GB - workable but the clang self-build will swap" }
else { Add-Row 'RAM' 'FAIL' "$ramGB GB - not enough for a WSL2 build host" }

# --- 4. virtualization ---------------------------------------------------
try {
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $hyper = $false
    try { $hyper = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    if ($cpu.VirtualizationFirmwareEnabled -or $hyper) { Add-Row 'Virtualization' 'OK' 'enabled (VT-x / SVM)' }
    else { Add-Row 'Virtualization' 'FAIL' 'enable VT-x/SVM in BIOS before installing WSL2' }
} catch {
    Add-Row 'Virtualization' 'WARN' 'could not read (check BIOS yourself: VT-x / SVM must be on)'
}

# --- 5. free space -------------------------------------------------------
$cFree = Get-FreeGB -Drive 'C'
$eFree = Get-FreeGB -Drive 'E'
if ($cFree -ge 30) { Add-Row 'C: free' 'OK' "$cFree GB" }
else { Add-Row 'C: free' 'WARN' "$cFree GB - fine: WSL is imported to E:\WSL, not C:" }

if ($eFree -ge 40) { Add-Row 'E: free' 'OK' "$eFree GB (WSL distro + toolchain + repos live here)" }
elseif ($eFree -ge 20) { Add-Row 'E: free' 'WARN' "$eFree GB - 40 GB recommended for the build" }
else { Add-Row 'E: free' 'FAIL' "$eFree GB - too small for WSL + toolchain" }

# --- 6. WSL --------------------------------------------------------------
$wslExe = (Get-Command wsl.exe -ErrorAction SilentlyContinue).Source
if (-not $wslExe) {
    Add-Row 'wsl.exe' 'FAIL' 'not found - run 01-install-wsl.ps1 (needs admin + reboot)'
} else {
    # registry only: `wsl.exe -l` can hang while the optional features are pending
    $dists = @()
    $lxss = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path -LiteralPath $lxss) {
        foreach ($k in @(Get-ChildItem -LiteralPath $lxss -ErrorAction SilentlyContinue)) {
            $n = (Get-ItemProperty -LiteralPath $k.PSPath -Name DistributionName -ErrorAction SilentlyContinue).DistributionName
            if ($n) { $dists += $n }
        }
    }
    if ($dists -contains 'Ubuntu-24.04') { Add-Row 'WSL distro' 'OK' 'Ubuntu-24.04 installed' }
    elseif ($dists.Count -gt 0) { Add-Row 'WSL distro' 'WARN' "found [$($dists -join ', ')]" }
    else { Add-Row 'WSL distro' 'WARN' 'not installed yet - 01-install-wsl.ps1 imports it to E:\WSL' }
}

# --- 7. tools ------------------------------------------------------------
$git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if ($git) { Add-Row 'git.exe' 'OK' $git } else { Add-Row 'git.exe' 'WARN' 'only needed on the Windows side for convenience' }

$candidates = @()
if ($env:ANDROID_TOOLS) { $candidates += (Join-Path $env:ANDROID_TOOLS 'fastboot.exe') }
$candidates += @(
    (Join-Path $PSScriptRoot '..\platform-tools\fastboot.exe'),
    'C:\platform-tools\fastboot.exe'
)
$fastboot = $null
foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $fastboot = $c; break } }
if (-not $fastboot) { $fastboot = (Get-Command fastboot.exe -ErrorAction SilentlyContinue).Source }
if ($fastboot) { Add-Row 'fastboot.exe' 'OK' $fastboot } else { Add-Row 'fastboot.exe' 'FAIL' 'android platform-tools not found' }

$adb = $null
foreach ($c in $candidates) {
    $a = Split-Path -Parent $c
    if (Test-Path -LiteralPath (Join-Path $a 'adb.exe')) { $adb = Join-Path $a 'adb.exe'; break }
}
if (-not $adb) { $adb = (Get-Command adb.exe -ErrorAction SilentlyContinue).Source }
if ($adb) { Add-Row 'adb.exe' 'OK' $adb } else { Add-Row 'adb.exe' 'WARN' 'needed for the userdata backup step' }

# --- 8. network ----------------------------------------------------------
if (Test-Port -Target 'github.com' -Port 443) { Add-Row 'github.com:443' 'OK' 'reachable' }
elseif (Test-Port -Target 'ghproxy.net' -Port 443) { Add-Row 'github.com:443' 'WARN' 'blocked; ghproxy.net mirror is reachable, 02-setup-repos.sh --mirror will use it' }
else { Add-Row 'github.com:443' 'FAIL' 'blocked and no mirror reachable - git clone impossible' }

if (Test-Port -Target 'updates.cdn-apple.com' -Port 443) { Add-Row 'apple cdn:443' 'OK' 'IPSW reachable' }
else { Add-Row 'apple cdn:443' 'WARN' 'unreachable right now - make devicetree needs it (retry later / proxy)' }

# --- report --------------------------------------------------------------
Write-Host ""
$script:rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$fails = @($script:rows | Where-Object { $_.State -eq 'FAIL' })
$warns = @($script:rows | Where-Object { $_.State -eq 'WARN' })

Write-Host ("FAIL: {0}   WARN: {1}" -f $fails.Count, $warns.Count)
if ($fails.Count -gt 0) {
    Write-Host ""
    Write-Host "Blocking items:" -ForegroundColor Red
    foreach ($f in $fails) { Write-Host ("  - {0}: {1}" -f $f.Item, $f.Detail) -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Host is ready. Next: scripts\01-install-wsl.ps1 (admin, one reboot)." -ForegroundColor Green
exit 0
