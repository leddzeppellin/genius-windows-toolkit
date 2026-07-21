# Ferramenta interna de validação: garante BOM UTF-8 e checa a sintaxe do toolkit.
param([string]$Path = (Join-Path $PSScriptRoot '..\GeniusToolkit.ps1'))

$Path = (Resolve-Path $Path).Path
$content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($true)))

$bytes = [IO.File]::ReadAllBytes($Path)
Write-Host ("BOM: {0},{1},{2} (esperado 239,187,191)" -f $bytes[0], $bytes[1], $bytes[2])

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Host ("ERRO linha {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
    }
    exit 1
}
Write-Host 'PARSE OK' -ForegroundColor Green
