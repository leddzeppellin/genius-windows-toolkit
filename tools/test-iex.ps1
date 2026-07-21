# Simula a execução via "irm URL | iex" / scriptblock remoto, sem rede.
$content = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\GeniusToolkit.ps1'), [Text.Encoding]::UTF8)
& ([scriptblock]::Create($content)) -SmokeTest -TargetDrive C: -Preset Extended
exit $LASTEXITCODE
