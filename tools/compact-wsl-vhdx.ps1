#Requires -Version 5.1
<#
  compact-wsl-vhdx.ps1 - shrink a WSL ext4.vhdx that grew and never shrank.

  Plain `diskpart compact vdisk` refuses the WSL 3.x virtual disk with
  "the virtual disk file must be uncompressed, unencrypted and not sparse".
  WSL creates the vhdx with the NTFS sparse attribute set even though the file
  is fully allocated, so clearing that attribute (metadata only) makes diskpart
  happy.

  Must run elevated. Stop WSL first.

  Usage:
    powershell -ExecutionPolicy Bypass -File tools\compact-wsl-vhdx.ps1 `
        -VhdxPath E:\WSL\Ubuntu-24.04\ext4.vhdx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VhdxPath,
    [switch]$KeepSparse
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[FAIL] needs administrator' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $VhdxPath)) { Write-Host "[FAIL] not found: $VhdxPath" -ForegroundColor Red; exit 1 }

& wsl.exe --shutdown 2>&1 | Out-Null
Start-Sleep -Seconds 3

$before = [math]::Round((Get-Item -LiteralPath $VhdxPath).Length / 1GB, 2)
Write-Host "before : $before GB"

$flags = (& fsutil.exe sparse queryflag $VhdxPath 2>&1) -join ' '
if ($flags -match '稀疏|sparse') {
    Write-Host 'clearing the NTFS sparse attribute (metadata only)'
    & fsutil.exe sparse setflag $VhdxPath 0 | Out-Null
}

$tmp = Join-Path $env:TEMP ('compact-' + [guid]::NewGuid().ToString('N') + '.txt')
@"
select vdisk file="$VhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@ | Set-Content -LiteralPath $tmp -Encoding ASCII

& diskpart.exe /s $tmp | Out-Host
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

if ($KeepSparse) {
    Write-Host 'restoring the sparse attribute'
    & fsutil.exe sparse setflag $VhdxPath 1 | Out-Null
}

$after = [math]::Round((Get-Item -LiteralPath $VhdxPath).Length / 1GB, 2)
Write-Host "after  : $after GB (freed $([math]::Round($before - $after, 2)) GB)" -ForegroundColor Green
