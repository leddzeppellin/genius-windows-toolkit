# Genius Windows Toolkit - carregador remoto.
# Este arquivo e ASCII puro (sem BOM, sem acentos) de proposito: e o unico formato
# 100% seguro para o padrao "irm URL | iex" no PowerShell 5.1.
# Ele baixa o script principal (UTF-8 com BOM, com acentos e emojis), remove o
# caractere BOM que o Invoke-RestMethod preserva e executa repassando os argumentos.

$mainUrl   = 'https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/GeniusToolkit.ps1'
$loaderUrl = 'https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/get.ps1'

$source = Invoke-RestMethod -Uri $mainUrl
if ($source.Length -gt 0 -and $source[0] -eq [char]0xFEFF) {
    $source = $source.Substring(1)
}

$argList = @()
if (Test-Path variable:args) { $argList = @($args) }
if ($argList -notcontains '-ScriptUrl') {
    $argList += @('-ScriptUrl', $loaderUrl)
}

& ([scriptblock]::Create($source)) @argList
