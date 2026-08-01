# Lê assets\genius-info-logo.png, gera base64 e injeta na linha $LogoBase64 = '...'
# do GeniusToolkit.ps1 (mantém a execução via irm|iex autossuficiente).
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$logo = Join-Path $root 'assets\genius-info-logo.png'
$target = Join-Path $root 'GeniusToolkit.ps1'

if (-not (Test-Path $logo)) {
    Write-Host "ERRO: logo não encontrada em $logo" -ForegroundColor Red
    Write-Host "Salve a imagem como assets\genius-info-logo.png e rode de novo." -ForegroundColor Yellow
    exit 1
}

# Redimensiona a cópia embutida para no máx. 520px de largura (mantém o arquivo
# original em alta). Isso mantém o script leve para o "irm | iex".
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($logo)
try {
    $maxW = 520
    if ($src.Width -gt $maxW) {
        $ratio = $maxW / $src.Width
        $w = $maxW
        $h = [int][math]::Round($src.Height * $ratio)
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.DrawImage($src, 0, 0, $w, $h)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }
    else {
        $bytes = [IO.File]::ReadAllBytes($logo)
    }
}
finally { $src.Dispose() }

$b64 = [Convert]::ToBase64String($bytes)
$text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)

# Substitui a primeira atribuição de $LogoBase64 (pode estar vazia ou já preenchida).
$pattern = "(?m)^\`$LogoBase64 = '.*?'$"
$replacement = "`$LogoBase64 = '$b64'"
if ($text -notmatch "(?m)^\`$LogoBase64 = '") {
    Write-Host 'ERRO: linha $LogoBase64 não encontrada no script.' -ForegroundColor Red
    exit 1
}
$new = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $replacement })
[IO.File]::WriteAllText($target, $new, (New-Object Text.UTF8Encoding($true)))

$kb = [math]::Round($b64.Length / 1KB, 1)
Write-Host "Logo embutida ($kb KB em base64) no GeniusToolkit.ps1." -ForegroundColor Green
