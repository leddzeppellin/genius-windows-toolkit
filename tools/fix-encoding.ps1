# Normaliza o encoding dos arquivos do extras:
#  - .ps1  -> UTF-8 COM BOM  (o PowerShell 5.1 lê arquivos sem BOM como ANSI e
#             corrompe os acentos: "histórico" vira "histÃ³rico")
#  - demais (.json/.js/.css/.html/.md) -> UTF-8 SEM BOM (BOM quebra ConvertFrom-Json
#             e pode atrapalhar JS/CSS)
param([string]$Path = (Join-Path $PSScriptRoot '..\extras'))

$addBom = 0
$delBom = 0

Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object {
    $ext = $_.Extension.ToLower()
    if ($ext -notin '.ps1', '.psm1', '.json', '.js', '.css', '.html', '.md', '.txt') { return }

    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    $wantBom = ($ext -in '.ps1', '.psm1')

    if ($wantBom -and -not $hasBom) {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($true)))
        Write-Host "+BOM  $($_.Name)" -ForegroundColor Green
        $addBom++
    }
    elseif (-not $wantBom -and $hasBom) {
        $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding($false)))
        Write-Host "-BOM  $($_.Name)" -ForegroundColor Yellow
        $delBom++
    }
}

Write-Host "BOM adicionado: $addBom | BOM removido: $delBom"
