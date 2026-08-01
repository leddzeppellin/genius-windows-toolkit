[CmdletBinding()]
param(
    [ValidateRange(15, 1440)]
    [int]$IntervalMinutes = 60,
    [switch]$NoInitialTest,
    [switch]$DoNotOpenDashboard
)

$ErrorActionPreference = "Stop"
$InstallPath = "C:\InternetMonitor"
$TaskCollector = "InternetMonitor - Coleta"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Execute este instalador como administrador."
    }
}

function Find-Speedtest {
    $known = @(
        (Join-Path $InstallPath "bin\speedtest.exe"),
        "$env:ProgramFiles\Speedtest CLI\speedtest.exe",
        "$env:ProgramFiles\Ookla\Speedtest CLI\speedtest.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\speedtest.exe"
    )

    foreach ($candidate in $known) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command speedtest.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $roots = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:ProgramFiles\WinGet\Packages"
    )
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -LiteralPath $root -Filter speedtest.exe -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

Assert-Administrator

Write-Step "Preparando as pastas"
$directories = @(
    $InstallPath,
    (Join-Path $InstallPath "bin"),
    (Join-Path $InstallPath "dashboard"),
    (Join-Path $InstallPath "data"),
    (Join-Path $InstallPath "logs")
)
foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

Write-Step "Preservando o histórico existente"
$legacyCsv = Join-Path $InstallPath "historico-internet.csv"
$currentCsv = Join-Path $InstallPath "data\historico-internet.csv"
if ((Test-Path -LiteralPath $legacyCsv) -and -not (Test-Path -LiteralPath $currentCsv)) {
    $legacyRows = @(Import-Csv -LiteralPath $legacyCsv)
    $migratedRows = foreach ($row in $legacyRows) {
        [PSCustomObject][ordered]@{
            DataHora = $row.DataHora
            DownloadMbps = $row.DownloadMbps
            UploadMbps = $row.UploadMbps
            PingMs = $row.PingMs
            JitterMs = $row.JitterMs
            PerdaPacotesPct = $row.PerdaPacotesPct
            ISP = $row.ISP
            Servidor = $row.Servidor
            LocalServidor = $row.LocalServidor
            URLResultado = $row.URLResultado
            Status = if ($row.Status) { $row.Status } else { "Sucesso" }
            Mensagem = ""
        }
    }
    if ($migratedRows.Count) {
        $migratedRows | Export-Csv -LiteralPath $currentCsv -NoTypeInformation -Encoding UTF8
    }
    Copy-Item -LiteralPath $legacyCsv -Destination (Join-Path $InstallPath "data\historico-legado-backup.csv") -Force
}

Write-Step "Instalando o Speedtest CLI"
$speedtestPath = Find-Speedtest
if (-not $speedtestPath) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "WinGet não foi encontrado. Atualize o 'Instalador de Aplicativo' pela Microsoft Store e tente novamente."
    }

    & $winget.Source install --id Ookla.Speedtest.CLI -e --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "O WinGet não conseguiu instalar Ookla.Speedtest.CLI (código $LASTEXITCODE)."
    }
    $speedtestPath = Find-Speedtest
}
if (-not $speedtestPath) {
    throw "O Speedtest CLI foi instalado, mas speedtest.exe não foi localizado."
}
$bundledSpeedtest = Join-Path $InstallPath "bin\speedtest.exe"
$sourceSpeedtest = (Resolve-Path -LiteralPath $speedtestPath).Path
$destinationSpeedtest = if (Test-Path -LiteralPath $bundledSpeedtest) {
    (Resolve-Path -LiteralPath $bundledSpeedtest).Path
} else {
    $bundledSpeedtest
}
if (-not [string]::Equals($sourceSpeedtest, $destinationSpeedtest, [StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $sourceSpeedtest -Destination $bundledSpeedtest -Force
}

Write-Step "Copiando os componentes"
$sourcePath = Join-Path $PSScriptRoot "src"
$files = @(
    "Collect-Internet.ps1",
    "Open-Dashboard.ps1",
    "Update-DashboardData.ps1"
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $sourcePath $file) -Destination (Join-Path $InstallPath $file) -Force
}
Copy-Item -Path (Join-Path $sourcePath "dashboard\*") -Destination (Join-Path $InstallPath "dashboard") -Recurse -Force

$configPath = Join-Path $InstallPath "config.json"
$configWasInstalled = Test-Path -LiteralPath $configPath
$configSource = if ($configWasInstalled) {
    $configPath
} else {
    Join-Path $sourcePath "config.json"
}
$config = Get-Content -LiteralPath $configSource -Raw -Encoding UTF8 | ConvertFrom-Json
$previousInterval = if ($null -ne $config.collectionIntervalMinutes) {
    [double]$config.collectionIntervalMinutes
} else {
    60
}
$previousAutomaticStale = [math]::Ceiling($previousInterval * 2.5)
$staleWasAutomatic = ($null -eq $config.staleAfterMinutes) -or
    ([math]::Abs([double]$config.staleAfterMinutes - $previousAutomaticStale) -lt 0.001)

$config | Add-Member -NotePropertyName "collectionIntervalMinutes" -NotePropertyValue $IntervalMinutes -Force
if ($staleWasAutomatic) {
    $config | Add-Member -NotePropertyName "staleAfterMinutes" `
        -NotePropertyValue ([int][math]::Ceiling($IntervalMinutes * 2.5)) -Force
}
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

Write-Step "Criando as tarefas automáticas"
$powerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$collectorAction = New-ScheduledTaskAction -Execute $powerShellExe -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallPath "Collect-Internet.ps1")
)
$collectorTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$collectorPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$collectorSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskCollector -Action $collectorAction -Trigger $collectorTrigger `
    -Principal $collectorPrincipal -Settings $collectorSettings -Description (
        "Executa o Speedtest CLI a cada $IntervalMinutes minutos e grava o histórico local."
    ) -Force | Out-Null

Write-Step "Criando o atalho na Área de Trabalho"
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "Internet Monitor.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powerShellExe
$shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\InternetMonitor\Open-Dashboard.ps1"'
$shortcut.WorkingDirectory = $InstallPath
$shortcut.IconLocation = "$env:SystemRoot\System32\netshell.dll,0"
$shortcut.Save()

if (-not $NoInitialTest) {
    Write-Step "Executando a primeira medição (pode levar alguns minutos)"
    & $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $InstallPath "Collect-Internet.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "A primeira medição falhou. Consulte C:\InternetMonitor\logs\coleta-erros.log."
    }
}

Write-Step "Iniciando o dashboard"
if (-not $DoNotOpenDashboard) {
    & (Join-Path $InstallPath "Open-Dashboard.ps1")
}

Write-Host "`nInstalação concluída." -ForegroundColor Green
Write-Host "Coleta: a cada $IntervalMinutes minutos, como SYSTEM (sem senha)."
Write-Host "Dashboard: C:\InternetMonitor\dashboard\index.html"
Write-Host "Histórico: C:\InternetMonitor\data\historico-internet.csv"
