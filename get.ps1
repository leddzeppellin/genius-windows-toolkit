# Genius Windows Toolkit - carregador remoto.
# Este arquivo e ASCII puro (sem BOM, sem acentos) de proposito: e o unico formato
# 100% seguro para o padrao "irm URL | iex" no PowerShell 5.1.
# Ele baixa o script principal (UTF-8 com BOM, com acentos e emojis), remove o
# caractere BOM que o Invoke-RestMethod preserva e executa repassando os argumentos.
[CmdletBinding()]
param(
    [string]$TargetDrive,
    [string]$Preset,
    [string]$Config,
    [string]$ScriptUrl,
    [switch]$SmokeTest
)

$mainUrl   = 'https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/GeniusToolkit.ps1'
$loaderUrl = 'https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/get.ps1'

$source = Invoke-RestMethod -Uri $mainUrl
if ($source.Length -gt 0 -and $source[0] -eq [char]0xFEFF) {
    $source = $source.Substring(1)
}

# Repassa apenas os parametros informados (hashtable splat trata switches corretamente).
$forward = @{}
foreach ($name in $PSBoundParameters.Keys) {
    $forward[$name] = $PSBoundParameters[$name]
}
if (-not $forward.ContainsKey('ScriptUrl')) {
    $forward['ScriptUrl'] = $loaderUrl
}

& ([scriptblock]::Create($source)) @forward
