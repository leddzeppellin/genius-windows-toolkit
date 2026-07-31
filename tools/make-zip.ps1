# Monta o pacote portátil (GeniusToolkit-portable.zip) para uso offline no pendrive.
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$staging = Join-Path $env:TEMP ("gwt_pkg_" + [guid]::NewGuid().ToString('N').Substring(0,8))
$dest = Join-Path $root 'GeniusToolkit-portable.zip'

New-Item -ItemType Directory -Path $staging -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $staging 'presets') -Force | Out-Null

Copy-Item (Join-Path $root 'GeniusToolkit.ps1')        $staging
Copy-Item (Join-Path $root 'get.ps1')                  $staging
Copy-Item (Join-Path $root 'Genius-Toolkit.bat')        $staging
Copy-Item (Join-Path $root 'Genius-Toolkit-Admin.bat')  $staging
Copy-Item (Join-Path $root 'Criar-Atalho-Desktop.bat')  $staging
New-Item -ItemType Directory -Path (Join-Path $staging 'tools') -Force | Out-Null
Copy-Item (Join-Path $root 'tools\New-DesktopShortcut.ps1') (Join-Path $staging 'tools')
Copy-Item (Join-Path $root 'README.md')                $staging
Copy-Item (Join-Path $root 'LICENSE')                  $staging
Copy-Item (Join-Path $root 'presets\*.json')           (Join-Path $staging 'presets')

$assets = Join-Path $root 'assets'
if (Test-Path $assets) {
    New-Item -ItemType Directory -Path (Join-Path $staging 'assets') -Force | Out-Null
    Copy-Item (Join-Path $assets '*') (Join-Path $staging 'assets') -Recurse
}

# extras/ (Monitor de Internet) — permite instalar offline, do pendrive
$extras = Join-Path $root 'extras'
if (Test-Path $extras) {
    New-Item -ItemType Directory -Path (Join-Path $staging 'extras') -Force | Out-Null
    Copy-Item (Join-Path $extras '*') (Join-Path $staging 'extras') -Recurse
}

if (Test-Path $dest) { Remove-Item $dest -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $dest -Force
Remove-Item $staging -Recurse -Force

$sizeKb = [math]::Round((Get-Item $dest).Length / 1KB, 1)
Write-Host "Pacote gerado: $dest ($sizeKb KB)"
