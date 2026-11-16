#Requires -Version 5.1
# Elevated helper: re-bind the phone's USB device so usbip attach works again. ASCII only.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$log = Join-Path $root 'logs\usbipd-rebind.log'
$exe = 'C:\Program Files\usbipd-win\usbipd.exe'

$out = @()
$out += '--- unbind'
$out += ((& $exe unbind --busid 2-1 2>&1) -join "`n")
Start-Sleep -Seconds 1
$out += '--- bind'
$out += ((& $exe bind --busid 2-1 2>&1) -join "`n")
Start-Sleep -Seconds 1
$out += '--- list'
$out += ((& $exe list 2>&1) -join "`n")
Set-Content -LiteralPath $log -Value ($out -join "`n") -Encoding UTF8
