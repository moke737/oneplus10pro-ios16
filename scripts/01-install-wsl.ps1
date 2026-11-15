#Requires -Version 5.1
<#
  01-install-wsl.ps1 - WSL2 without the Microsoft Store and without filling C:.

  Route: dism enables the two optional features, the WSL2 kernel MSI is installed,
  then an Ubuntu 24.04 rootfs tarball is imported to E:\WSL\Ubuntu-24.04.

  Why not `wsl --install -d Ubuntu-24.04`:
    * the Store distro lands on C:, which has ~10 GB free on this machine,
    * the Store may be blocked here while the Ubuntu image server is not.

  Exit codes:
    0   distro ready
    30  reboot required, run this script again afterwards
    1   failure

  Needs administrator. Run through oneclick.ps1 or:
    powershell -ExecutionPolicy Bypass -File scripts\01-install-wsl.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [string]$InstallRoot = 'E:\WSL'
)

$ErrorActionPreference = 'Continue'
$cache = Join-Path $InstallRoot 'cache'
$rootfs = Join-Path $cache 'ubuntu-base-24.04.3.tar.gz'
$msi = Join-Path $cache 'wsl_update_x64.msi'
$rootfsUrl = 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz'
$msiUrl = 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi'

function Say([string]$m, [string]$c = 'Gray') { Write-Host "[01] $m" -ForegroundColor $c }
function Get-Distros {
    # Registry only: calling `wsl.exe -l` right after enabling the optional
    # features can block for minutes (or open an invisible prompt).
    $out = @()
    $base = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path -LiteralPath $base) {
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $n = (Get-ItemProperty -LiteralPath $k.PSPath -Name DistributionName -ErrorAction SilentlyContinue).DistributionName
            if ($n) { $out += $n }
        }
    }
    return $out
}
function Test-WslWorks {
    # Start-Job instead of Start-Process: Start-Process throws on this machine
    # because the environment has both NO_PROXY and no_proxy (PS 5.1 bug).
    $job = Start-Job -ScriptBlock { & wsl.exe --version 2>&1 | Out-Null; $LASTEXITCODE }
    if (Wait-Job $job -Timeout 20) {
        $rc = Receive-Job $job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return ("$rc" -eq '0')
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $false
}
function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-FeatureState([string]$Name) {
    # Get-WindowsOptionalFeature is locale independent; the dism text is
    # translated on non-English Windows, so it is only a fallback.
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        return [string]$f.State
    } catch {
        $o = (& dism.exe /online /get-featureinfo /featurename:$Name 2>&1) -join "`n"
        if ($o -match 'State\s*:\s*Enabled') { return 'Enabled' }
        if ($o -match 'State\s*:\s*Disabled') { return 'Disabled' }
        return 'Unknown'
    }
}
function Download([string]$Url, [string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 1MB)) {
        Say "cached: $(Split-Path $Path -Leaf)"
        return $true
    }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    Say "downloading $(Split-Path $Path -Leaf)"
    & curl.exe -sSL --retry 3 --retry-delay 2 -m 900 -o $Path $Url
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-Item -LiteralPath $Path).Length -gt 1MB)
}

Say 'starting' 'Cyan'

# --- already done? (check this first: no admin needed, no wsl.exe call) ---
if (@(Get-Distros) -contains $Distro) {
    Say "$Distro is already registered" 'Green'
    & wsl.exe --set-default $Distro 2>&1 | Out-Null
    exit 0
}

$isAdmin = Test-Admin
if (-not $isAdmin) {
    if (-not (Test-WslWorks)) {
        Say 'WSL is not usable yet, and enabling the optional features needs administrator' 'Red'
        Say 're-run from an elevated PowerShell (or let oneclick.ps1 relaunch itself)' 'Yellow'
        exit 1
    }
    Say 'no administrator: WSL already works, doing the import only' 'Yellow'
}

# --- optional features (administrator only) ------------------------------
$rebootNeeded = $false
if ($isAdmin) {
    $vmState = Get-FeatureState 'VirtualMachinePlatform'
    $wslState = Get-FeatureState 'Microsoft-Windows-Subsystem-Linux'
    Say "feature VirtualMachinePlatform            : $vmState"
    Say "feature Microsoft-Windows-Subsystem-Linux : $wslState"

    foreach ($pair in @(
            @{ Name = 'VirtualMachinePlatform'; State = $vmState },
            @{ Name = 'Microsoft-Windows-Subsystem-Linux'; State = $wslState })) {
        if ($pair.State -eq 'Enabled') { continue }
        if ($pair.State -eq 'EnablePending') {
            Say "$($pair.Name) is already pending a reboot" 'Yellow'
            $rebootNeeded = $true
            continue
        }
        Say "enabling $($pair.Name) (state was '$($pair.State)')" 'Yellow'
        & dism.exe /online /enable-feature /featurename:$($pair.Name) /all /norestart 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            Say "dism failed for $($pair.Name) (rc=$LASTEXITCODE)" 'Red'
            exit 1
        }
        $rebootNeeded = $true
    }

    # --- WSL runtime / kernel --------------------------------------------
    $wslOk = Test-WslWorks

    if (-not $wslOk) {
        if (-not (Download $msiUrl $msi)) { Say 'cannot download the WSL2 kernel MSI' 'Red'; exit 1 }
        Say 'installing WSL2 kernel MSI'
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
        Say "msiexec exit: $($p.ExitCode)"
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1638) {
            Say 'MSI install failed (a newer WSL is probably already present - continuing)' 'Yellow'
        }
        if ($p.ExitCode -eq 3010) { $rebootNeeded = $true }
    }
}

if ($rebootNeeded) {
    Say 'REBOOT REQUIRED - run this script again after restarting' 'Yellow'
    exit 30
}

# wsl.exe works, features are on, no distro yet
Say 'configuring WSL defaults'
& wsl.exe --set-default-version 2 2>&1 | Out-Host

# --- import the rootfs ---------------------------------------------------
if (-not (Download $rootfsUrl $rootfs)) { Say 'cannot download the Ubuntu rootfs' 'Red'; exit 1 }

$target = Join-Path $InstallRoot $Distro
if (Test-Path -LiteralPath $target) {
    Say "removing stale import directory $target" 'Yellow'
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $target -Force | Out-Null

Say "importing $Distro into $target"
& wsl.exe --import $Distro $target $rootfs --version 2 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Say 'import with --version 2 failed, retrying without it' 'Yellow'
    & wsl.exe --import $Distro $target $rootfs 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Say 'wsl --import failed' 'Red'; exit 1 }
}
if (-not (@(Get-Distros) -contains $Distro)) { Say 'import claimed success but the distro is not registered' 'Red'; exit 1 }
& wsl.exe --set-default $Distro 2>&1 | Out-Null
Say "$Distro imported" 'Green'

# --- configure inside ----------------------------------------------------
Say 'configuring the distro (wsl.conf, apt mirror, base packages)'
$cfg = @'
set -e
if [ ! -f /etc/wsl.conf ]; then
  printf '[user]\ndefault=root\n\n[boot]\nsystemd=false\n\n[interop]\nenabled=true\nappendWindowsPath=true\n' > /etc/wsl.conf
fi
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  sed -i 's|http://archive.ubuntu.com|http://mirrors.aliyun.com|g; s|http://security.ubuntu.com|http://mirrors.aliyun.com|g; s|https://archive.ubuntu.com|http://mirrors.aliyun.com|g' "$f"
done
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo ca-certificates curl git >/dev/null
echo CONFIG_OK
'@
$cfgEscaped = $cfg -replace "'", "'\''"
& wsl.exe -d $Distro -u root -- bash -lc "echo '$cfgEscaped' > /tmp/cfg.sh && bash /tmp/cfg.sh"
if ($LASTEXITCODE -ne 0) {
    Say 'distro configuration failed (apt mirror?); the build will fail too' 'Red'
    exit 1
}

Say 'checking the toolchain basics'
& wsl.exe -d $Distro -u root -- bash -lc 'echo "user=$(id -un) ubuntu=$(cat /etc/os-release | grep VERSION_ID) git=$(git --version)"' 2>&1 | Out-Host

Say "$Distro ready at $target" 'Green'
exit 0
