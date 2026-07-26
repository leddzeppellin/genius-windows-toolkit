# Cria um atalho "Genius Windows Toolkit" na Área de Trabalho, apontando para o
# launcher Admin e usando o ícone da marca (assets\genius-info.ico).
$appDir = Split-Path -Parent $PSScriptRoot   # pasta do app (pai de \tools)

$target = Join-Path $appDir 'Genius-Toolkit-Admin.bat'
if (-not (Test-Path $target)) { $target = Join-Path $appDir 'Genius-Toolkit.bat' }
if (-not (Test-Path $target)) {
    Write-Host 'ERRO: launcher .bat não encontrado ao lado deste script.' -ForegroundColor Red
    exit 1
}

$icon = Join-Path $appDir 'assets\genius-info.ico'
$ws = New-Object -ComObject WScript.Shell
$desktop = $ws.SpecialFolders.Item('Desktop')
$lnkPath = Join-Path $desktop 'Genius Windows Toolkit.lnk'

$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = $target
$lnk.WorkingDirectory = $appDir
$lnk.Description = 'Genius Windows Toolkit — por Ricardo Valério S.'
if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
$lnk.Save()

Write-Host "Atalho criado na Área de Trabalho:" -ForegroundColor Green
Write-Host "  $lnkPath"
Write-Host "  -> $target"
