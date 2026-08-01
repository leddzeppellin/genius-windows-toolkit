# Diagnóstico de encoding: mostra se cada arquivo tem BOM UTF-8 e se há bytes não-ASCII.
param([string]$Path = (Join-Path $PSScriptRoot '..\extras'))

Get-ChildItem -LiteralPath $Path -Recurse -Include *.ps1, *.json, *.html, *.js, *.css -File | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
    $nonAscii = @($b | Where-Object { $_ -gt 127 }).Count
    '{0,-5} nonASCII={1,-5} {2}' -f $(if ($hasBom) { 'BOM' } else { '--' }), $nonAscii, $_.FullName.Replace($Path, '')
}
