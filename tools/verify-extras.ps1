# Valida os arquivos do extras: sintaxe dos .ps1, JSON parseável e acentos legíveis.
$root = Join-Path $PSScriptRoot '..\extras\InternetMonitor'
$fail = 0

Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -eq '.ps1' } | ForEach-Object {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count -gt 0) { Write-Host "PARSE FALHOU: $($_.Name) — $($e[0].Message)" -ForegroundColor Red; $script:fail++ }
    else { Write-Host "parse ok: $($_.Name)" -ForegroundColor Green }
}

$cfg = Join-Path $root 'src\config.json'
try {
    Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    Write-Host 'config.json: JSON válido' -ForegroundColor Green
}
catch { Write-Host "config.json FALHOU: $($_.Exception.Message)" -ForegroundColor Red; $fail++ }

# Amostra de acentos lidos do instalador (deve aparecer legível)
$sample = (Get-Content -LiteralPath (Join-Path $root 'Install-InternetMonitor.ps1') |
           Select-String 'hist|autom|medi' | Select-Object -First 3)
Write-Host ''
Write-Host 'Amostra de texto com acentos:' -ForegroundColor Cyan
$sample | ForEach-Object { '  ' + $_.Line.Trim() }

if ($fail -gt 0) { exit 1 }
Write-Host ''
Write-Host 'EXTRAS OK' -ForegroundColor Green
