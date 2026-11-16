#Requires -Version 5.1
# Elevated helper: share the phone's USB device with usbipd. ASCII only.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$log = Join-Path $root 'logs\usbipd-bind2.log'
$exe = 'C:\Program Files\usbipd-win\usbipd.exe'

$out = @()
$out += "admin: " + (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out += '--- bind'
$out += ((& $exe bind --busid 2-1 2>&1) -join "`n")
$out += "rc=$LASTEXITCODE"
$out += '--- list'
$out += ((& $exe list 2>&1) -join "`n")
Set-Content -LiteralPath $log -Value ($out -join "`n") -Encoding UTF8
