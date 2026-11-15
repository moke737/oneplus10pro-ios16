#Requires -Version 5.1
<#
  oneclick.ps1 - one-click (as close as physics allows) builder for the
  OnePlus 10 Pro / iOS 16 non-destructive boot test.

  Phases (state file: state\phase.txt, so a reboot or crash resumes):
    0  fresh            -> host check, install WSL2 (needs admin + reboot)
    1  waiting reboot   -> verify the distro, continue
    2  repos + deps     -> 02-setup-repos.sh, 03-host-deps.sh, start docker
    3  build            -> per-step `make` with artifact polling
    4  boot test        -> pause: put the phone in bootloader, then fastboot boot
    5  done

  Unavoidable manual points:
    * UAC prompt (WSL install needs administrator)
    * one reboot
    * `gh auth login` if gh is not authenticated yet (kernel artifact download)
    * putting the phone into fastboot mode before the last step

  Usage (double-click the .cmd is easiest):
    powershell -ExecutionPolicy Bypass -File scripts\oneclick.ps1
    ... -Proxy http://127.0.0.1:7890        # if github is blocked for gh/git
    ... -Steps "tools op10tool image mu kernel devicetree boot"
    ... -SkipBoot
    ... -Reset                               # start over from phase 0
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [string]$Distro = 'Ubuntu-24.04',
    [string]$Proxy = '',
    [switch]$NoMirror,
    [switch]$SkipBoot,
    [string]$Steps = 'boottest',
    [switch]$Reset
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $root 'state'
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $stateDir, $logDir -Force | Out-Null
$stateFile = Join-Path $stateDir 'phase.txt'
$logFile = Join-Path $logDir ('oneclick-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$installScript = Join-Path $root 'scripts\01-install-wsl.ps1'

function Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}
function Fail {
    param([string]$Message)
    Log "FAIL: $Message" 'Red'
    Log "log: $logFile" 'Yellow'
    exit 1
}
function Get-Phase {
    if (-not (Test-Path -LiteralPath $stateFile)) { return 0 }
    try { return [int]((Get-Content -LiteralPath $stateFile -Raw).Trim()) } catch { return 0 }
}
function Set-Phase {
    param([int]$Value)
    Set-Content -LiteralPath $stateFile -Value $Value -Encoding ASCII
    Log "phase -> $Value"
}
function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Distros {
    # registry only - `wsl.exe -l` can block right after the features are enabled
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

# --- proxy env prefix for everything that runs inside WSL -----------------
function Get-ProxyPrefix {
    if (-not $Proxy) { return '' }
    return ("export HTTPS_PROXY='{0}' HTTP_PROXY='{0}' ALL_PROXY='{0}' https_proxy='{0}' http_proxy='{0}' all_proxy='{0}'; " -f $Proxy)
}

function Invoke-Wsl {
    param([string]$Command, [int]$TimeoutSec = 0, [switch]$Show)
    $full = (Get-ProxyPrefix) + $Command
    if ($TimeoutSec -gt 0) {
        if ($Show) { & wsl.exe -d $Distro -u root -- timeout $TimeoutSec bash -lc $full 2>&1 | ForEach-Object { Write-Host "  $_"; Add-Content -LiteralPath $logFile -Value "    $_" -Encoding UTF8 } }
        else { & wsl.exe -d $Distro -u root -- timeout $TimeoutSec bash -lc $full 2>&1 | Out-Null }
    } else {
        if ($Show) { & wsl.exe -d $Distro -u root -- bash -lc $full 2>&1 | ForEach-Object { Write-Host "  $_"; Add-Content -LiteralPath $logFile -Value "    $_" -Encoding UTF8 } }
        else { & wsl.exe -d $Distro -u root -- bash -lc $full 2>&1 | Out-Null }
    }
    return $LASTEXITCODE
}

function Invoke-WslScript {
    param([string]$RelativePath, [string[]]$Arguments = @())
    $win = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $win)) { Fail "missing script: $win" }
    # pure string translation instead of wslpath (the minimal image may lack it)
    $wslPath = '/mnt/' + $win.Substring(0, 1).ToLower() + (($win.Substring(2)) -replace '\\', '/')
    $argLine = ''
    if ($Arguments.Count -gt 0) {
        $argLine = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    }
    # tr strips CRLF so the scripts stay runnable after Windows edits
    $cmd = "sed -i 's/\r`$//' '$wslPath'; bash '$wslPath' $argLine"
    return (Invoke-Wsl -Command $cmd -Show)
}

function Wait-DistroReady {
    for ($i = 1; $i -le 12; $i++) {
        $code = Invoke-Wsl -Command 'echo distro-ready' -TimeoutSec 60
        if ($code -eq 0) { return $true }
        Log "  distro not ready yet (attempt $i/12), waiting 15 s" 'Yellow'
        Start-Sleep -Seconds 15
    }
    return $false
}

function Get-RemoteMtime {
    param([string]$Path)
    $out = & wsl.exe -d $Distro -u root -- bash -lc "stat -c %Y '$Path' 2>/dev/null || echo -1" 2>$null
    $txt = ($out | Select-Object -First 1)
    if (-not $txt) { return -1 }
    $n = 0
    if ([int64]::TryParse($txt.Trim(), [ref]$n)) { return $n }
    return -1
}

function Wait-Artifact {
    param([string]$Path, [int]$TimeoutMin, [string]$Label)
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 300   # tolerate files made just before the wait
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    Log "  waiting for $Label ($Path), up to $TimeoutMin min"
    while ((Get-Date) -lt $deadline) {
        $m = Get-RemoteMtime -Path $Path
        if ($m -gt 0 -and $m -ge $startEpoch) {
            Log "  [OK] $Label ready" 'Green'
            return $true
        }
        Start-Sleep -Seconds 15
    }
    Log "  [TIMEOUT] $Label did not appear" 'Red'
    $tail = & wsl.exe -d $Distro -u root -- bash -lc "ls -t ~/iOSPlus10/logs/*.log 2>/dev/null | head -3" 2>$null
    foreach ($f in @($tail)) {
        if ($f) {
            Log "  ---- tail of $f ----" 'Yellow'
            & wsl.exe -d $Distro -u root -- bash -lc "tail -20 '$f'" 2>$null | ForEach-Object { Log "  $_" }
        }
    }
    return $false
}

function Register-RunOnce {
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Resume' -f $PSCommandPath
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UniXNUOneClick' -Value $cmd
    Log "registered RunOnce: the script resumes automatically after you log in"
}
function Clear-RunOnce {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'UniXNUOneClick' -ErrorAction SilentlyContinue
}

# =========================================================================
Log "=== one-click build, log: $logFile" 'Cyan'
Log "root : $root"
Log "steps: $Steps"

if ($Reset) { Set-Phase 0; Log "state reset" 'Yellow' }
$phase = Get-Phase
Log "phase: $phase" 'Cyan'

# ---------------------------------------------------------------- phase 0
if ($phase -eq 0) {
    if (-not (Test-Admin)) {
        Log "needs administrator for WSL install - relaunching elevated" 'Yellow'
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Proxy) { $argList += " -Proxy `"$Proxy`"" }
        if ($NoMirror) { $argList += ' -NoMirror' }
        if ($SkipBoot) { $argList += ' -SkipBoot' }
        $argList += " -Steps `"$Steps`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
        exit 0
    }

    Log "--- step 1/4: host check" 'Cyan'
    $check = Join-Path $root 'scripts\00-check-env.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $check
    if ($LASTEXITCODE -ne 0) {
        Log "host check reported blocking items - fix them, then re-run" 'Red'
        exit 1
    }

    Log "--- step 2/4: installing WSL2 + $Distro" 'Cyan'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Distro $Distro
    $instRc = $LASTEXITCODE
    Start-Sleep -Seconds 2

    $dists = Get-Distros
    if ((($dists -contains $Distro)) -and ($instRc -eq 0)) {
        Log "[OK] $Distro installed" 'Green'
        Set-Phase 2
        $phase = 2
    } elseif ($instRc -eq 30 -or -not ($dists -contains $Distro)) {
        Log "WSL install needs a reboot to finish (rc=$instRc)" 'Yellow'
        Set-Phase 1
        Register-RunOnce
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Yellow
        Write-Host '  REBOOT REQUIRED' -ForegroundColor Yellow
        Write-Host '  After logging back in, this script resumes automatically.' -ForegroundColor Yellow
        Write-Host '  (If Windows blocks RunOnce, just double-click the .cmd again.)' -ForegroundColor Yellow
        Write-Host '============================================================' -ForegroundColor Yellow
        $a = Read-Host 'Reboot now? (Y/n)'
        if ($a -ne 'n') { Restart-Computer -Force }
        exit 0
    }
}

# ---------------------------------------------------------------- phase 1
if ($phase -eq 1) {
    Log "--- step 2/4: finishing the $Distro install (post-reboot)" 'Cyan'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Distro $Distro
    $instRc = $LASTEXITCODE
    if (-not (@(Get-Distros) -contains $Distro)) {
        if ($instRc -eq 30) {
            Log "still needs a reboot (rc=30)" 'Yellow'
            Register-RunOnce
            $a = Read-Host 'Reboot now? (Y/n)'
            if ($a -ne 'n') { Restart-Computer -Force }
            exit 0
        }
        Fail "WSL distro $Distro is still missing (01 exit $instRc) - see the messages above"
    }
    if (-not (Wait-DistroReady)) { Fail "distro $Distro does not respond" }
    Log "[OK] distro ready" 'Green'
    Clear-RunOnce
    Set-Phase 2
    $phase = 2
}

# ---------------------------------------------------------------- phase 2
if ($phase -eq 2) {
    Log "--- step 3/4: repositories and host dependencies" 'Cyan'
    $repoArgs = @()
    if (-not $NoMirror) { $repoArgs += '--mirror' }
    $rc = Invoke-WslScript -RelativePath 'scripts\02-setup-repos.sh' -Arguments $repoArgs
    if ($rc -ne 0) { Fail "02-setup-repos.sh failed (rc=$rc)" }

    $rc = Invoke-WslScript -RelativePath 'scripts\03-host-deps.sh'
    if ($rc -ne 0) { Fail "03-host-deps.sh failed (rc=$rc)" }

    Log "starting docker inside WSL"
    # docker.io ships only a systemd unit; this WSL image has no systemd, and
    # `service docker start` fails with "unrecognized service". Start dockerd
    # directly as a fallback.
    $dockerCmd = 'if ! docker info >/dev/null 2>&1; then service docker start >/dev/null 2>&1 || true; fi; ' +
                 'if ! docker info >/dev/null 2>&1; then nohup dockerd >/var/log/dockerd.log 2>&1 & sleep 10; fi; ' +
                 'docker info >/dev/null 2>&1 && echo DOCKER_OK'
    $dockerRc = Invoke-Wsl -Command $dockerCmd -TimeoutSec 120
    if ($dockerRc -ne 0) { Log "docker did not start - 'make image' / 'make mu' will fail" 'Yellow' }
    else { Log "[OK] docker is running" 'Green' }

    Set-Phase 3
    $phase = 3
}

# ---------------------------------------------------------------- phase 3
if ($phase -eq 3) {
    Log "--- step 4/4: build" 'Cyan'

    # expand groups
    $stepList = @()
    foreach ($s in ($Steps -split '\s+')) {
        if (-not $s) { continue }
        switch ($s) {
            'boottest' { $stepList += @('tools', 'op10tool', 'image', 'mu', 'kernel', 'devicetree', 'boot') }
            'setup' { $stepList += @('tools', 'op10tool', 'image') }
            'chain' { $stepList += @('mu', 'kernel', 'devicetree', 'boot') }
            default { $stepList += $s }
        }
    }

    # expected artifact per step, and how long to wait for it
    $artifacts = @{
        'op10tool'   = @{ path = '/root/iOSPlus10/out/bin/op10tool'; min = 30 }
        'mu'         = @{ path = '/root/iOSPlus10/out/mu/SILICIUM_UEFI-DEBUG.fd'; min = 180 }
        'kernel'     = @{ path = '/root/iOSPlus10/out/kernel/kernel.macho'; min = 90 }
        'devicetree' = @{ path = '/root/op10-apple/d22ap.adt'; min = 60 }
        'boot'       = @{ path = '/root/iOSPlus10/out/ios16/boot_a.img'; min = 60 }
        'dmgs'       = @{ path = '/root/op10-apple/20H392'; min = 120 }
        'root'       = @{ path = '/root/op10-apple/ios16-root.img'; min = 180 }
        'simg'       = @{ path = '/root/op10-apple/ios16-root.simg'; min = 90 }
    }

    foreach ($s in $stepList) {
        Log "===== make target: $s" 'Cyan'

        if ($s -eq 'kernel') {
            $auth = Invoke-Wsl -Command 'command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && echo GH_OK' -TimeoutSec 60
            if ($auth -ne 0) {
                Log "'gh' is not authenticated - the kernel comes from a GitHub Actions artifact" 'Yellow'
                Log "running 'gh auth login --web' now, follow the browser prompt" 'Yellow'
                Invoke-Wsl -Command 'gh auth login --web'
                $auth = Invoke-Wsl -Command 'gh auth status >/dev/null 2>&1 && echo GH_OK' -TimeoutSec 60
                if ($auth -ne 0) { Fail "gh auth still failing (github blocked? try -Proxy http://127.0.0.1:PORT)" }
            }
        }

        $rc = Invoke-WslScript -RelativePath 'scripts\04-build.sh' -Arguments @('--steps', $s)
        if ($rc -ne 0) {
            Log "step '$s' returned $rc - checking for a detached tmux job anyway" 'Yellow'
        }

        # `make image` also detaches into tmux; the Mu build needs the image to exist.
        if ($s -eq 'image') {
            Log "  waiting for the build image (iosplus10-build:amd64), up to 60 min"
            $deadline = (Get-Date).AddMinutes(60)
            $imgOk = $false
            while ((Get-Date) -lt $deadline) {
                if ((Invoke-Wsl -Command 'docker image inspect iosplus10-build:amd64 >/dev/null 2>&1' -TimeoutSec 60) -eq 0) { $imgOk = $true; break }
                Start-Sleep -Seconds 20
            }
            if ($imgOk) { Log "  [OK] build image ready" 'Green' } else { Fail "build image never appeared - see ~/iOSPlus10/logs/docker-image.log" }
        }

        if ($artifacts.ContainsKey($s)) {
            $a = $artifacts[$s]
            if (-not (Wait-Artifact -Path $a.path -TimeoutMin $a.min -Label $s)) {
                Log "check 'make status' inside WSL and ~/iOSPlus10/logs/" 'Yellow'
                Fail "step '$s' produced no artifact"
            }
        }
    }

    Log "[OK] build finished" 'Green'
    Set-Phase 4
    $phase = 4
}

# ---------------------------------------------------------------- phase 4
if ($phase -eq 4) {
    if ($SkipBoot) {
        Log "boot test skipped (-SkipBoot)" 'Yellow'
        Set-Phase 5
        $phase = 5
    } else {
        $img = Join-Path $root 'dist\boot_a.img'
        if (-not (Test-Path -LiteralPath $img)) { Fail "dist\boot_a.img missing - build step did not copy it" }

        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Yellow
        Write-Host '  Put the phone in BOOTLOADER mode now:' -ForegroundColor Yellow
        Write-Host '    power off -> hold Volume Up + Volume Down + Power' -ForegroundColor Yellow
        Write-Host '  (bootloader, not fastbootd)' -ForegroundColor Yellow
        Write-Host '  Nothing will be written to any partition.' -ForegroundColor Yellow
        Write-Host '============================================================' -ForegroundColor Yellow
        Read-Host 'Press Enter when the bootloader screen is up'

        $boot = Join-Path $root 'scripts\05-boot.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $boot -Image $img
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Log "fastboot boot returned $rc - see the messages above" 'Red'
            Fail "boot test failed"
        }
        Set-Phase 5
        $phase = 5
    }
}

# ---------------------------------------------------------------- phase 5
Clear-RunOnce
Log "=== done" 'Green'
Write-Host ''
Write-Host 'Result:' -ForegroundColor Cyan
Write-Host '  Mu-Silicium / UniXNU menu on screen  -> the UEFI chain works on this phone'
Write-Host '  menu -> XNU -> black screen          -> expected: no iOS root, mount fails'
Write-Host '  black screen with no menu            -> ABL rejected the shim (see README)'
Write-Host ''
Write-Host "log: $logFile"
