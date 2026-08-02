[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = "Stop"
# Com -File, o padrão de um parâmetro é avaliado antes de $PSScriptRoot existir.
if (-not $Root) { $Root = $PSScriptRoot }

$speedtestExe = Join-Path $Root "bin\speedtest.exe"
$configPath = Join-Path $Root "config.json"

if (-not (Test-Path -LiteralPath $speedtestExe)) {
    throw "speedtest.exe não encontrado em $speedtestExe"
}

Write-Host ""
Write-Host "  Servidores de teste mais próximos de você" -ForegroundColor Cyan
Write-Host "  Consultando a Ookla..."
Write-Host ""

# A saída de um processo é decodificada com a codepage do console, que fora do UTF-8
# corromperia acentos nos nomes de cidade.
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $output = & $speedtestExe --servers --format=json 2>&1
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
if ($LASTEXITCODE -ne 0) {
    throw "O Speedtest não conseguiu listar os servidores: $output"
}

$servers = ($output | ConvertFrom-Json).servers
if (-not $servers) {
    throw "Nenhum servidor foi retornado."
}

$servers | ForEach-Object {
    [PSCustomObject]@{
        ID = $_.id
        Servidor = $_.name
        Local = $_.location
        Pais = $_.country
        Host = $_.host
    }
} | Format-Table -AutoSize

$current = 0
if (Test-Path -LiteralPath $configPath) {
    try {
        $current = [int](Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
            ConvertFrom-Json).servidorFixoId
    }
    catch { $current = 0 }
}

if ($current -gt 0) {
    Write-Host ("  Servidor fixo atual: {0}" -f $current) -ForegroundColor Green
}
else {
    Write-Host "  Servidor fixo atual: nenhum (escolha automática a cada teste)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Para fixar um servidor, informe o ID desejado e pressione Enter."
Write-Host "  Deixe em branco para manter a escolha automática."
Write-Host ""
$answer = Read-Host "  ID do servidor"

if ([string]::IsNullOrWhiteSpace($answer)) {
    Write-Host "  Nada foi alterado." -ForegroundColor Yellow
    return
}

$chosen = 0
if (-not [int]::TryParse($answer.Trim(), [ref]$chosen)) {
    throw "'$answer' não é um número válido."
}
if ($chosen -gt 0 -and -not ($servers | Where-Object { [int]$_.id -eq $chosen })) {
    Write-Warning "O ID $chosen não está na lista acima. Ele será gravado mesmo assim."
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config | Add-Member -NotePropertyName "servidorFixoId" -NotePropertyValue $chosen -Force
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

if ($chosen -gt 0) {
    $server = $servers | Where-Object { [int]$_.id -eq $chosen } | Select-Object -First 1
    $label = if ($server) { " ({0} - {1})" -f $server.name, $server.location } else { "" }
    Write-Host ("  Servidor fixo definido: {0}{1}" -f $chosen, $label) -ForegroundColor Green
}
else {
    Write-Host "  Escolha automática restaurada." -ForegroundColor Green
}
Write-Host "  A configuração vale a partir da próxima coleta."
Write-Host ""
