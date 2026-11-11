# Рисует иконку приложения и раскладывает её по платформам:
#   powershell -ExecutionPolicy Bypass -File tool\make_icon.ps1
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$size = 1024

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$master = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($master)
$g.SmoothingMode = 'AntiAlias'
$g.PixelOffsetMode = 'HighQuality'
$g.Clear([System.Drawing.Color]::Transparent)

# Фон: скруглённый квадрат с акцентным градиентом приложения.
$bg = New-RoundedRect 0 0 $size $size 230
$gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.PointF(0, 0)),
    (New-Object System.Drawing.PointF($size, $size)),
    [System.Drawing.Color]::FromArgb(255, 0x8B, 0x5C, 0xF6),
    [System.Drawing.Color]::FromArgb(255, 0x22, 0xD3, 0xEE))
$g.FillPath($gradient, $bg)

# Щит.
$shield = New-Object System.Drawing.Drawing2D.GraphicsPath
$shield.AddLine(512, 196, 772, 296)
$shield.AddBezier(772, 296, 772, 566, 664, 748, 512, 836)
$shield.AddBezier(512, 836, 360, 748, 252, 566, 252, 296)
$shield.CloseFigure()
$shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 20, 10, 60))
$g.TranslateTransform(0, 18)
$g.FillPath($shadow, $shield)
$g.ResetTransform()
$g.FillPath([System.Drawing.Brushes]::White, $shield)

# Замочная скважина.
$hole = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0x6D, 0x4B, 0xE0))
$g.FillEllipse($hole, 512 - 70, 400, 140, 140)
$stem = New-Object System.Drawing.Drawing2D.GraphicsPath
$stem.AddPolygon([System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF(478, 500)),
    (New-Object System.Drawing.PointF(546, 500)),
    (New-Object System.Drawing.PointF(574, 668)),
    (New-Object System.Drawing.PointF(450, 668))))
$g.FillPath($hole, $stem)
$g.Dispose()

function Get-Scaled([int]$px) {
    $bmp = New-Object System.Drawing.Bitmap($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.InterpolationMode = 'HighQualityBicubic'
    $gr.PixelOffsetMode = 'HighQuality'
    $gr.SmoothingMode = 'AntiAlias'
    $gr.DrawImage($master, 0, 0, $px, $px)
    $gr.Dispose()
    return $bmp
}

function Get-PngBytes($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

# Исходник.
$assetDir = Join-Path $root 'assets\icon'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$master.Save((Join-Path $assetDir 'icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# Android.
$densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
foreach ($d in $densities.GetEnumerator()) {
    $bmp = Get-Scaled $d.Value
    $bmp.Save((Join-Path $root "android\app\src\main\res\mipmap-$($d.Key)\ic_launcher.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Windows: .ico с PNG-кадрами.
$icoSizes = 16, 24, 32, 48, 64, 128, 256
$frames = @()
foreach ($s in $icoSizes) {
    $bmp = Get-Scaled $s
    $frames += , (Get-PngBytes $bmp)
    $bmp.Dispose()
}
$ico = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($ico)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$icoSizes.Count)
$offset = 6 + 16 * $icoSizes.Count
for ($i = 0; $i -lt $icoSizes.Count; $i++) {
    $s = $icoSizes[$i]
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $w.Write($f) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $root 'windows\runner\resources\app_icon.ico'), $ico.ToArray())
$master.Dispose()
Write-Output 'Icon updated.'
