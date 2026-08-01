# Gera um ícone quadrado (o "G" da logo) em .ico multi-resolução + PNG base64
# para o ícone da janela. Recorta a região superior-central da logo.
param([switch]$PreviewOnly)

Add-Type -AssemblyName System.Drawing
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$logo = Join-Path $root 'assets\genius-info-logo.png'
if (-not (Test-Path $logo)) { Write-Host "ERRO: $logo não existe"; exit 1 }

$src = [System.Drawing.Bitmap]::FromFile($logo)
$W = $src.Width; $H = $src.Height
Write-Host "Logo: ${W}x${H}"

# Caixa quadrada centrada no "G" (topo-centro da arte).
$side = [int]([math]::Round($H * 0.46))
$cx = [int]([math]::Round($W * 0.5))
$cy = [int]([math]::Round($H * 0.31))
$left = [math]::Max(0, $cx - [int]($side / 2))
$top = [math]::Max(0, $cy - [int]($side / 2))
if (($left + $side) -gt $W) { $side = $W - $left }
if (($top + $side) -gt $H) { $side = $H - $top }

$crop = New-Object System.Drawing.Bitmap $side, $side
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $side, $side), (New-Object System.Drawing.Rectangle $left, $top, $side, $side), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$src.Dispose()

# Salva um preview PNG 256 para conferência
$previewPng = Join-Path $root 'assets\icon-preview.png'
$p256 = New-Object System.Drawing.Bitmap 256, 256
$pg = [System.Drawing.Graphics]::FromImage($p256)
$pg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$pg.DrawImage($crop, 0, 0, 256, 256)
$pg.Dispose()
$p256.Save($previewPng, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "Preview: $previewPng"

if ($PreviewOnly) { $crop.Dispose(); $p256.Dispose(); exit 0 }

# Gera o .ico multi-resolução (16..256)
$icoPath = Join-Path $root 'assets\genius-info.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $gg = [System.Drawing.Graphics]::FromImage($bmp)
    $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gg.DrawImage($crop, 0, 0, $s, $s)
    $gg.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , $ms.ToArray()
    $bmp.Dispose(); $ms.Dispose()
}

$fs = [IO.File]::Open($icoPath, [IO.FileMode]::Create)
$bw = New-Object IO.BinaryWriter $fs
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$len); $bw.Write([UInt32]$offset)
    $offset += $len
}
foreach ($png in $pngs) { $bw.Write($png) }
$bw.Flush(); $bw.Close(); $fs.Close()
Write-Host "Ícone: $icoPath"

# PNG base64 (256) para o ícone da janela via irm|iex, injetado em $IconBase64
$icoB64 = [Convert]::ToBase64String((Get-Content $previewPng -Encoding Byte -Raw))
$target = Join-Path $root 'GeniusToolkit.ps1'
$text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$newLine = "`$IconBase64 = '$icoB64'"
if ($text -match "(?m)^\`$IconBase64 = '") {
    $text = [regex]::Replace($text, "(?m)^\`$IconBase64 = '.*?'$", [System.Text.RegularExpressions.MatchEvaluator] { param($m) $newLine })
}
elseif ($text -match "(?m)^\`$LogoBase64 = '.*?'$") {
    # Insere a linha $IconBase64 logo após a linha $LogoBase64
    $text = [regex]::Replace($text, "(?m)^(\`$LogoBase64 = '.*?')$", [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + "`r`n" + $newLine })
}
else {
    Write-Host 'AVISO: nem $IconBase64 nem $LogoBase64 encontrados — pulei o embed.'
    $crop.Dispose(); $p256.Dispose(); exit 0
}
[IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($true)))
Write-Host ("Ícone embutido em \$IconBase64 (" + [math]::Round($icoB64.Length / 1KB, 1) + " KB).")

$crop.Dispose(); $p256.Dispose()
