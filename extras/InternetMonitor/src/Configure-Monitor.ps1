[CmdletBinding()]
param(
    [string]$Root,
    # Modo não interativo usado pela auto-elevação: aplica o intervalo e encerra.
    [int]$SetIntervalMinutes = 0
)

$ErrorActionPreference = "Stop"
# Com -File, o padrão de um parâmetro é avaliado antes de $PSScriptRoot existir.
if (-not $Root) { $Root = $PSScriptRoot }

$TaskName = "InternetMonitor - Coleta"
$ConfigPath = Join-Path $Root "config.json"
$CollectorScript = Join-Path $Root "Collect-Internet.ps1"
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return [PSCustomObject]@{} }
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-ConfigValue($Config, [string]$Name, $Default) {
    $property = $Config.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value -and "$($property.Value)" -ne "") {
        return $property.Value
    }
    return $Default
}

function Read-Number([string]$Prompt, $Current, [double]$Min, [double]$Max) {
    $answer = Read-Host ("  {0} [atual: {1}]" -f $Prompt, $Current)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
    $parsed = 0.0
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $normalized = $answer.Trim().Replace(",", ".")
    if (-not [double]::TryParse($normalized, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$parsed)) {
        Write-Host "  Valor inválido; nada foi alterado." -ForegroundColor Yellow
        return $null
    }
    if ($parsed -lt $Min -or $parsed -gt $Max) {
        Write-Host ("  Informe um valor entre {0} e {1}." -f $Min, $Max) -ForegroundColor Yellow
        return $null
    }
    return $parsed
}

# Uma tarefa registrada para SYSTEM nasce ilegível para contas padrão: consultá-la sem
# elevação devolve "acesso negado", e o menu não conseguiria nem informar se a coleta
# está ativa. Conceder leitura ao grupo Usuários resolve sem dar poder de alteração.
function Grant-TaskRead {
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $task = $service.GetFolder("\").GetTask($TaskName)
        $daclOnly = 4
        $sddl = $task.GetSecurityDescriptor($daclOnly)
        # 0x1200a9 é como o Windows normaliza GRGX depois de gravar.
        if ($sddl -notmatch ";BU\)" ) {
            $task.SetSecurityDescriptor($sddl + "(A;;GRGX;;;BU)", 0)
        }
    }
    catch {
        Write-Verbose ("Não foi possível liberar a leitura da tarefa: {0}" -f $_.Exception.Message)
    }
}

# Distingue "não existe" de "existe mas não posso ler" pelo HResult, que não depende do
# idioma do Windows: 0x80070002 é arquivo não encontrado e 0x80070005 é acesso negado.
function Get-CollectorTaskState {
    $state = [PSCustomObject]@{
        Exists = $false; Readable = $false; State = ""
        NextRun = $null; LastRun = $null; LastResult = $null
    }
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $task = $service.GetFolder("\").GetTask($TaskName)
        $state.Exists = $true
        $state.Readable = $true
        $state.State = switch ([int]$task.State) {
            1 { "desativada" }
            2 { "na fila" }
            3 { "ativa" }
            4 { "executando agora" }
            default { "desconhecida" }
        }
        try { $state.NextRun = $task.NextRunTime } catch { }
        try { $state.LastRun = $task.LastRunTime } catch { }
        try { $state.LastResult = $task.LastTaskResult } catch { }
    }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        if ($exception.HResult -eq 0x80070005) { $state.Exists = $true }
    }
    return $state
}

# Trigger diário repetindo a cada N minutos por 24 horas. É mais confiável que uma
# repetição única de duração muito longa, que o Agendador rejeita em alguns casos.
function Register-CollectorTask([int]$IntervalMinutes) {
    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $CollectorScript
    )
    $trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description (
            "Executa o Speedtest CLI a cada $IntervalMinutes minutos e grava o histórico local."
        ) -Force | Out-Null

    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "A tarefa foi registrada mas não pôde ser localizada em seguida."
    }
    Grant-TaskRead
}

function Set-Interval([int]$Minutes) {
    $config = Get-Config
    $previousInterval = [double](Get-ConfigValue $config "collectionIntervalMinutes" 60)
    $previousAutomaticStale = [math]::Ceiling($previousInterval * 2.5)
    $currentStale = Get-ConfigValue $config "staleAfterMinutes" $null
    # Só reajusta o aviso de dados desatualizados se ele nunca foi personalizado.
    $staleWasAutomatic = ($null -eq $currentStale) -or
        ([math]::Abs([double]$currentStale - $previousAutomaticStale) -lt 0.001)

    Register-CollectorTask $Minutes

    $config | Add-Member -NotePropertyName "collectionIntervalMinutes" -NotePropertyValue $Minutes -Force
    if ($staleWasAutomatic) {
        $config | Add-Member -NotePropertyName "staleAfterMinutes" `
            -NotePropertyValue ([int][math]::Ceiling($Minutes * 2.5)) -Force
    }
    Save-Config $config
}

function Invoke-ElevatedInterval([int]$Minutes) {
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Root", "`"$Root`"",
        "-SetIntervalMinutes", $Minutes
    )
    $process = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    return ($process.ExitCode -eq 0)
}

# ---------------------------------------------------------------------------
# Modo não interativo (chamado já elevado)
# ---------------------------------------------------------------------------
if ($SetIntervalMinutes -gt 0) {
    if (-not (Test-Administrator)) {
        Write-Error "É necessário executar como administrador para alterar a tarefa agendada."
        exit 1
    }
    Set-Interval $SetIntervalMinutes
    exit 0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
function Show-TaskStatus {
    $task = Get-CollectorTaskState

    if (-not $task.Exists) {
        Write-Host "  Coleta automática: NÃO CONFIGURADA" -ForegroundColor Red
        Write-Host "                     use a opção 1 para criar a tarefa" -ForegroundColor Red
        return
    }
    if (-not $task.Readable) {
        Write-Host "  Coleta automática: configurada" -ForegroundColor Green
        Write-Host "                     execute a opção 1 uma vez para poder ver os detalhes"
        return
    }

    $color = if ($task.State -eq "desativada") { "Yellow" } else { "Green" }
    Write-Host ("  Coleta automática: {0}" -f $task.State) -ForegroundColor $color
    if ($task.NextRun -and $task.NextRun.Year -gt 1900) {
        Write-Host ("                     próxima medição em {0}" -f $task.NextRun)
    }
    if ($task.LastRun -and $task.LastRun.Year -gt 1900) {
        $outcome = if ($task.LastResult -eq 0) { "sucesso" } else { "código $($task.LastResult)" }
        Write-Host ("                     última execução {0} ({1})" -f $task.LastRun, $outcome)
    }
}

function Show-Menu {
    $config = Get-Config
    $interval = Get-ConfigValue $config "collectionIntervalMinutes" 60
    $provider = Get-ConfigValue $config "provedorContratado" ""
    $plan = Get-ConfigValue $config "planoContratado" ""
    $down = Get-ConfigValue $config "contratadoDownloadMbps" 0
    $up = Get-ConfigValue $config "contratadoUploadMbps" 0
    $server = Get-ConfigValue $config "servidorFixoId" 0

    $planLabel = (@($provider, $plan) | Where-Object { $_ }) -join " · "
    if (-not $planLabel) { $planLabel = "não informado" }
    $speedLabel = if ([double]$down -gt 0 -or [double]$up -gt 0) {
        "{0} / {1} Mbps" -f $down, $up
    } else { "não informada" }
    $serverLabel = if ([int]$server -gt 0) { "$server" } else { "automático" }

    Write-Host ""
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host "   Internet Monitor - Configuração" -ForegroundColor Cyan
    Write-Host "  ===========================================" -ForegroundColor Cyan
    Write-Host ""
    Show-TaskStatus
    Write-Host ""
    Write-Host ("  1) Intervalo entre medições .... {0} minutos" -f $interval)
    Write-Host ("  2) Plano contratado ............ {0}" -f $planLabel)
    Write-Host ("  3) Velocidade contratada ....... {0}" -f $speedLabel)
    Write-Host ("  4) Servidor de teste ........... {0}" -f $serverLabel)
    Write-Host ("  5) Limites do painel")
    Write-Host ("  6) Exportar relatório em PDF")
    Write-Host ("  7) Abrir o painel")
    Write-Host ("  0) Sair")
    Write-Host ""
}

function Export-Report {
    Write-Host ""
    Write-Host "  Período do relatório:"
    Write-Host "    1) últimas 24 horas"
    Write-Host "    2) últimos 7 dias"
    Write-Host "    3) últimos 30 dias  (recomendado)"
    Write-Host "    4) todo o histórico"
    Write-Host ""
    $answer = Read-Host "  Escolha [3]"
    $hours = switch ($answer.Trim()) {
        "1" { 24 }
        "2" { 168 }
        "4" { 0 }
        default { 720 }
    }
    & (Join-Path $Root "Export-Report.ps1") -Root $Root -Hours $hours
}

function Edit-Interval {
    $config = Get-Config
    $current = Get-ConfigValue $config "collectionIntervalMinutes" 60
    Write-Host ""
    Write-Host "  Cada medição transfere uma quantidade relevante de dados." -ForegroundColor Yellow
    Write-Host "  Em um link de 500 Mbps, algo entre 500 MB e 1,5 GB por teste." -ForegroundColor Yellow
    Write-Host "  Intervalos menores que 30 minutos consomem muita franquia." -ForegroundColor Yellow
    Write-Host ""
    $minutes = Read-Number "Minutos entre medições (15 a 1440)" $current 15 1440
    if ($null -eq $minutes) { return }

    Write-Host ""
    Write-Host "  Alterar a tarefa agendada exige privilégio de administrador."
    Write-Host "  Uma confirmação do Windows será exibida."
    if (Test-Administrator) {
        Set-Interval ([int]$minutes)
        Write-Host ("  Intervalo definido: {0} minutos." -f [int]$minutes) -ForegroundColor Green
    }
    elseif (Invoke-ElevatedInterval ([int]$minutes)) {
        Write-Host ("  Intervalo definido: {0} minutos." -f [int]$minutes) -ForegroundColor Green
    }
    else {
        Write-Host "  Não foi possível alterar a tarefa agendada." -ForegroundColor Red
    }
}

function Edit-Plan {
    $config = Get-Config
    Write-Host ""
    $provider = Read-Host ("  Nome do provedor [atual: {0}]" -f (Get-ConfigValue $config "provedorContratado" "vazio"))
    $plan = Read-Host ("  Nome do plano [atual: {0}]" -f (Get-ConfigValue $config "planoContratado" "vazio"))
    if (-not [string]::IsNullOrWhiteSpace($provider)) {
        $config | Add-Member -NotePropertyName "provedorContratado" -NotePropertyValue $provider.Trim() -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($plan)) {
        $config | Add-Member -NotePropertyName "planoContratado" -NotePropertyValue $plan.Trim() -Force
    }
    Save-Config $config
    Write-Host "  Plano atualizado." -ForegroundColor Green
}

function Edit-Speeds {
    $config = Get-Config
    Write-Host ""
    Write-Host "  Informe a velocidade do seu contrato. Use 0 para ocultar o painel"
    Write-Host "  de conformidade."
    Write-Host ""
    $down = Read-Number "Download contratado em Mbps" (Get-ConfigValue $config "contratadoDownloadMbps" 0) 0 100000
    if ($null -ne $down) {
        $config | Add-Member -NotePropertyName "contratadoDownloadMbps" -NotePropertyValue $down -Force
    }
    $up = Read-Number "Upload contratado em Mbps" (Get-ConfigValue $config "contratadoUploadMbps" 0) 0 100000
    if ($null -ne $up) {
        $config | Add-Member -NotePropertyName "contratadoUploadMbps" -NotePropertyValue $up -Force
    }
    Save-Config $config
    Write-Host "  Velocidade contratada atualizada." -ForegroundColor Green
}

function Edit-Limits {
    $config = Get-Config
    Write-Host ""
    Write-Host "  Limites usados apenas para destacar os cartões do painel."
    Write-Host "  Deixe em branco para manter o valor atual."
    Write-Host ""
    $fields = @(
        @{ Name = "downloadMinMbps";   Prompt = "Download mínimo em Mbps"; Min = 0; Max = 100000 }
        @{ Name = "uploadMinMbps";     Prompt = "Upload mínimo em Mbps";   Min = 0; Max = 100000 }
        @{ Name = "pingMaxMs";         Prompt = "Ping máximo em ms";       Min = 0; Max = 10000 }
        @{ Name = "jitterMaxMs";       Prompt = "Jitter máximo em ms";     Min = 0; Max = 10000 }
        @{ Name = "packetLossMaxPct";  Prompt = "Perda máxima em %";       Min = 0; Max = 100 }
    )
    foreach ($field in $fields) {
        $value = Read-Number $field.Prompt (Get-ConfigValue $config $field.Name 0) $field.Min $field.Max
        if ($null -ne $value) {
            $config | Add-Member -NotePropertyName $field.Name -NotePropertyValue $value -Force
        }
    }
    Save-Config $config
    Write-Host "  Limites atualizados." -ForegroundColor Green
}

while ($true) {
    Show-Menu
    $choice = Read-Host "  Escolha uma opção"
    switch ($choice.Trim()) {
        "1" { Edit-Interval }
        "2" { Edit-Plan }
        "3" { Edit-Speeds }
        "4" { & (Join-Path $Root "List-Servers.ps1") -Root $Root }
        "5" { Edit-Limits }
        "6" { Export-Report }
        "7" { & (Join-Path $Root "Open-Dashboard.ps1") -Root $Root; return }
        "0" { return }
        default { Write-Host "  Opção inválida." -ForegroundColor Yellow }
    }
    Write-Host ""
    Read-Host "  Pressione Enter para voltar ao menu" | Out-Null
}
