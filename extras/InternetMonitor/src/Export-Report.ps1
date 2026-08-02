[CmdletBinding()]
param(
    [string]$Root,
    # 24 = um dia, 168 = sete dias, 720 = trinta dias, 0 = todo o histórico.
    [ValidateSet(24, 168, 720, 0)]
    [int]$Hours = 720,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
# Com -File, o padrão de um parâmetro é avaliado antes de $PSScriptRoot existir.
if (-not $Root) { $Root = $PSScriptRoot }

$dashboard = Join-Path $Root "dashboard\index.html"
$updater = Join-Path $Root "Update-DashboardData.ps1"

if (-not (Test-Path -LiteralPath $dashboard)) {
    throw "Dashboard não encontrado em $dashboard"
}

function Find-Browser {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

$periodLabel = switch ($Hours) {
    24  { "24 horas" }
    168 { "7 dias" }
    720 { "30 dias" }
    0   { "historico completo" }
}

if (-not $OutputPath) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $OutputPath = Join-Path $desktop (
        "Internet Monitor - Relatorio {0} ({1}).pdf" -f (Get-Date).ToString("yyyy-MM-dd"), $periodLabel
    )
}

Write-Host ""
Write-Host "  Internet Monitor - exportacao de relatorio" -ForegroundColor Cyan
Write-Host ("  Periodo: {0}" -f $periodLabel)
Write-Host ""

# Garante que o painel reflita as medições mais recentes antes de virar documento.
if (Test-Path -LiteralPath $updater) {
    & $updater -Root $Root
}

$browser = Find-Browser
if (-not $browser) {
    Write-Warning "Microsoft Edge ou Google Chrome não foi encontrado."
    Write-Host ""
    Write-Host "  Gere o PDF manualmente: abra o painel, clique em 'Exportar PDF'"
    Write-Host "  e escolha 'Salvar como PDF' na janela de impressão."
    Write-Host ""
    Start-Process $dashboard
    return
}

$uri = ([System.Uri]$dashboard).AbsoluteUri + ("?print=1&hours={0}" -f $Hours)
$profile = Join-Path $env:TEMP ("internet-monitor-print-{0}" -f [guid]::NewGuid())

Write-Host "  Gerando o PDF..."
try {
    $arguments = @(
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--user-data-dir=`"$profile`"",
        # Dá tempo para o data.js carregar e os gráficos serem desenhados.
        "--virtual-time-budget=10000",
        "--print-to-pdf-no-header",
        "--print-to-pdf=`"$OutputPath`"",
        "`"$uri`""
    )
    $process = Start-Process -FilePath $browser -ArgumentList $arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "O navegador retornou código $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "O arquivo não foi gerado."
    }
}
catch {
    Write-Warning ("Não foi possível gerar o PDF automaticamente: {0}" -f $_.Exception.Message)
    Write-Host ""
    Write-Host "  Alternativa: abra o painel, clique em 'Exportar PDF' e escolha"
    Write-Host "  'Salvar como PDF' na janela de impressão."
    Write-Host ""
    Start-Process $dashboard
    return
}
finally {
    Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
}

$size = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1KB)
Write-Host ""
Write-Host ("  Relatorio gerado: {0}" -f $OutputPath) -ForegroundColor Green
Write-Host ("  Tamanho: {0} KB" -f $size)
Write-Host ""
Start-Process $OutputPath
