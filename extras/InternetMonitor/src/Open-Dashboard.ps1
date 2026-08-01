$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dashboard = Join-Path $PSScriptRoot "dashboard\index.html"
$dashboardUpdater = Join-Path $root "Update-DashboardData.ps1"
$logPath = Join-Path $root "logs"

if (-not (Test-Path -LiteralPath $dashboard)) {
    throw "Dashboard não encontrado em $dashboard"
}

try {
    if (-not (Test-Path -LiteralPath $dashboardUpdater)) {
        throw "Atualizador do dashboard não encontrado em $dashboardUpdater"
    }
    & $dashboardUpdater -Root $root
}
catch {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    $logLine = "{0} - Falha ao preparar o dashboard: {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $message
    Add-Content -LiteralPath (Join-Path $logPath "dashboard-erros.log") -Value $logLine -Encoding UTF8
}

Start-Process $dashboard
