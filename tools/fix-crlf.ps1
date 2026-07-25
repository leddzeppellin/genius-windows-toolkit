# Garante CRLF (ASCII) nos arquivos .bat (batch do Windows).
$dir = Join-Path $PSScriptRoot '..'
foreach ($name in 'Genius-Toolkit.bat', 'Genius-Toolkit-Admin.bat') {
    $path = Join-Path $dir $name
    $text = [IO.File]::ReadAllText($path)
    $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.ASCIIEncoding))
    Write-Host "CRLF: $name"
}
