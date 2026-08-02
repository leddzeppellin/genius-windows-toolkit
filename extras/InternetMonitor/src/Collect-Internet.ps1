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

    # Executado via System.Diagnostics.Process porque com "Start-Process -PassThru"
    # (sem -Wait) a propriedade ExitCode volta NULA — e "$null -ne 0" fazia o script
    # tratar TODA medição bem-sucedida como falha.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SpeedtestExe
    $psi.Arguments = "--accept-license --accept-gdpr --format=json"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        # Leitura assíncrona dos dois fluxos evita travamento se um deles encher
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(480000)) {
            try { $process.Kill() } catch { }
            throw "O Speedtest excedeu o limite de 8 minutos."
        }

        $stdout = $outTask.Result
        $stderr = $errTask.Result
        $exitCode = $process.ExitCode

        if ($exitCode -ne 0) {
            $detalhe = if ([string]::IsNullOrWhiteSpace($stderr)) { "(sem detalhes)" } else { $stderr.Trim() }
            throw "Speedtest retornou código ${exitCode}: $detalhe"
        }
        if (-not $stdout) { throw "O Speedtest não retornou dados." }

        # O Speedtest emite avisos não fatais (ex.: "Cannot open socket") e ainda
        # assim conclui a medição. Registramos como aviso, sem interromper.
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-ErrorLog ("Aviso do Speedtest (medição concluída mesmo assim): {0}" -f $stderr.Trim())
        }

        # A saída pode ter mais de uma linha JSON (logs + resultado): usa a do resultado.
        $linhaResultado = $stdout -split "`r?`n" |
            Where-Object { $_.Trim() -and $_ -match '"type"\s*:\s*"result"' } |
            Select-Object -Last 1
        if (-not $linhaResultado) {
            $linhaResultado = $stdout -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
        }

        $result = $linhaResultado | ConvertFrom-Json
        if ($null -eq $result.download) { throw "Resposta do Speedtest sem dados de medição." }
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
        if ($process) { $process.Dispose() }
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
