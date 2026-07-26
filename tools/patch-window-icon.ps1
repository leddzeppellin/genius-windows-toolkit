# Insere (uma vez) o código que define o ícone da janela a partir de $IconBase64.
$target = Join-Path $PSScriptRoot '..\GeniusToolkit.ps1'
$target = (Resolve-Path $target).Path
$text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)

if ($text -match '\$Window\.Icon = \$iconImg') {
    Write-Host 'Ícone da janela já estava configurado. Nada a fazer.'
    exit 0
}

$anchor = "        `$sync.Controls['TitleLogo'].Visibility = 'Visible'"
if ($text -notmatch [regex]::Escape($anchor)) {
    Write-Host 'ERRO: âncora não encontrada.'; exit 1
}

$insert = @"
$anchor

        try {
            if (-not [string]::IsNullOrWhiteSpace(`$IconBase64)) {
                `$iconImg = New-Object System.Windows.Media.Imaging.BitmapImage
                `$ims = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String(`$IconBase64))
                `$iconImg.BeginInit()
                `$iconImg.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                `$iconImg.StreamSource = `$ims
                `$iconImg.EndInit()
                `$iconImg.Freeze()
                `$Window.Icon = `$iconImg
            }
            else { `$Window.Icon = `$img }
        }
        catch { }
"@

$text = $text.Replace($anchor, $insert)
[IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($true)))
Write-Host 'Ícone da janela configurado.'
