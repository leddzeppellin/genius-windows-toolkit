[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = "Stop"
# Com -File, o padrão de um parâmetro é avaliado antes de $PSScriptRoot existir.
if (-not $Root) { $Root = $PSScriptRoot }

Write-Host ""
Write-Host "  Internet Monitor - medicao sob demanda" -ForegroundColor Cyan
Write-Host "  Aguarde: o teste transfere dados e pode levar ate 2 minutos."
Write-Host ""

& (Join-Path $Root "Collect-Internet.ps1") -Root $Root
$collectorExitCode = $LASTEXITCODE

if ($collectorExitCode -eq 0) {
    Write-Host "  Medicao concluida." -ForegroundColor Green
}
else {
    Write-Warning "A medicao falhou. Consulte $Root\logs\coleta-erros.log."
}

& (Join-Path $Root "Open-Dashboard.ps1")

if ($collectorExitCode -ne 0) {
    Write-Host ""
    Read-Host "  Pressione Enter para fechar"
}
