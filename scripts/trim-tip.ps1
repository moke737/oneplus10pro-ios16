#Requires -Version 5.1
# Crop the tip QR to the QR + caption area (drops the white margins and the
# full-width gold banner). ASCII only.
param(
    [string]$Source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\tip-moke-orig.png'),
    [string]$Dest   = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\tip-moke.png'),
    [int]$X = 120,
    [int]$Y = 120,
    [int]$W = 830,
    [int]$H = 680
)

Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile($Source)
Write-Host ("source: {0}x{1}" -f $src.Width, $src.Height)

if (($X + $W) -gt $src.Width) { $W = $src.Width - $X }
if (($Y + $H) -gt $src.Height) { $H = $src.Height - $Y }
Write-Host ("crop  : x={0} y={1} {2}x{3}" -f $X, $Y, $W, $H)

$rect = New-Object System.Drawing.Rectangle $X, $Y, $W, $H
$cropped = $src.Clone($rect, $src.PixelFormat)
$src.Dispose()

$final = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($final)
$g.Clear([System.Drawing.Color]::White)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($cropped, 0, 0, $W, $H)
$g.Dispose()
$cropped.Dispose()

$final.Save($Dest, [System.Drawing.Imaging.ImageFormat]::Png)
$final.Dispose()

$bytes = (Get-Item -LiteralPath $Dest).Length
Write-Host ("saved : {0}  {1:N0} KB" -f $Dest, ($bytes / 1KB))
