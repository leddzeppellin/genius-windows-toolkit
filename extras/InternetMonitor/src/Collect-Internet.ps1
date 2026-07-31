[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$DataPath = Join-Path $Root "data"
$LogPath = Join-Path $Root "logs"
$CsvPath = Join-Path $DataPath "historico-internet.csv"
$SpeedtestExe = Join-Path $Root "bin\speedtest.exe"
$DashboardUpdater = Join-Path $Root "Update-DashboardData.ps1"
$mutex = New-Object System.Threading.Mutex($false, "Global\InternetMonitorCollector")
$hasLock = $false

New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

function Write-ErrorLog([string]$Message) {
    $cleanMessage = $Message -replace '[\r\n]+', ' '
    $logLine = "{0} - {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $cleanMessage
    Add-Content -LiteralPath (Join-Path $LogPath "coleta-erros.log") -Value $logLine -Encoding UTF8
}

function Save-Record([psobject]$Record) {
    if (Test-Path -LiteralPath $CsvPath) {
        $Record | Export-Csv -LiteralPath $CsvPath -Append -NoTypeInformation -Encoding UTF8
    }
    else {
        $Record | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    }
}

function Update-Dashboard {
    try {
        if (-not (Test-Path -LiteralPath $DashboardUpdater)) {
            throw "Atualizador do dashboard não encontrado em $DashboardUpdater"
        }
        & $DashboardUpdater -Root $Root
    }
    catch {
        Write-ErrorLog ("Falha ao atualizar o dashboard: {0}" -f $_.Exception.Message)
    }
}

function Empty-Record([string]$Status, [string]$Message) {
    [PSCustomObject][ordered]@{
        DataHora = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DownloadMbps = ""
        UploadMbps = ""
        PingMs = ""
        JitterMs = ""
        PerdaPacotesPct = ""
        ISP = ""
        Servidor = ""
        LocalServidor = ""
        URLResultado = ""
        Status = $Status
        Mensagem = $Message
    }
}

try {
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock) { exit 0 }
    if (-not (Test-Path -LiteralPath $SpeedtestExe)) {
        throw "speedtest.exe não encontrado em $SpeedtestExe"
    }

    $tempOut = Join-Path $env:TEMP ("internet-monitor-{0}.json" -f [guid]::NewGuid())
    $tempErr = Join-Path $env:TEMP ("internet-monitor-{0}.log" -f [guid]::NewGuid())
    try {
        $process = Start-Process -FilePath $SpeedtestExe -ArgumentList @(
            "--accept-license", "--accept-gdpr", "--format=json"
        ) -NoNewWindow -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr

        if (-not $process.WaitForExit(480000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "O Speedtest excedeu o limite de 8 minutos."
        }
        $process.WaitForExit()
        $stdout = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
        if ($process.ExitCode -ne 0) {
            throw "Speedtest retornou código $($process.ExitCode): $stderr"
        }
        if (-not $stdout) { throw "O Speedtest não retornou dados." }

        $result = $stdout | ConvertFrom-Json
        $loss = if ($null -ne $result.packetLoss) {
            [math]::Round([double]$result.packetLoss, 2)
        } else { "" }
        $jitter = if ($null -ne $result.ping.jitter) {
            [math]::Round([double]$result.ping.jitter, 2)
        } else { "" }

        $record = [PSCustomObject][ordered]@{
            DataHora = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            DownloadMbps = [math]::Round(([double]$result.download.bandwidth * 8 / 1000000), 2)
            UploadMbps = [math]::Round(([double]$result.upload.bandwidth * 8 / 1000000), 2)
            PingMs = [math]::Round([double]$result.ping.latency, 2)
            JitterMs = $jitter
            PerdaPacotesPct = $loss
            ISP = [string]$result.isp
            Servidor = [string]$result.server.name
            LocalServidor = [string]$result.server.location
            URLResultado = [string]$result.result.url
            Status = "Sucesso"
            Mensagem = ""
        }
        Save-Record $record
        Update-Dashboard
    }
    finally {
        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
    }
}
catch {
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    Write-ErrorLog $message
    Save-Record (Empty-Record -Status "Erro" -Message $message)
    Update-Dashboard
    exit 1
}
finally {
    if ($hasLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
