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

# O carregador get.ps1 PRECISA ser ASCII puro e sem BOM (senão o irm | iex quebra).
$loader = Join-Path (Split-Path $Path) 'get.ps1'
if (Test-Path $loader) {
    $loaderBytes = [IO.File]::ReadAllBytes($loader)
    if ($loaderBytes[0] -eq 239) {
        Write-Host 'ERRO: get.ps1 está com BOM — remova, o irm | iex vai quebrar.' -ForegroundColor Red
        exit 1
    }
    $nonAscii = @($loaderBytes | Where-Object { $_ -gt 127 })
    if ($nonAscii.Count -gt 0) {
        Write-Host "ERRO: get.ps1 contém $($nonAscii.Count) byte(s) não-ASCII — deve ser ASCII puro." -ForegroundColor Red
        exit 1
    }
    $lTokens = $null; $lErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($loader, [ref]$lTokens, [ref]$lErrors) | Out-Null
    if ($lErrors.Count -gt 0) {
        foreach ($e in $lErrors) { Write-Host ("ERRO get.ps1 linha {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
        exit 1
    }
    Write-Host 'LOADER OK (ASCII puro, sem BOM)' -ForegroundColor Green
}
