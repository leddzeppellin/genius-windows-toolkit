[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [ValidateRange(1, 50000)]
    [int]$MaxRows = 5000
)

$ErrorActionPreference = "Stop"
$csvPath = Join-Path $Root "data\historico-internet.csv"
$configPath = Join-Path $Root "config.json"
$dashboardPath = Join-Path $Root "dashboard"
$dashboardData = Join-Path $dashboardPath "data.js"

if (-not (Test-Path -LiteralPath $dashboardPath -PathType Container)) {
    throw "Pasta do dashboard não encontrada em $dashboardPath"
}

$rows = @()
if (Test-Path -LiteralPath $csvPath) {
    $rows = @(Import-Csv -LiteralPath $csvPath | Select-Object -Last $MaxRows)
}

$config = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    [PSCustomObject]@{}
}

$historyJson = ConvertTo-Json -InputObject @($rows) -Compress -Depth 4
$configJson = ConvertTo-Json -InputObject $config -Compress -Depth 4
$javascript = "window.INTERNET_MONITOR_DATA=$historyJson;window.INTERNET_MONITOR_CONFIG=$configJson;"
$temporaryData = Join-Path $dashboardPath ("data-{0}.tmp" -f [guid]::NewGuid())

try {
    Set-Content -LiteralPath $temporaryData -Value $javascript -Encoding UTF8
    Move-Item -LiteralPath $temporaryData -Destination $dashboardData -Force
}
finally {
    Remove-Item -LiteralPath $temporaryData -Force -ErrorAction SilentlyContinue
}
