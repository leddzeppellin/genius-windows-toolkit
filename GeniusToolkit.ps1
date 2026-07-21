#requires -version 5.1
<#
.SYNOPSIS
  Genius Windows Toolkit — utilitário de bancada para pós-formatação do Windows.

.DESCRIPTION
  Interface WPF moderna (arquitetura inspirada no WinUtil do Chris Titus) para:
    • Migrar pastas conhecidas do usuário (Documentos, Imagens, etc.) para outra unidade
      com análise de espaço, cópia verificada via robocopy e backup automático;
    • Reparar rede e compartilhamento (NetBIOS, SMB, firewall, serviços) com backup .reg;
    • Instalar programas via winget com catálogo estilo Ninite;
    • Aplicar ajustes práticos do Windows;
    • Gerar diagnóstico da máquina;
    • Exportar/importar presets JSON para repetir o mesmo kit em várias máquinas.

  Todas as operações pesadas rodam em runspaces (a janela nunca congela) e o
  progresso real é exibido em tempo integral.

  Execução direta pelo GitHub (via carregador get.ps1, seguro contra o BOM):
    irm https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/get.ps1 | iex

  Com parâmetros:
    & ([scriptblock]::Create((irm URL_DO_GET))) -TargetDrive D: -Preset Extended -Config preset.json

.NOTES
  Autor: Ricardo Valério da Silva (leddzeppellin) + Claude
  Licença: MIT
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$TargetDrive,

    [ValidateSet('Core', 'Extended', 'All')]
    [string]$Preset = 'Core',

    [string]$Config,

    [string]$ScriptUrl,

    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ============================================================================
#region Estado compartilhado (UI <-> runspaces)
# ============================================================================

$sync = [hashtable]::Synchronized(@{})
$sync.Version      = '1.0.0'
$sync.AppName      = 'GeniusWindowsToolkit'
$sync.AppRoot      = Join-Path $env:LOCALAPPDATA $sync.AppName
$sync.BackupRoot   = Join-Path $sync.AppRoot 'backups'
$sync.LogRoot      = Join-Path $sync.AppRoot 'logs'
$sync.ReportRoot   = Join-Path $sync.AppRoot 'reports'
$sync.SessionStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sync.LogFile      = Join-Path $sync.LogRoot ("session-{0}.log" -f $sync.SessionStamp)
$sync.ScriptUrl    = if ($ScriptUrl) { $ScriptUrl } else { 'https://raw.githubusercontent.com/leddzeppellin/genius-windows-toolkit/main/get.ps1' }

$sync.LogQueue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$sync.PendingUi     = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$sync.Busy          = $false
$sync.ProgressValue = [double]0
$sync.ProgressMax   = [double]0
$sync.StatusText    = 'Pronto.'
$sync.Plan          = @()
$sync.PlanValid     = $false
$sync.PlanTotalBytes = [long]0
$sync.PlanTotalFiles = [long]0
$sync.PlanFreeBytes  = [long]0
$sync.PlanDrive      = ''
$sync.DiagReport     = ''
$sync.RunspacePool   = $null
$sync.Jobs           = [System.Collections.ArrayList]::new()
$sync.Controls       = @{}
$sync.Window         = $null

New-Item -ItemType Directory -Path $sync.BackupRoot, $sync.LogRoot, $sync.ReportRoot -Force | Out-Null

#endregion

# ============================================================================
#region Catálogos (pastas, rede, ajustes, programas)
# ============================================================================

$KnownFolders = @(
    [pscustomobject]@{ Key='Desktop';    Name='Área de Trabalho'; Icon='🖥️'; Guid='B4BFCC3A-DB2C-424C-B029-7FE99A87C641'; Relative='Desktop';     Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Documents';  Name='Documentos';       Icon='📄'; Guid='FDD39AD0-238F-46AF-ADB4-6C85480369C7'; Relative='Documents';   Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Downloads';  Name='Downloads';        Icon='⬇️'; Guid='374DE290-123F-4565-9164-39C4925E467B'; Relative='Downloads';   Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Pictures';   Name='Imagens';          Icon='🖼️'; Guid='33E28130-4E1E-4676-835A-98395C3BC3BB'; Relative='Pictures';    Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Music';      Name='Músicas';          Icon='🎵'; Guid='4BD8D571-6D19-48D3-BE97-422220080E43'; Relative='Music';       Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Videos';     Name='Vídeos';           Icon='🎬'; Guid='18989B1D-99B5-455B-841C-AB7C74E4DDFC'; Relative='Videos';      Presets=@('Core','Extended','All') }
    [pscustomobject]@{ Key='Favorites';  Name='Favoritos';        Icon='⭐'; Guid='1777F761-68AD-4D8A-87BD-30B759FA33DD'; Relative='Favorites';   Presets=@('Extended','All') }
    [pscustomobject]@{ Key='Links';      Name='Links';            Icon='🔗'; Guid='BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968'; Relative='Links';       Presets=@('Extended','All') }
    [pscustomobject]@{ Key='Contacts';   Name='Contatos';         Icon='👥'; Guid='56784854-C6CB-462B-8169-88E350ACB882'; Relative='Contacts';    Presets=@('All') }
    [pscustomobject]@{ Key='SavedGames'; Name='Jogos Salvos';     Icon='🎮'; Guid='4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4'; Relative='Saved Games'; Presets=@('All') }
    [pscustomobject]@{ Key='Searches';   Name='Pesquisas';        Icon='🔍'; Guid='7D1D3A04-DEBB-4115-95CF-2F29DA2920DA'; Relative='Searches';    Presets=@('All') }
)

# Aba Rede — funcionalidade integral preservada do BAT original de compartilhamento.
$NetworkActions = @(
    [pscustomobject]@{ Key='NetBios';    Name='Ativar NetBIOS sobre TCP/IP';               Risk='Compatibilidade'; Default=$true  }
    [pscustomobject]@{ Key='Smb1';       Name='Ativar SMB 1.0/CIFS';                       Risk='Alto';            Default=$false }
    [pscustomobject]@{ Key='SmbGuest';   Name='Permitir logon convidado inseguro SMB';     Risk='Alto';            Default=$true  }
    [pscustomobject]@{ Key='Private';    Name='Definir redes atuais como Particular';      Risk='Baixo';           Default=$true  }
    [pscustomobject]@{ Key='NoPassword'; Name='Ajustar compartilhamento sem senha (LSA)';  Risk='Médio';           Default=$true  }
    [pscustomobject]@{ Key='Firewall';   Name='Liberar descoberta e compartilhamento';     Risk='Baixo';           Default=$true  }
    [pscustomobject]@{ Key='Services';   Name='Serviços de compartilhamento automáticos';  Risk='Baixo';           Default=$true  }
    [pscustomobject]@{ Key='ResetStack'; Name='Limpar DNS e resetar pilha TCP/IP';         Risk='Requer reboot';   Default=$true  }
    [pscustomobject]@{ Key='Winsock';    Name='Resetar Winsock (netsh winsock reset)';     Risk='Requer reboot';   Default=$false }
)

$WindowsTweaks = @(
    [pscustomobject]@{ Key='ShowExtensions'; Name='Mostrar extensões de arquivos';                Scope='Usuário'; Default=$true  }
    [pscustomobject]@{ Key='ShowHidden';     Name='Mostrar arquivos ocultos';                     Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='Clipboard';      Name='Ativar histórico da área de transferência';    Scope='Usuário'; Default=$true  }
    [pscustomobject]@{ Key='ThisPc';         Name='Abrir Explorer em Este Computador';            Scope='Usuário'; Default=$true  }
    [pscustomobject]@{ Key='DarkMode';       Name='Ativar modo escuro do Windows';                Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='ClassicMenu';    Name='Menu de contexto clássico (Windows 11)';       Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='NoBingSearch';   Name='Desativar Bing na busca do menu Iniciar';      Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='TaskbarLeft';    Name='Alinhar barra de tarefas à esquerda (Win 11)'; Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='EndTask';        Name='Botão Finalizar tarefa na barra de tarefas';   Scope='Usuário'; Default=$false }
    [pscustomobject]@{ Key='FastStartup';    Name='Desativar inicialização rápida';               Scope='Sistema'; Default=$false }
)

# Catálogo winget curado — IDs validados, sem duplicatas nem pacotes mortos.
$Packages = @(
    [pscustomobject]@{ Category='Navegadores'; Name='Google Chrome'; Id='Google.Chrome'; Default=$true }
    [pscustomobject]@{ Category='Navegadores'; Name='Mozilla Firefox'; Id='Mozilla.Firefox'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Microsoft Edge'; Id='Microsoft.Edge'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Brave'; Id='Brave.Brave'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Opera'; Id='Opera.Opera'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Vivaldi'; Id='VivaldiTechnologies.Vivaldi'; Default=$false }

    [pscustomobject]@{ Category='Mensagens'; Name='WhatsApp'; Id='WhatsApp.WhatsApp'; Default=$false }
    [pscustomobject]@{ Category='Mensagens'; Name='Telegram Desktop'; Id='Telegram.TelegramDesktop'; Default=$false }
    [pscustomobject]@{ Category='Mensagens'; Name='Zoom'; Id='Zoom.Zoom'; Default=$false }
    [pscustomobject]@{ Category='Mensagens'; Name='Discord'; Id='Discord.Discord'; Default=$false }
    [pscustomobject]@{ Category='Mensagens'; Name='Microsoft Teams'; Id='Microsoft.Teams'; Default=$false }
    [pscustomobject]@{ Category='Mensagens'; Name='Thunderbird'; Id='Mozilla.Thunderbird'; Default=$false }

    [pscustomobject]@{ Category='Nuvem e Torrent'; Name='Google Drive'; Id='Google.GoogleDrive'; Default=$false }
    [pscustomobject]@{ Category='Nuvem e Torrent'; Name='Dropbox'; Id='Dropbox.Dropbox'; Default=$false }
    [pscustomobject]@{ Category='Nuvem e Torrent'; Name='OneDrive'; Id='Microsoft.OneDrive'; Default=$false }
    [pscustomobject]@{ Category='Nuvem e Torrent'; Name='qBittorrent'; Id='qBittorrent.qBittorrent'; Default=$false }

    [pscustomobject]@{ Category='Compactadores'; Name='7-Zip'; Id='7zip.7zip'; Default=$true }
    [pscustomobject]@{ Category='Compactadores'; Name='WinRAR'; Id='RARLab.WinRAR'; Default=$false }
    [pscustomobject]@{ Category='Compactadores'; Name='PeaZip'; Id='Giorgiotani.Peazip'; Default=$false }

    [pscustomobject]@{ Category='Mídia'; Name='VLC'; Id='VideoLAN.VLC'; Default=$true }
    [pscustomobject]@{ Category='Mídia'; Name='Spotify'; Id='Spotify.Spotify'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='K-Lite Codec Pack'; Id='CodecGuide.K-LiteCodecPack.Standard'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='Audacity'; Id='Audacity.Audacity'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='HandBrake'; Id='HandBrake.HandBrake'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='MusicBee'; Id='MusicBee.MusicBee'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='AIMP'; Id='AIMP.AIMP'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='foobar2000'; Id='PeterPawlowski.foobar2000'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='GOM Player'; Id='GOMLab.GOMPlayer'; Default=$false }
    [pscustomobject]@{ Category='Mídia'; Name='iTunes'; Id='Apple.iTunes'; Default=$false }

    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2015+ x64'; Id='Microsoft.VCRedist.2015+.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2015+ x86'; Id='Microsoft.VCRedist.2015+.x86'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2013 x64'; Id='Microsoft.VCRedist.2013.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2013 x86'; Id='Microsoft.VCRedist.2013.x86'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2012 x64'; Id='Microsoft.VCRedist.2012.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2012 x86'; Id='Microsoft.VCRedist.2012.x86'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2010 x64'; Id='Microsoft.VCRedist.2010.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2010 x86'; Id='Microsoft.VCRedist.2010.x86'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2008 x64'; Id='Microsoft.VCRedist.2008.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2008 x86'; Id='Microsoft.VCRedist.2008.x86'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2005 x64'; Id='Microsoft.VCRedist.2005.x64'; Default=$false }
    [pscustomobject]@{ Category='VC++ Redistributables'; Name='VC++ 2005 x86'; Id='Microsoft.VCRedist.2005.x86'; Default=$false }

    [pscustomobject]@{ Category='.NET Runtimes'; Name='.NET Desktop Runtime 8 x64'; Id='Microsoft.DotNet.DesktopRuntime.8'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='.NET Runtimes'; Name='.NET Desktop Runtime 9 x64'; Id='Microsoft.DotNet.DesktopRuntime.9'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='.NET Runtimes'; Name='.NET Desktop Runtime 10 x64'; Id='Microsoft.DotNet.DesktopRuntime.10'; Arch='x64'; Default=$false }

    [pscustomobject]@{ Category='Java'; Name='JRE Temurin 8 x64'; Id='EclipseAdoptium.Temurin.8.JRE'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='Java'; Name='JRE Temurin 11 x64'; Id='EclipseAdoptium.Temurin.11.JRE'; Arch='x64'; Default=$true }
    [pscustomobject]@{ Category='Java'; Name='JRE Temurin 17 x64'; Id='EclipseAdoptium.Temurin.17.JRE'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='Java'; Name='JRE Temurin 21 x64'; Id='EclipseAdoptium.Temurin.21.JRE'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='Java'; Name='JDK Temurin 11 x64'; Id='EclipseAdoptium.Temurin.11.JDK'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='Java'; Name='JDK Temurin 17 x64'; Id='EclipseAdoptium.Temurin.17.JDK'; Arch='x64'; Default=$false }
    [pscustomobject]@{ Category='Java'; Name='JDK Temurin 21 x64'; Id='EclipseAdoptium.Temurin.21.JDK'; Arch='x64'; Default=$false }

    [pscustomobject]@{ Category='Imagem e Design'; Name='GIMP'; Id='GIMP.GIMP'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='Paint.NET'; Id='dotPDN.PaintDotNet'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='IrfanView'; Id='IrfanSkiljan.IrfanView'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='Krita'; Id='KDE.Krita'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='Inkscape'; Id='Inkscape.Inkscape'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='Blender'; Id='BlenderFoundation.Blender'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='ShareX'; Id='ShareX.ShareX'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='Greenshot'; Id='Greenshot.Greenshot'; Default=$false }
    [pscustomobject]@{ Category='Imagem e Design'; Name='XnView Classic'; Id='XnSoft.XnView.Classic'; Default=$false }

    [pscustomobject]@{ Category='Utilitários'; Name='AnyDesk'; Id='AnyDeskSoftwareGmbH.AnyDesk'; Default=$true }
    [pscustomobject]@{ Category='Utilitários'; Name='TeamViewer'; Id='TeamViewer.TeamViewer'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='RustDesk'; Id='RustDesk.RustDesk'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='TeraCopy'; Id='CodeSector.TeraCopy'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='Everything'; Id='voidtools.Everything'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='Revo Uninstaller'; Id='RevoUninstaller.RevoUninstaller'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='WinDirStat'; Id='WinDirStat.WinDirStat'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='WizTree'; Id='AntibodySoftware.WizTree'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='CCleaner'; Id='Piriform.CCleaner'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='CPU-Z'; Id='CPUID.CPU-Z'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='HWiNFO'; Id='REALiX.HWiNFO'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='CrystalDiskInfo'; Id='CrystalDewWorld.CrystalDiskInfo'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='Open-Shell'; Id='Open-Shell.Open-Shell-Menu'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='KeePass 2'; Id='DominikReichl.KeePass'; Default=$false }
    [pscustomobject]@{ Category='Utilitários'; Name='NVDA (leitor de tela)'; Id='NVAccess.NVDA'; Default=$false }

    [pscustomobject]@{ Category='Documentos'; Name='Adobe Acrobat Reader'; Id='Adobe.Acrobat.Reader.64-bit'; Default=$false }
    [pscustomobject]@{ Category='Documentos'; Name='Foxit PDF Reader'; Id='Foxit.FoxitReader'; Default=$false }
    [pscustomobject]@{ Category='Documentos'; Name='SumatraPDF'; Id='SumatraPDF.SumatraPDF'; Default=$false }
    [pscustomobject]@{ Category='Documentos'; Name='LibreOffice'; Id='TheDocumentFoundation.LibreOffice'; Default=$false }
    [pscustomobject]@{ Category='Documentos'; Name='Apache OpenOffice'; Id='Apache.OpenOffice'; Default=$false }

    [pscustomobject]@{ Category='Segurança'; Name='Malwarebytes'; Id='Malwarebytes.Malwarebytes'; Default=$false }
    [pscustomobject]@{ Category='Segurança'; Name='AdwCleaner'; Id='Malwarebytes.AdwCleaner'; Default=$false }

    [pscustomobject]@{ Category='Jogos'; Name='Steam'; Id='Valve.Steam'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Epic Games Launcher'; Id='EpicGames.EpicGamesLauncher'; Default=$false }

    [pscustomobject]@{ Category='Desenvolvimento'; Name='Notepad++'; Id='Notepad++.Notepad++'; Default=$true }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Visual Studio Code'; Id='Microsoft.VisualStudioCode'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Git'; Id='Git.Git'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Python 3.13'; Id='Python.Python.3.13'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Node.js LTS'; Id='OpenJS.NodeJS.LTS'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='PowerShell 7'; Id='Microsoft.PowerShell'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Windows Terminal'; Id='Microsoft.WindowsTerminal'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='FileZilla'; Id='TimKosse.FileZilla.Client'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='WinSCP'; Id='WinSCP.WinSCP'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='PuTTY'; Id='PuTTY.PuTTY'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='WinMerge'; Id='WinMerge.WinMerge'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Cursor'; Id='Anysphere.Cursor'; Default=$false }
)

# Chave única de cada pacote (Id + arquitetura quando houver)
foreach ($pkg in $Packages) {
    $arch = if ($pkg.PSObject.Properties.Name -contains 'Arch') { $pkg.Arch } else { $null }
    $key = if ($arch) { "$($pkg.Id)#$arch" } else { $pkg.Id }
    Add-Member -InputObject $pkg -NotePropertyName Key -NotePropertyValue $key -Force
}

#endregion

# ============================================================================
#region Funções compartilhadas (prefixo Gwt = disponíveis nos runspaces)
# ============================================================================

function Add-GwtLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $prefix = switch ($Level) {
        'Success' { '[ OK ]' }
        'Warn'    { '[AVISO]' }
        'Error'   { '[ERRO ]' }
        default   { '[INFO ]' }
    }
    $line = "[{0:HH:mm:ss}] {1} {2}" -f (Get-Date), $prefix, $Message
    $sync.LogQueue.Enqueue($line)
}

function Request-GwtUi {
    param([hashtable]$Action)
    $sync.PendingUi.Enqueue($Action)
}

function Format-GwtBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Test-GwtAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-GwtNativeApi {
    if ('GwtNative.KnownFolders' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GwtNative {
    public static class KnownFolders {
        [DllImport("shell32.dll")]
        public static extern int SHGetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            out IntPtr ppszPath);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SHSetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            string pszPath);

        [DllImport("ole32.dll")]
        public static extern void CoTaskMemFree(IntPtr pv);
    }
}
'@
}

function Get-GwtKnownFolderPath {
    param([string]$Guid)

    Initialize-GwtNativeApi
    $ptr = [IntPtr]::Zero
    $result = [GwtNative.KnownFolders]::SHGetKnownFolderPath([Guid]$Guid, 0, [IntPtr]::Zero, [ref]$ptr)
    if ($result -ne 0) {
        throw ("Não foi possível ler a pasta conhecida {0}. HRESULT: 0x{1:X8}" -f $Guid, $result)
    }
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) { [GwtNative.KnownFolders]::CoTaskMemFree($ptr) }
    }
}

function Set-GwtKnownFolderPath {
    param([string]$Guid, [string]$Path)

    Initialize-GwtNativeApi
    $result = [GwtNative.KnownFolders]::SHSetKnownFolderPath([Guid]$Guid, 0, [IntPtr]::Zero, $Path)
    if ($result -ne 0) {
        throw ("Não foi possível definir '{0}'. HRESULT: 0x{1:X8}" -f $Path, $result)
    }
}

function Export-GwtRegistryKey {
    param([string]$Key, [string]$Destination)

    $output = & reg.exe export $Key $Destination /y 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-GwtLog "Backup de registro: $Destination" 'Success'
    }
    else {
        Add-GwtLog "Chave ausente ou não exportada: $Key" 'Warn'
        foreach ($line in $output) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) { Add-GwtLog $text 'Warn' }
        }
    }
}

function Backup-GwtRegistrySet {
    param([string]$Name, [string[]]$Keys)

    $folder = Join-Path $sync.BackupRoot ("{0}-{1}" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    foreach ($key in $Keys) {
        $safeName = ($key -replace '[\\/:*?"<>| ]', '_') + '.reg'
        Export-GwtRegistryKey -Key $key -Destination (Join-Path $folder $safeName)
    }
    return $folder
}

function Get-GwtFolderSize {
    param([string]$Path)

    $bytes = [long]0
    $files = [long]0
    if (-not [System.IO.Directory]::Exists($Path)) {
        return [pscustomobject]@{ Bytes = $bytes; Files = $files }
    }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $bytes += ([System.IO.FileInfo]::new($file)).Length
                    $files++
                }
                catch { }
            }
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $info = [System.IO.DirectoryInfo]::new($sub)
                    # Ignora junctions/links simbólicos (mesmo comportamento do robocopy /XJ)
                    if (-not ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        $stack.Push($sub)
                    }
                }
                catch { }
            }
        }
        catch { }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Invoke-GwtRobocopy {
    param([string]$Source, [string]$Destination)

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Add-GwtLog "Origem inexistente, pulando cópia: $Source" 'Warn'
        return 0
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $rcArgs = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ',
                '/R:1', '/W:1', '/BYTES', '/NJH', '/NJS', '/NDL', '/NC', '/NP')

    $fileCount = 0
    & robocopy.exe @rcArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line -match '^\s*(\d+)\s+\S') {
            # Uma linha por arquivo copiado: "<bytes>  <caminho>"
            $sync.ProgressValue = [double]$sync.ProgressValue + [double]$Matches[1]
            $fileCount++
            if (($fileCount % 200) -eq 0) {
                $sync.StatusText = "Copiando... $fileCount arquivos nesta pasta"
            }
        }
        elseif ($line -match 'ERROR|ERRO') {
            Add-GwtLog $line.Trim() 'Error'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            Add-GwtLog $line.Trim() 'Warn'
        }
    }
    return $LASTEXITCODE
}

function Test-GwtCopyComplete {
    param([string]$Source, [string]$Destination)

    # Robocopy em modo lista (/L): se nada seria copiado, origem e destino conferem.
    $rcArgs = @($Source, $Destination, '/E', '/L', '/XJ',
                '/R:0', '/W:0', '/BYTES', '/NJH', '/NJS', '/NDL', '/NC', '/NP')
    $pending = 0
    & robocopy.exe @rcArgs 2>&1 | ForEach-Object {
        if ([string]$_ -match '^\s*\d+\s+\S') { $pending++ }
    }
    return ($pending -eq 0)
}

function Save-GwtFolderBackup {
    param([object[]]$Plan, [string]$Drive)

    $folder = Join-Path $sync.BackupRoot ("folders-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $jsonPath = Join-Path $folder 'known-folders.json'

    [pscustomobject]@{
        CreatedAt    = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        UserProfile  = $env:USERPROFILE
        TargetDrive  = $Drive
        Folders      = $Plan
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    Export-GwtRegistryKey -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Destination (Join-Path $folder 'user-shell-folders.reg')
    Export-GwtRegistryKey -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -Destination (Join-Path $folder 'shell-folders.reg')
    return $folder
}

function Invoke-GwtNativeCommand {
    param([string]$FilePath, [string[]]$Arguments, [string]$Description)

    Add-GwtLog $Description
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($text)) { Add-GwtLog $text.Trim() }
    }
    if ($exitCode -ne 0) {
        Add-GwtLog "Código de saída: $exitCode" 'Warn'
    }
    return $exitCode
}

#endregion

# ============================================================================
#region Workers (executados em runspaces, nunca na thread da UI)
# ============================================================================

function Invoke-GwtAnalyzeWorker {
    param([object[]]$Folders, [string]$Drive)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Analisando pastas e calculando tamanhos...'
        Add-GwtLog "Analisando $($Folders.Count) pasta(s) para migração até $Drive ..."

        $userLeaf = Split-Path -Path $env:USERPROFILE -Leaf
        $targetRoot = Join-Path "$Drive\" ("Users\{0}" -f $userLeaf)
        $oneDriveRoot = $env:OneDrive

        $plan = New-Object System.Collections.Generic.List[object]
        $totalBytes = [long]0
        $totalFiles = [long]0

        foreach ($folder in $Folders) {
            $current = Get-GwtKnownFolderPath -Guid $folder.Guid
            $target = Join-Path $targetRoot $folder.Relative
            $samePath = (([System.IO.Path]::GetFullPath($current).TrimEnd('\')) -ieq ([System.IO.Path]::GetFullPath($target).TrimEnd('\')))
            $isOneDrive = (($current -like '*\OneDrive\*') -or (-not [string]::IsNullOrWhiteSpace($oneDriveRoot) -and $current -like "$oneDriveRoot*"))

            $sync.StatusText = "Medindo $($folder.Name)..."
            $size = if ($samePath) {
                [pscustomobject]@{ Bytes = [long]0; Files = [long]0 }
            } else {
                Get-GwtFolderSize -Path $current
            }

            if (-not $samePath) {
                $totalBytes += $size.Bytes
                $totalFiles += $size.Files
            }

            $status = if ($samePath) { 'Já está no destino' }
                      elseif (Test-Path -LiteralPath $target) { 'Destino já existe' }
                      else { 'Pronto para migrar' }

            $plan.Add([pscustomobject]@{
                Key         = $folder.Key
                Name        = "$($folder.Icon) $($folder.Name)"
                PlainName   = $folder.Name
                Guid        = $folder.Guid
                CurrentPath = $current
                TargetPath  = $target
                SizeBytes   = $size.Bytes
                SizeText    = Format-GwtBytes $size.Bytes
                Files       = $size.Files
                Status      = $status
                Warning     = if ($isOneDrive) { '⚠ OneDrive' } else { '' }
                SamePath    = $samePath
                OneDrive    = $isOneDrive
            })
            Add-GwtLog ("  {0}: {1} em {2:N0} arquivo(s)" -f $folder.Name, (Format-GwtBytes $size.Bytes), $size.Files)
        }

        $free = ([System.IO.DriveInfo]::new("$Drive\")).AvailableFreeSpace

        $sync.Plan = @($plan)
        $sync.PlanTotalBytes = $totalBytes
        $sync.PlanTotalFiles = $totalFiles
        $sync.PlanFreeBytes = $free
        $sync.PlanDrive = $Drive
        $sync.PlanValid = $true

        $enough = ($free -gt ($totalBytes * 1.05))
        $verdict = if ($enough) { 'espaço suficiente ✔' } else { 'ESPAÇO INSUFICIENTE ✖' }
        Add-GwtLog ("Análise concluída: {0} a migrar, livre em {1} {2} — {3}" -f (Format-GwtBytes $totalBytes), $Drive, (Format-GwtBytes $free), $verdict) $(if ($enough) { 'Success' } else { 'Error' })
        Request-GwtUi @{ Action = 'PlanReady' }
    }
    catch {
        Add-GwtLog "Falha na análise: $($_.Exception.Message)" 'Error'
        $sync.PlanValid = $false
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro na análise'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtMigrationWorker {
    param([object[]]$Plan, [string]$Drive, [bool]$CopyOnly, [bool]$RenameSource)

    try {
        $sync.Busy = $true
        $pending = @($Plan | Where-Object { -not $_.SamePath })
        $sync.ProgressMax = [double](@($pending | Measure-Object -Property SizeBytes -Sum).Sum)
        $sync.ProgressValue = [double]0

        Add-GwtLog '================ MIGRAÇÃO DE PASTAS ================'
        $backup = Save-GwtFolderBackup -Plan $Plan -Drive $Drive
        Add-GwtLog "Backup criado em: $backup" 'Success'

        $ok = 0
        $failed = 0
        foreach ($item in $pending) {
            $sync.StatusText = "Copiando $($item.PlainName)..."
            Add-GwtLog "▶ $($item.PlainName): $($item.CurrentPath) → $($item.TargetPath) ($($item.SizeText))"

            $code = Invoke-GwtRobocopy -Source $item.CurrentPath -Destination $item.TargetPath
            if ($code -ge 8) {
                Add-GwtLog "$($item.PlainName): robocopy retornou código $code — pasta NÃO será redirecionada." 'Error'
                $failed++
                continue
            }

            $sync.StatusText = "Verificando $($item.PlainName)..."
            $verified = Test-GwtCopyComplete -Source $item.CurrentPath -Destination $item.TargetPath
            if (-not $verified) {
                Add-GwtLog "$($item.PlainName): verificação encontrou diferenças entre origem e destino — atalho NÃO foi alterado. Revise e rode novamente." 'Error'
                $failed++
                continue
            }
            Add-GwtLog "$($item.PlainName): cópia verificada, origem e destino conferem." 'Success'

            if (-not $CopyOnly) {
                Set-GwtKnownFolderPath -Guid $item.Guid -Path $item.TargetPath
                Add-GwtLog "$($item.PlainName): atalho do Explorer atualizado para o novo local." 'Success'

                if ($RenameSource) {
                    try {
                        $stamp = Get-Date -Format 'yyyyMMdd'
                        $newName = (Split-Path -Leaf $item.CurrentPath) + "-old-$stamp"
                        Rename-Item -LiteralPath $item.CurrentPath -NewName $newName -ErrorAction Stop
                        Add-GwtLog "$($item.PlainName): origem renomeada para '$newName' (nada foi apagado)." 'Success'
                    }
                    catch {
                        Add-GwtLog "$($item.PlainName): não foi possível renomear a origem ($($_.Exception.Message)). Ela permanece intacta." 'Warn'
                    }
                }
            }
            else {
                Add-GwtLog "$($item.PlainName): conteúdo copiado; atalho mantido (modo cópia)." 'Success'
            }
            $ok++
        }

        Add-GwtLog "================ RESULTADO: $ok concluída(s), $failed com problema(s) ================" $(if ($failed -eq 0) { 'Success' } else { 'Warn' })

        if (-not $CopyOnly -and $ok -gt 0) {
            Request-GwtUi @{ Action = 'AskExplorerRestart' }
        }
        $kind = if ($failed -eq 0) { 'Info' } else { 'Warning' }
        Request-GwtUi @{ Action = 'Message'; Title = 'Migração concluída'; Kind = $kind
                         Text = "Pastas migradas: $ok`nCom problemas: $failed`n`nA origem não foi apagada. Backups em:`n$($sync.BackupRoot)" }
    }
    catch {
        Add-GwtLog "Falha na migração: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro na migração'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.ProgressValue = [double]0
        $sync.StatusText = 'Pronto.'
        $sync.PlanValid = $false
    }
}

function Invoke-GwtNetworkAction {
    param([string]$Key)

    switch ($Key) {
        'NetBios' {
            Add-GwtLog 'Ativando NetBIOS sobre TCP/IP...'
            $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and ($_.TcpipNetbiosOptions -eq 0 -or $_.TcpipNetbiosOptions -eq 2) })
            foreach ($config in $configs) {
                Invoke-CimMethod -InputObject $config -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = 1 } | Out-Null
            }
            Add-GwtLog "NetBIOS ajustado em $($configs.Count) adaptador(es)." 'Success'
        }
        'Smb1' {
            Add-GwtLog 'Ativando SMB 1.0/CIFS...'
            Enable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -All | Out-Null
            Add-GwtLog 'SMB 1.0/CIFS solicitado. Reinício pode ser necessário.' 'Success'
        }
        'SmbGuest' {
            Add-GwtLog 'Configurando SMB guest e assinatura...'
            Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force | Out-Null
            Set-SmbClientConfiguration -RequireSecuritySignature $false -Force | Out-Null
            Set-SmbServerConfiguration -RequireSecuritySignature $false -Force | Out-Null
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Force | Out-Null
            New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name 'AllowInsecureGuestLogon' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'SMB guest inseguro habilitado.' 'Success'
        }
        'Private' {
            Add-GwtLog 'Definindo perfis de rede como Particular...'
            Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
            Add-GwtLog 'Perfis de rede ajustados para Particular.' 'Success'
        }
        'NoPassword' {
            Add-GwtLog 'Ajustando compartilhamento sem senha (chaves LSA)...'
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'everyoneincludesanonymous' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'restrictanonymous' -PropertyType DWord -Value 0 -Force | Out-Null
            New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Force | Out-Null
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'auth0' -PropertyType DWord -Value 0 -Force | Out-Null
            Add-GwtLog 'Chaves LSA ajustadas.' 'Success'
        }
        'Firewall' {
            Add-GwtLog 'Habilitando regras de firewall para descoberta e compartilhamento...'
            # Grupos por identificador (independente do idioma do Windows)
            try {
                Set-NetFirewallRule -Group '@FirewallAPI.dll,-32752' -Enabled True -ErrorAction Stop   # Descoberta de Rede
                Set-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Enabled True -ErrorAction Stop   # Compartilhamento de Arquivo e Impressora
                Add-GwtLog 'Regras de firewall habilitadas (grupos nativos).' 'Success'
            }
            catch {
                Add-GwtLog "Cmdlet de firewall falhou ($($_.Exception.Message)); usando netsh como alternativa..." 'Warn'
                Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('advfirewall','firewall','set','rule','group=Descoberta de Rede','new','enable=Yes') -Description 'Firewall: Descoberta de Rede' | Out-Null
                Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('advfirewall','firewall','set','rule','group=Compartilhamento de Arquivo e Impressora','new','enable=Yes') -Description 'Firewall: Compartilhamento de Arquivo e Impressora' | Out-Null
                Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('advfirewall','firewall','set','rule','group=Network Discovery','new','enable=Yes') -Description 'Firewall: Network Discovery (fallback)' | Out-Null
                Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('advfirewall','firewall','set','rule','group=File and Printer Sharing','new','enable=Yes') -Description 'Firewall: File and Printer Sharing (fallback)' | Out-Null
            }
        }
        'Services' {
            Add-GwtLog 'Configurando serviços de compartilhamento para Automático...'
            foreach ($svc in 'LanmanWorkstation', 'LanmanServer', 'fdPHost', 'FDResPub') {
                Invoke-GwtNativeCommand -FilePath 'sc.exe' -Arguments @('config', $svc, 'start=', 'auto') -Description "Serviço $svc → Automático" | Out-Null
                try { Start-Service -Name $svc -ErrorAction Stop } catch { Add-GwtLog "Serviço $svc não pôde ser iniciado agora: $($_.Exception.Message)" 'Warn' }
            }
            Add-GwtLog 'Serviços ajustados.' 'Success'
        }
        'ResetStack' {
            Add-GwtLog 'Limpando DNS e resetando pilha TCP/IP...'
            Invoke-GwtNativeCommand -FilePath 'ipconfig.exe' -Arguments @('/flushdns') -Description 'Flush DNS' | Out-Null
            Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('int', 'ip', 'reset') -Description 'Reset TCP/IP' | Out-Null
            Add-GwtLog 'Reset de TCP/IP concluído. Reinício recomendado.' 'Success'
        }
        'Winsock' {
            Add-GwtLog 'Resetando catálogo Winsock...'
            Invoke-GwtNativeCommand -FilePath 'netsh.exe' -Arguments @('winsock', 'reset') -Description 'Reset Winsock' | Out-Null
            Add-GwtLog 'Winsock resetado. Reinício recomendado.' 'Success'
        }
    }
}

function Invoke-GwtNetworkWorker {
    param([string[]]$Keys)

    try {
        $sync.Busy = $true
        $sync.StatusText = 'Executando rotina de rede...'
        Add-GwtLog '================ REPARO DE REDE ================'

        $backupKeys = @(
            'HKLM\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation',
            'HKLM\SYSTEM\CurrentControlSet\Control\Lsa',
            'HKLM\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0',
            'HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation',
            'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer',
            'HKLM\SYSTEM\CurrentControlSet\Services\fdPHost',
            'HKLM\SYSTEM\CurrentControlSet\Services\FDResPub',
            'HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters'
        )
        $backup = Backup-GwtRegistrySet -Name 'network' -Keys $backupKeys
        Add-GwtLog "Backup de registro de rede criado em: $backup" 'Success'

        $failed = 0
        foreach ($key in $Keys) {
            try {
                Invoke-GwtNetworkAction -Key $key
            }
            catch {
                $failed++
                Add-GwtLog "Ação '$key' falhou: $($_.Exception.Message)" 'Error'
            }
        }

        Add-GwtLog "Rotina de rede concluída ($($Keys.Count - $failed) ok, $failed falha(s))." $(if ($failed -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'AskReboot' }
    }
    catch {
        Add-GwtLog "Falha no reparo de rede: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro de rede'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtWingetWorker {
    param([object[]]$Selected)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]$Selected.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ INSTALAÇÃO VIA WINGET ($($Selected.Count) pacote(s)) ================"

        $okList = New-Object System.Collections.Generic.List[string]
        $failList = New-Object System.Collections.Generic.List[string]
        $index = 0

        foreach ($pkg in $Selected) {
            $index++
            $sync.StatusText = "Instalando $($pkg.Name) ($index de $($Selected.Count))..."
            Add-GwtLog "▶ [$index/$($Selected.Count)] $($pkg.Name) ($($pkg.Id))"

            $wgArgs = @('install', '--id', [string]$pkg.Id, '-e', '--silent',
                        '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            if ($pkg.PSObject.Properties.Name -contains 'Arch' -and -not [string]::IsNullOrWhiteSpace([string]$pkg.Arch)) {
                $wgArgs += @('--architecture', [string]$pkg.Arch)
            }

            & winget.exe @wgArgs 2>&1 | ForEach-Object {
                $line = ([string]$_).Trim()
                if ($line -and $line.Length -le 220 -and $line -notmatch '^[\s\-\\|/█▒░]+$') {
                    Add-GwtLog "    $line"
                }
            }
            $code = $LASTEXITCODE

            if ($code -eq 0) {
                $okList.Add($pkg.Name)
                Add-GwtLog "$($pkg.Name): instalado." 'Success'
            }
            else {
                $failList.Add("$($pkg.Name) (0x$('{0:X8}' -f $code))")
                Add-GwtLog "$($pkg.Name): falhou com código 0x$('{0:X8}' -f $code)." 'Error'
            }
            $sync.ProgressValue = [double]$index
        }

        Add-GwtLog "================ RESULTADO: $($okList.Count) ok, $($failList.Count) falha(s) ================" $(if ($failList.Count -eq 0) { 'Success' } else { 'Warn' })
        $summary = "Instalados: $($okList.Count)`nFalharam: $($failList.Count)"
        if ($failList.Count -gt 0) { $summary += "`n`nFalhas:`n" + (($failList | Select-Object -First 12) -join "`n") }
        Request-GwtUi @{ Action = 'Message'; Title = 'Instalação concluída'; Text = $summary; Kind = $(if ($failList.Count -eq 0) { 'Info' } else { 'Warning' }) }
    }
    catch {
        Add-GwtLog "Falha na instalação: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro no winget'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtWingetUpgradeWorker {
    try {
        $sync.Busy = $true
        $sync.StatusText = 'Atualizando todos os programas (winget upgrade --all)...'
        Add-GwtLog '================ WINGET UPGRADE --ALL ================'

        & winget.exe upgrade --all --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | ForEach-Object {
            $line = ([string]$_).Trim()
            if ($line -and $line.Length -le 220 -and $line -notmatch '^[\s\-\\|/█▒░]+$') {
                Add-GwtLog "    $line"
            }
        }
        Add-GwtLog "winget upgrade concluído (código $LASTEXITCODE)." 'Success'
    }
    catch {
        Add-GwtLog "Falha no upgrade: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtTweak {
    param([string]$Key)

    switch ($Key) {
        'ShowExtensions' {
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -PropertyType DWord -Value 0 -Force | Out-Null
            Add-GwtLog 'Extensões de arquivos visíveis.' 'Success'
        }
        'ShowHidden' {
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'Arquivos ocultos visíveis.' 'Success'
        }
        'Clipboard' {
            New-Item -Path 'HKCU:\Software\Microsoft\Clipboard' -Force | Out-Null
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'EnableClipboardHistory' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'Histórico da área de transferência ativado (Win+V).' 'Success'
        }
        'ThisPc' {
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'Explorer abrirá em Este Computador.' 'Success'
        }
        'DarkMode' {
            $themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            New-Item -Path $themePath -Force | Out-Null
            New-ItemProperty -Path $themePath -Name 'AppsUseLightTheme' -PropertyType DWord -Value 0 -Force | Out-Null
            New-ItemProperty -Path $themePath -Name 'SystemUsesLightTheme' -PropertyType DWord -Value 0 -Force | Out-Null
            Add-GwtLog 'Modo escuro ativado.' 'Success'
        }
        'ClassicMenu' {
            $clsid = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            New-Item -Path $clsid -Force | Out-Null
            Set-ItemProperty -Path $clsid -Name '(Default)' -Value '' | Out-Null
            Add-GwtLog 'Menu de contexto clássico habilitado (Windows 11).' 'Success'
        }
        'NoBingSearch' {
            $polPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
            New-Item -Path $polPath -Force | Out-Null
            New-ItemProperty -Path $polPath -Name 'DisableSearchBoxSuggestions' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'Bing removido da busca do menu Iniciar.' 'Success'
        }
        'TaskbarLeft' {
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -PropertyType DWord -Value 0 -Force | Out-Null
            Add-GwtLog 'Barra de tarefas alinhada à esquerda.' 'Success'
        }
        'EndTask' {
            $devPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
            New-Item -Path $devPath -Force | Out-Null
            New-ItemProperty -Path $devPath -Name 'TaskbarEndTask' -PropertyType DWord -Value 1 -Force | Out-Null
            Add-GwtLog 'Botão Finalizar tarefa habilitado.' 'Success'
        }
        'FastStartup' {
            if (-not (Test-GwtAdmin)) { throw 'Desativar inicialização rápida exige Administrador.' }
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
            Add-GwtLog 'Inicialização rápida desativada.' 'Success'
        }
    }
}

function Invoke-GwtTweaksWorker {
    param([string[]]$Keys)

    try {
        $sync.Busy = $true
        $sync.StatusText = 'Aplicando ajustes do Windows...'
        Add-GwtLog '================ AJUSTES DO WINDOWS ================'

        $backupKeys = @(
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
            'HKCU\Software\Microsoft\Clipboard',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            'HKCU\Software\Policies\Microsoft\Windows\Explorer',
            'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        )
        $backup = Backup-GwtRegistrySet -Name 'tweaks' -Keys $backupKeys
        Add-GwtLog "Backup de ajustes criado em: $backup" 'Success'

        $failed = 0
        foreach ($key in $Keys) {
            try { Invoke-GwtTweak -Key $key }
            catch {
                $failed++
                Add-GwtLog "Ajuste '$key' falhou: $($_.Exception.Message)" 'Error'
            }
        }

        Add-GwtLog "Ajustes concluídos ($($Keys.Count - $failed) ok, $failed falha(s))." $(if ($failed -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'AskExplorerRestart' }
    }
    catch {
        Add-GwtLog "Falha nos ajustes: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtDiagnosticWorker {
    try {
        $sync.Busy = $true
        $sync.StatusText = 'Gerando diagnóstico...'
        Add-GwtLog 'Gerando diagnóstico da máquina...'

        $computer = Get-CimInstance Win32_ComputerSystem
        $os = Get-CimInstance Win32_OperatingSystem
        $bios = Get-CimInstance Win32_BIOS
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $volumes = @(Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name)
        $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('Genius Windows Toolkit — Diagnóstico')
        $lines.Add(('Gerado em: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)))
        $lines.Add('')
        $lines.Add('SISTEMA')
        $lines.Add("  Computador: $env:COMPUTERNAME")
        $lines.Add("  Usuário: $env:USERNAME")
        $lines.Add("  Fabricante: $($computer.Manufacturer)")
        $lines.Add("  Modelo: $($computer.Model)")
        $lines.Add("  Windows: $($os.Caption) $($os.Version) (build $($os.BuildNumber))")
        $lines.Add("  Nº de série BIOS: $($bios.SerialNumber)")
        $lines.Add("  CPU: $($cpu.Name)")
        $lines.Add(('  RAM: {0:N1} GB' -f ($computer.TotalPhysicalMemory / 1GB)))
        $lines.Add("  Administrador: $(Test-GwtAdmin)")
        $lines.Add('')
        $lines.Add('VOLUMES')
        foreach ($v in $volumes) {
            $size = if ($v.Size) { $v.Size / 1GB } else { 0 }
            $free = if ($v.SizeRemaining) { $v.SizeRemaining / 1GB } else { 0 }
            $lines.Add(('  {0}:  {1}  {2:N1} GB livres de {3:N1} GB  ({4})' -f $v.DriveLetter, $v.FileSystemLabel, $free, $size, $v.FileSystem))
        }
        $lines.Add('')
        $lines.Add('PASTAS CONHECIDAS DO PERFIL ATUAL')
        Initialize-GwtNativeApi
        foreach ($kf in @(
            @{ N='Área de Trabalho'; G='B4BFCC3A-DB2C-424C-B029-7FE99A87C641' },
            @{ N='Documentos';       G='FDD39AD0-238F-46AF-ADB4-6C85480369C7' },
            @{ N='Downloads';        G='374DE290-123F-4565-9164-39C4925E467B' },
            @{ N='Imagens';          G='33E28130-4E1E-4676-835A-98395C3BC3BB' },
            @{ N='Músicas';          G='4BD8D571-6D19-48D3-BE97-422220080E43' },
            @{ N='Vídeos';           G='18989B1D-99B5-455B-841C-AB7C74E4DDFC' }
        )) {
            try { $lines.Add(("  {0}: {1}" -f $kf.N, (Get-GwtKnownFolderPath -Guid $kf.G))) } catch { }
        }
        $lines.Add('')
        $lines.Add('REDE')
        foreach ($adapter in $adapters) {
            $lines.Add("  $($adapter.Name): $($adapter.Status)  $($adapter.LinkSpeed)")
        }
        foreach ($netProfile in $profiles) {
            $lines.Add("  Perfil '$($netProfile.Name)': $($netProfile.NetworkCategory)")
        }
        $lines.Add('')
        $lines.Add("Log da sessão: $($sync.LogFile)")

        $text = ($lines -join [Environment]::NewLine)
        $reportFile = Join-Path $sync.ReportRoot ("diagnostico-{0}.txt" -f $sync.SessionStamp)
        Set-Content -LiteralPath $reportFile -Value $text -Encoding UTF8

        $sync.DiagReport = $text
        Add-GwtLog "Diagnóstico salvo em: $reportFile" 'Success'
        Request-GwtUi @{ Action = 'DiagReady' }
    }
    catch {
        Add-GwtLog "Falha no diagnóstico: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

#endregion

# ============================================================================
#region Infraestrutura de runspaces (padrão WinUtil)
# ============================================================================

function Initialize-GwtRunspacePool {
    if ($sync.RunspacePool -and $sync.RunspacePool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.RunspacePool
    }

    $maxThreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 2)
    $syncVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $initialState.Variables.Add($syncVar)

    foreach ($function in (Get-ChildItem function:\ | Where-Object { $_.Name -match 'Gwt' })) {
        $definition = Get-Content "function:\$($function.Name)"
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $definition
        $initialState.Commands.Add($entry)
    }

    $sync.RunspacePool = [runspacefactory]::CreateRunspacePool(1, $maxThreads, $initialState, $Host)
    $sync.RunspacePool.Open()
    return $sync.RunspacePool
}

function Invoke-GwtRunspace {
    param([scriptblock]$ScriptBlock, [object]$Argument)

    Initialize-GwtRunspacePool | Out-Null
    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock)
    if ($null -ne $Argument) { [void]$ps.AddArgument($Argument) }
    $ps.RunspacePool = $sync.RunspacePool
    $handle = $ps.BeginInvoke()
    [void]$sync.Jobs.Add(@{ PowerShell = $ps; Handle = $handle })
}

#endregion

# ============================================================================
#region XAML — interface
# ============================================================================

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genius Windows Toolkit"
        Width="1340" Height="850"
        MinWidth="1120" MinHeight="720"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="CanResize"
        Background="#14161B"
        FontFamily="Segoe UI"
        FontSize="13">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>

    <Window.Resources>
        <SolidColorBrush x:Key="BgBrush" Color="#14161B"/>
        <SolidColorBrush x:Key="PanelBrush" Color="#1C2027"/>
        <SolidColorBrush x:Key="SoftBrush" Color="#252B36"/>
        <SolidColorBrush x:Key="LineBrush" Color="#313947"/>
        <SolidColorBrush x:Key="TextBrush" Color="#F2F5F9"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#9AA5B4"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#6C63FF"/>
        <SolidColorBrush x:Key="AccentSoftBrush" Color="#2B2952"/>
        <SolidColorBrush x:Key="GoldBrush" Color="#F6AE2D"/>
        <SolidColorBrush x:Key="GreenBrush" Color="#34D399"/>
        <SolidColorBrush x:Key="RedBrush" Color="#F87171"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>

        <Style TargetType="Button">
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Padding" Value="16,9"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource SoftBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
        </Style>

        <Style x:Key="GoldButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource GoldBrush}"/>
            <Setter Property="Foreground" Value="#181305"/>
        </Style>

        <Style x:Key="TitleButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="Width" Value="42"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Margin" Value="2,0,0,0"/>
            <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Margin" Value="0,5,0,5"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="TabControl">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="bd" CornerRadius="10" Margin="0,0,8,10" Padding="16,9" Background="{StaticResource PanelBrush}">
                            <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" Value="True"/>
                                    <Condition Property="IsSelected" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource SoftBrush}"/>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DriveCard" TargetType="RadioButton">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="bd" CornerRadius="10" BorderThickness="2" BorderBrush="{StaticResource LineBrush}"
                                Background="{StaticResource SoftBrush}" Padding="12,10">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource AccentSoftBrush}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="16"/>
        </Style>

        <Style x:Key="Console" TargetType="TextBox">
            <Setter Property="Background" Value="#0C0E12"/>
            <Setter Property="Foreground" Value="#D7E0E8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="TextWrapping" Value="NoWrap"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource SoftBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="RowBackground" Value="{StaticResource PanelBrush}"/>
            <Setter Property="AlternatingRowBackground" Value="{StaticResource SoftBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="RowHeight" Value="30"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{StaticResource SoftBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{StaticResource AccentSoftBrush}"/>
                    <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="ProgressBar">
            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Background" Value="{StaticResource SoftBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="10"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="46"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Barra de título -->
        <Grid Grid.Row="0" Background="{StaticResource BgBrush}">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
                <TextBlock Text="🧞" FontSize="20" VerticalAlignment="Center"/>
                <TextBlock Text="Genius Windows Toolkit" FontSize="15" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                <TextBlock Name="TitleVersionText" Text="v0.0.0" FontSize="12" Foreground="{StaticResource MutedBrush}" Margin="10,2,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0">
                <Button Name="MinButton" Style="{StaticResource TitleButton}" Content="—"/>
                <Button Name="MaxButton" Style="{StaticResource TitleButton}" Content="▢"/>
                <Button Name="CloseButton" Style="{StaticResource TitleButton}" Content="✕"/>
            </StackPanel>
        </Grid>

        <!-- Corpo -->
        <Grid Grid.Row="1" Margin="18,6,18,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="270"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Sidebar -->
            <Border Grid.Column="0" Style="{StaticResource Card}">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0">
                        <TextBlock Text="Ferramenta de bancada" Foreground="{StaticResource GoldBrush}" FontWeight="SemiBold" FontSize="12"/>
                        <TextBlock Text="Pós-formatação sem dor" FontSize="21" FontWeight="Bold" Margin="0,2,0,6" TextWrapping="Wrap"/>
                        <TextBlock Text="Migração de pastas, rede, programas, ajustes e diagnóstico — tudo com backup e log." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="19"/>
                    </StackPanel>

                    <Border Grid.Row="1" Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="12" Margin="0,16,0,0">
                        <StackPanel>
                            <TextBlock Text="Sessão" FontWeight="Bold" Margin="0,0,0,6"/>
                            <TextBlock Name="AdminText" Text="Administrador: ..." Foreground="{StaticResource MutedBrush}" Margin="0,0,0,3"/>
                            <TextBlock Name="ProfileText" Text="Perfil: ..." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>

                    <StackPanel Grid.Row="2" Margin="0,16,0,0">
                        <TextBlock Text="Atalhos" FontWeight="Bold" Margin="0,0,0,10"/>
                        <Button Name="ElevateButton" Content="🛡️  Abrir como Administrador" HorizontalContentAlignment="Left" Margin="0,0,0,8"/>
                        <Button Name="ExportPresetButton" Style="{StaticResource GhostButton}" Content="📤  Exportar preset" Margin="0,0,0,8"/>
                        <Button Name="ImportPresetButton" Style="{StaticResource GhostButton}" Content="📥  Importar preset" Margin="0,0,0,8"/>
                        <Button Name="OpenBackupsButton" Style="{StaticResource GhostButton}" Content="🗂️  Abrir backups" Margin="0,0,0,8"/>
                        <Button Name="OpenLogsButton" Style="{StaticResource GhostButton}" Content="📜  Abrir logs" Margin="0,0,0,8"/>
                        <Button Name="RestoreRegButton" Style="{StaticResource GhostButton}" Content="♻️  Restaurar backup .reg" Margin="0,0,0,8"/>
                    </StackPanel>

                    <TextBlock Grid.Row="3" Text="Ações sensíveis sempre pedem confirmação e criam backup antes de alterar o registro." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="18" FontSize="12"/>
                </Grid>
            </Border>

            <!-- Área principal -->
            <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="140"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TabControl Name="MainTabs" Grid.Row="0">
                    <TabItem Header="📁  Pastas">
                        <Grid Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="300"/>
                                <ColumnDefinition Width="14"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <TextBlock Grid.Row="0" Text="Unidade de destino" FontSize="16" FontWeight="Bold"/>
                                    <ScrollViewer Grid.Row="1" MaxHeight="170" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
                                        <StackPanel Name="DrivePanel"/>
                                    </ScrollViewer>

                                    <TextBlock Grid.Row="2" Text="Pastas do perfil" FontSize="16" FontWeight="Bold" Margin="0,12,0,6"/>
                                    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto">
                                        <StackPanel Name="FolderList"/>
                                    </ScrollViewer>

                                    <CheckBox Grid.Row="4" Name="RenameSourceCheck" Margin="0,10,0,4"
                                              Content="Renomear origem após verificação"
                                              ToolTip="Depois da cópia verificada, renomeia a pasta original para NOME-old-DATA. Nada é apagado."/>

                                    <StackPanel Grid.Row="5" Margin="0,10,0,0">
                                        <Button Name="AnalyzeButton" Content="🔎  Analisar (tamanhos e espaço)" Margin="0,0,0,8"/>
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <Button Grid.Column="0" Name="CopyOnlyButton" Style="{StaticResource GhostButton}" Content="Copiar apenas"/>
                                            <Button Grid.Column="1" Name="MigrateButton" Style="{StaticResource GoldButton}" Content="🚀  Migrar" Margin="0"/>
                                        </Grid>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border Grid.Column="2" Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,10">
                                        <TextBlock Text="Prévia da migração" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Name="FolderSummaryText" Text="Selecione a unidade e as pastas, depois clique em Analisar." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                    </StackPanel>
                                    <DataGrid Name="PlanGrid" Grid.Row="1">
                                        <DataGrid.Columns>
                                            <DataGridTextColumn Header="Pasta" Binding="{Binding Name}" Width="150"/>
                                            <DataGridTextColumn Header="Tamanho" Binding="{Binding SizeText}" Width="90"/>
                                            <DataGridTextColumn Header="Atual" Binding="{Binding CurrentPath}" Width="*"/>
                                            <DataGridTextColumn Header="Destino" Binding="{Binding TargetPath}" Width="*"/>
                                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="130"/>
                                            <DataGridTextColumn Header="Aviso" Binding="{Binding Warning}" Width="95"/>
                                        </DataGrid.Columns>
                                    </DataGrid>
                                </Grid>
                            </Border>
                        </Grid>
                    </TabItem>

                    <TabItem Header="🌐  Rede">
                        <Grid Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="430"/>
                                <ColumnDefinition Width="14"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0">
                                        <TextBlock Text="Reparo de rede e compartilhamento" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Rotina completa do BAT original, com confirmação, log e backup .reg antes das mudanças." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,12"/>
                                    </StackPanel>
                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                        <StackPanel Name="NetworkList"/>
                                    </ScrollViewer>
                                    <StackPanel Grid.Row="2" Margin="0,14,0,0">
                                        <Button Name="NetworkRunButton" Style="{StaticResource GoldButton}" Content="⚡  Executar selecionados" Margin="0,0,0,10"/>
                                        <TextBlock Text="SMB1 e convidado inseguro são opções de compatibilidade para redes legadas (NAS, DVR, impressoras antigas). Use com critério." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="18" FontSize="12"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border Grid.Column="2" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="O que esta rotina pode alterar" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="22"><Run Text="1. NetBIOS sobre TCP/IP nos adaptadores ativos."/><LineBreak/><Run Text="2. Recurso opcional SMB 1.0/CIFS, se marcado."/><LineBreak/><Run Text="3. Configurações SMB client/server e LanmanWorkstation."/><LineBreak/><Run Text="4. Perfil de rede como Particular."/><LineBreak/><Run Text="5. Chaves LSA usadas por compartilhamento sem senha."/><LineBreak/><Run Text="6. Regras de firewall para descoberta e compartilhamento (por grupo nativo, independente do idioma)."/><LineBreak/><Run Text="7. Serviços LanmanWorkstation, LanmanServer, fdPHost e FDResPub."/><LineBreak/><Run Text="8. Flush DNS, reset TCP/IP e, se marcado, reset Winsock."/></TextBlock>
                                    <Border Background="#2D2113" BorderBrush="{StaticResource GoldBrush}" BorderThickness="1" CornerRadius="10" Padding="14" Margin="0,18,0,0">
                                        <TextBlock Text="Antes de executar, o utilitário exporta as chaves HKLM relacionadas para a pasta de backups. Ainda assim, essas opções reduzem a segurança para ganhar compatibilidade com equipamentos antigos. Cada ação roda isolada: se uma falhar, as demais continuam." Foreground="#FFE7B0" TextWrapping="Wrap" LineHeight="20"/>
                                    </Border>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </TabItem>

                    <TabItem Header="📦  Programas">
                        <Grid Margin="0,4,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border Grid.Row="0" Style="{StaticResource Card}" Padding="12" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBox Grid.Column="0" Name="PackageSearchBox" FontSize="13" VerticalContentAlignment="Center" Margin="0,0,12,0" ToolTip="Filtrar programas pelo nome"/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Button Name="PackageDefaultButton" Style="{StaticResource GhostButton}" Content="⭐ Kit básico"/>
                                        <Button Name="PackageAllButton" Style="{StaticResource GhostButton}" Content="Tudo"/>
                                        <Button Name="PackageNoneButton" Style="{StaticResource GhostButton}" Content="Limpar" Margin="0"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <Border Grid.Row="1" Style="{StaticResource Card}">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <WrapPanel Name="PackageList" Orientation="Vertical" ItemHeight="30" MaxHeight="99999"/>
                                </ScrollViewer>
                            </Border>

                            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
                                <Button Name="WingetInstallButton" Style="{StaticResource GoldButton}" Content="📦  Instalar selecionados"/>
                                <Button Name="WingetUpgradeButton" Style="{StaticResource GhostButton}" Content="⬆️  Atualizar tudo (winget upgrade)"/>
                                <TextBlock Name="PackageCountText" Text="" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="8,0,0,0"/>
                            </StackPanel>
                        </Grid>
                    </TabItem>

                    <TabItem Header="⚙️  Ajustes">
                        <Grid Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="430"/>
                                <ColumnDefinition Width="14"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Style="{StaticResource Card}">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0">
                                        <TextBlock Text="Ajustes práticos" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Pequenos ajustes comuns de pós-formatação, com backup .reg antes de aplicar." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,12"/>
                                    </StackPanel>
                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                        <StackPanel Name="TweaksList"/>
                                    </ScrollViewer>
                                    <Button Grid.Row="2" Name="TweaksApplyButton" Style="{StaticResource GoldButton}" Content="✨  Aplicar ajustes" Margin="0,14,0,0"/>
                                </Grid>
                            </Border>
                            <Border Grid.Column="2" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="Escopo" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Text="Ajustes de usuário não exigem Administrador. Ajustes de sistema, como inicialização rápida, exigem. Todos os itens marcados geram backup .reg antes da aplicação, e o Explorer é reiniciado ao final para refletir as mudanças." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="22"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </TabItem>

                    <TabItem Header="🩺  Diagnóstico">
                        <Grid Margin="0,4,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource Card}" Padding="14" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Diagnóstico da máquina" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Windows, hardware, volumes, pastas do perfil, adaptadores e perfis de rede. Salvo em relatórios." Foreground="{StaticResource MutedBrush}"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Button Name="DiagRunButton" Style="{StaticResource GoldButton}" Content="🩺  Gerar diagnóstico"/>
                                        <Button Name="OpenReportsButton" Style="{StaticResource GhostButton}" Content="Abrir relatórios" Margin="0"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                            <Border Grid.Row="1" Style="{StaticResource Card}" Padding="8">
                                <TextBox Name="DiagnosticText" Style="{StaticResource Console}"/>
                            </Border>
                        </Grid>
                    </TabItem>
                </TabControl>

                <!-- Console de log -->
                <Border Grid.Row="1" Style="{StaticResource Card}" Padding="8" Margin="0,12,0,0">
                    <TextBox Name="LogBox" Style="{StaticResource Console}"/>
                </Border>

                <!-- Barra de status -->
                <Grid Grid.Row="2" Margin="0,10,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="280"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Name="StatusText" Text="Pronto." Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center"/>
                    <TextBlock Name="ProgressText" Grid.Column="1" Text="" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <ProgressBar Name="Progress" Grid.Column="2" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"/>
                </Grid>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

#endregion

# ============================================================================
#region Construção da janela e vínculo de controles
# ============================================================================

$reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)
$sync.Window = $Window

$Xaml.SelectNodes('//*[@Name]') | ForEach-Object {
    $sync.Controls[$_.Name] = $Window.FindName($_.Name)
}

$sync.Controls['TitleVersionText'].Text = "v$($sync.Version)"
$sync.Controls['AdminText'].Text = "Administrador: $(if (Test-GwtAdmin) { 'Sim ✔' } else { 'Não' })"
$sync.Controls['ProfileText'].Text = "Perfil: $env:USERPROFILE"

function Invalidate-Plan {
    $sync.PlanValid = $false
    if ($sync.Controls.ContainsKey('FolderSummaryText')) {
        $sync.Controls['FolderSummaryText'].Text = 'Seleção alterada — clique em Analisar antes de migrar.'
    }
}

# --- Cartões de unidades ---
function Update-DriveCards {
    $panel = $sync.Controls['DrivePanel']
    $panel.Children.Clear()
    $currentDrive = ([System.IO.Path]::GetPathRoot($env:USERPROFILE)).TrimEnd('\')
    $selected = $null

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | Sort-Object Name)) {
        $letter = "$($drive.Name):"
        $freeGb = if ($null -ne $drive.Free) { '{0:N0} GB livres' -f ($drive.Free / 1GB) } else { '?' }
        $suffix = if ($letter -eq $currentDrive) { '  •  unidade do perfil atual' } else { '' }

        $card = New-Object System.Windows.Controls.RadioButton
        $card.Style = $Window.Resources['DriveCard']
        $card.GroupName = 'Drives'
        $card.Tag = $letter
        $card.Content = "💽  $letter   $freeGb$suffix"
        $card.Add_Checked({ Invalidate-Plan })
        [void]$panel.Children.Add($card)

        if ($TargetDrive -and $letter -eq $TargetDrive.ToUpperInvariant()) { $selected = $card }
        elseif (-not $TargetDrive -and -not $selected -and $letter -ne $currentDrive) { $selected = $card }
    }
    if (-not $selected -and $panel.Children.Count -gt 0) { $selected = $panel.Children[0] }
    if ($selected) { $selected.IsChecked = $true }
}

function Get-SelectedDrive {
    foreach ($child in $sync.Controls['DrivePanel'].Children) {
        if ($child.IsChecked) { return [string]$child.Tag }
    }
    return $null
}

Update-DriveCards

# --- Pastas conhecidas ---
foreach ($folder in $KnownFolders) {
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = "$($folder.Icon)  $($folder.Name)"
    $check.Tag = $folder.Key
    $check.IsChecked = ($folder.Presets -contains $Preset)
    $check.Add_Checked({ Invalidate-Plan })
    $check.Add_Unchecked({ Invalidate-Plan })
    [void]$sync.Controls['FolderList'].Children.Add($check)
}

function Get-SelectedFolderDefs {
    $keys = @()
    foreach ($child in $sync.Controls['FolderList'].Children) {
        if ($child.IsChecked) { $keys += [string]$child.Tag }
    }
    return @($KnownFolders | Where-Object { $keys -contains $_.Key })
}

# --- Ações de rede ---
foreach ($action in $NetworkActions) {
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = "$($action.Name)   [$($action.Risk)]"
    $check.Tag = $action.Key
    $check.IsChecked = [bool]$action.Default
    [void]$sync.Controls['NetworkList'].Children.Add($check)
}

# --- Ajustes ---
foreach ($tweak in $WindowsTweaks) {
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = "$($tweak.Name)   [$($tweak.Scope)]"
    $check.Tag = $tweak.Key
    $check.IsChecked = [bool]$tweak.Default
    [void]$sync.Controls['TweaksList'].Children.Add($check)
}

function Get-CheckedKeys {
    param([System.Windows.Controls.Panel]$Panel)
    $keys = @()
    foreach ($child in $Panel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
            $keys += [string]$child.Tag
        }
    }
    return $keys
}

# --- Programas ---
$lastCategory = $null
foreach ($pkg in $Packages) {
    if ($pkg.Category -ne $lastCategory) {
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $pkg.Category
        $label.FontWeight = 'Bold'
        $label.FontSize = 13
        $label.Margin = '0,8,24,4'
        $label.Foreground = $Window.Resources['GoldBrush']
        [void]$sync.Controls['PackageList'].Children.Add($label)
        $lastCategory = $pkg.Category
    }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $pkg.Name
    $check.Tag = $pkg
    $check.ToolTip = "$($pkg.Id)"
    $check.IsChecked = [bool]$pkg.Default
    $check.Margin = '0,2,24,2'
    $check.Add_Checked({ Update-PackageCount })
    $check.Add_Unchecked({ Update-PackageCount })
    [void]$sync.Controls['PackageList'].Children.Add($check)
}

function Get-SelectedPackages {
    $selected = @()
    foreach ($child in $sync.Controls['PackageList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
            $selected += $child.Tag
        }
    }
    return @($selected)
}

function Update-PackageCount {
    $count = (Get-SelectedPackages).Count
    $sync.Controls['PackageCountText'].Text = "$count selecionado(s)"
}
Update-PackageCount

function Set-PackageSelection {
    param([ValidateSet('Default', 'All', 'None')][string]$Mode)
    foreach ($child in $sync.Controls['PackageList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            switch ($Mode) {
                'All'     { $child.IsChecked = $true }
                'None'    { $child.IsChecked = $false }
                'Default' { $child.IsChecked = [bool]$child.Tag.Default }
            }
        }
    }
    Update-PackageCount
}

function Update-PackageFilter {
    $filter = $sync.Controls['PackageSearchBox'].Text
    foreach ($child in $sync.Controls['PackageList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $match = [string]::IsNullOrWhiteSpace($filter) -or
                     $child.Tag.Name -like "*$filter*" -or
                     $child.Tag.Id -like "*$filter*" -or
                     $child.Tag.Category -like "*$filter*"
            $child.Visibility = if ($match) { 'Visible' } else { 'Collapsed' }
        }
    }
}

#endregion

# ============================================================================
#region Presets (exportar / importar / aplicar)
# ============================================================================

function Get-CurrentSelectionPreset {
    [pscustomobject]@{
        Version     = 1
        Tool        = 'GeniusWindowsToolkit'
        SavedAt     = (Get-Date).ToString('o')
        TargetDrive = Get-SelectedDrive
        Folders     = @((Get-SelectedFolderDefs).Key)
        Network     = @(Get-CheckedKeys -Panel $sync.Controls['NetworkList'])
        Tweaks      = @(Get-CheckedKeys -Panel $sync.Controls['TweaksList'])
        Packages    = @((Get-SelectedPackages).Key)
    }
}

function Apply-PresetObject {
    param($PresetData)

    if ($PresetData.PSObject.Properties.Name -contains 'TargetDrive' -and $PresetData.TargetDrive) {
        foreach ($child in $sync.Controls['DrivePanel'].Children) {
            if ([string]$child.Tag -eq [string]$PresetData.TargetDrive) { $child.IsChecked = $true }
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Folders') {
        foreach ($child in $sync.Controls['FolderList'].Children) {
            $child.IsChecked = (@($PresetData.Folders) -contains [string]$child.Tag)
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Network') {
        foreach ($child in $sync.Controls['NetworkList'].Children) {
            $child.IsChecked = (@($PresetData.Network) -contains [string]$child.Tag)
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Tweaks') {
        foreach ($child in $sync.Controls['TweaksList'].Children) {
            $child.IsChecked = (@($PresetData.Tweaks) -contains [string]$child.Tag)
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Packages') {
        foreach ($child in $sync.Controls['PackageList'].Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) {
                $child.IsChecked = (@($PresetData.Packages) -contains [string]$child.Tag.Key)
            }
        }
        Update-PackageCount
    }
    Invalidate-Plan
    Add-GwtLog 'Preset aplicado às seleções.' 'Success'
}

function Import-PresetFrom {
    param([string]$Source)
    $json = if ($Source -match '^https?://') {
        (Invoke-RestMethod -Uri $Source)
    } else {
        Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json
    }
    if ($json -is [string]) { $json = $json | ConvertFrom-Json }
    Apply-PresetObject -PresetData $json
}

#endregion

# ============================================================================
#region Handlers de eventos
# ============================================================================

$sync.Controls['MinButton'].Add_Click({ $Window.WindowState = 'Minimized' })
$sync.Controls['MaxButton'].Add_Click({
    $Window.WindowState = if ($Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
})
$sync.Controls['CloseButton'].Add_Click({ $Window.Close() })

$sync.Controls['AnalyzeButton'].Add_Click({
    if ($sync.Busy) { return }
    $drive = Get-SelectedDrive
    if (-not $drive) {
        [System.Windows.MessageBox]::Show($Window, 'Escolha a unidade de destino.', 'Unidade', 'OK', 'Warning') | Out-Null
        return
    }
    $folders = Get-SelectedFolderDefs
    if (-not $folders) {
        [System.Windows.MessageBox]::Show($Window, 'Selecione pelo menos uma pasta.', 'Pastas', 'OK', 'Warning') | Out-Null
        return
    }
    Invoke-GwtRunspace -ScriptBlock {
        param($state)
        Invoke-GwtAnalyzeWorker -Folders $state.Folders -Drive $state.Drive
    } -Argument @{ Folders = $folders; Drive = $drive }
})

function Start-Migration {
    param([bool]$CopyOnly)

    if ($sync.Busy) { return }
    if (-not $sync.PlanValid) {
        [System.Windows.MessageBox]::Show($Window, 'Clique em Analisar primeiro — a análise mede os tamanhos e confere o espaço livre no destino.', 'Análise necessária', 'OK', 'Warning') | Out-Null
        return
    }

    $pending = @($sync.Plan | Where-Object { -not $_.SamePath })
    if (-not $pending) {
        [System.Windows.MessageBox]::Show($Window, 'Todas as pastas selecionadas já apontam para o destino. Nada a fazer.', 'Nada a migrar', 'OK', 'Information') | Out-Null
        return
    }

    # Trava de segurança: espaço em disco
    $needed = [double]$sync.PlanTotalBytes * 1.05
    if ($sync.PlanFreeBytes -lt $needed) {
        $msg = "Espaço insuficiente em $($sync.PlanDrive)`n`nNecessário (com folga de 5%): $(Format-GwtBytes $needed)`nDisponível: $(Format-GwtBytes $sync.PlanFreeBytes)`n`nLibere espaço ou reduza a seleção de pastas."
        [System.Windows.MessageBox]::Show($Window, $msg, 'Espaço insuficiente', 'OK', 'Error') | Out-Null
        return
    }

    # Trava de segurança: sessão elevada pode pertencer a outro usuário
    if (Test-GwtAdmin) {
        $msg = "Esta janela está ELEVADA como '$env:USERNAME'.`n`nAs pastas alteradas serão as do perfil:`n$env:USERPROFILE`n`nSe a intenção era migrar o perfil de OUTRO usuário (ex.: técnico logado com conta admin), cancele e rode o toolkit na sessão do próprio usuário, sem elevação.`n`nContinuar mesmo assim?"
        if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confira o perfil', 'YesNo', 'Warning') -ne 'Yes') { return }
    }

    $oneDrive = @($pending | Where-Object { $_.OneDrive })
    $renameSource = [bool]$sync.Controls['RenameSourceCheck'].IsChecked
    $actionText = if ($CopyOnly) { 'copiar o conteúdo SEM alterar os atalhos' } else { 'copiar, verificar e atualizar os atalhos do Explorer' }
    $msg = "O utilitário vai $actionText.`n`nPastas: $($pending.Count)`nTotal: $(Format-GwtBytes $sync.PlanTotalBytes) em $('{0:N0}' -f $sync.PlanTotalFiles) arquivos`nDestino: $($sync.PlanDrive)`nRenomear origem após verificação: $(if ($renameSource -and -not $CopyOnly) { 'Sim' } else { 'Não' })"
    if ($oneDrive) { $msg += "`n`n⚠ Atenção: $($oneDrive.Count) pasta(s) estão sob OneDrive — revise antes." }
    $msg += "`n`nSerá criado backup antes. A origem NUNCA é apagada.`n`nContinuar?"
    if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confirmar migração', 'YesNo', 'Warning') -ne 'Yes') {
        Add-GwtLog 'Migração cancelada pelo usuário.' 'Warn'
        return
    }

    Invoke-GwtRunspace -ScriptBlock {
        param($state)
        Invoke-GwtMigrationWorker -Plan $state.Plan -Drive $state.Drive -CopyOnly $state.CopyOnly -RenameSource $state.RenameSource
    } -Argument @{ Plan = $sync.Plan; Drive = $sync.PlanDrive; CopyOnly = $CopyOnly; RenameSource = ($renameSource -and -not $CopyOnly) }
}

$sync.Controls['MigrateButton'].Add_Click({ Start-Migration -CopyOnly $false })
$sync.Controls['CopyOnlyButton'].Add_Click({ Start-Migration -CopyOnly $true })

$sync.Controls['NetworkRunButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'As ações de rede precisam de PowerShell como Administrador. Use o botão "Abrir como Administrador" na barra lateral.', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        Add-GwtLog 'Rede: execução bloqueada porque a sessão não é Administrador.' 'Warn'
        return
    }
    $selected = Get-CheckedKeys -Panel $sync.Controls['NetworkList']
    if (-not $selected) {
        Add-GwtLog 'Nenhuma ação de rede selecionada.' 'Warn'
        return
    }
    $msg = "Esta rotina pode habilitar SMB1, logon convidado inseguro e compartilhamento sem senha.`n`nUse apenas em redes confiáveis/legadas e revise as opções marcadas ($($selected.Count) ação(ões)).`n`nUm backup .reg será criado antes.`n`nContinuar?"
    if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confirmar reparo de rede', 'YesNo', 'Warning') -ne 'Yes') {
        Add-GwtLog 'Reparo de rede cancelado pelo usuário.' 'Warn'
        return
    }
    Invoke-GwtRunspace -ScriptBlock {
        param($keys)
        Invoke-GwtNetworkWorker -Keys $keys
    } -Argument $selected
})

$sync.Controls['WingetInstallButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'winget não foi encontrado. Instale/atualize o "Instalador de Aplicativo" pela Microsoft Store e tente novamente.', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    $selected = Get-SelectedPackages
    if (-not $selected) {
        Add-GwtLog 'Nenhum programa selecionado.' 'Warn'
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, "Instalar $($selected.Count) programa(s) via winget?", 'Confirmar instalação', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($packages)
        Invoke-GwtWingetWorker -Selected $packages
    } -Argument $selected
})

$sync.Controls['WingetUpgradeButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'winget não foi encontrado nesta máquina.', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, 'Atualizar todos os programas instalados via winget upgrade --all?', 'Atualizar tudo', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtWingetUpgradeWorker }
})

$sync.Controls['PackageDefaultButton'].Add_Click({ Set-PackageSelection -Mode Default })
$sync.Controls['PackageAllButton'].Add_Click({ Set-PackageSelection -Mode All })
$sync.Controls['PackageNoneButton'].Add_Click({ Set-PackageSelection -Mode None })
$sync.Controls['PackageSearchBox'].Add_TextChanged({ Update-PackageFilter })

$sync.Controls['TweaksApplyButton'].Add_Click({
    if ($sync.Busy) { return }
    $selected = Get-CheckedKeys -Panel $sync.Controls['TweaksList']
    if (-not $selected) {
        Add-GwtLog 'Nenhum ajuste selecionado.' 'Warn'
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, "Aplicar $($selected.Count) ajuste(s)? Um backup .reg será criado antes.", 'Confirmar ajustes', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($keys)
        Invoke-GwtTweaksWorker -Keys $keys
    } -Argument $selected
})

$sync.Controls['DiagRunButton'].Add_Click({
    if ($sync.Busy) { return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtDiagnosticWorker }
})

$sync.Controls['ExportPresetButton'].Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = 'Salvar preset'
        $dialog.FileName = "genius-preset-$env:COMPUTERNAME.json"
        $dialog.Filter = 'Preset JSON (*.json)|*.json'
        if ($dialog.ShowDialog($Window) -ne $true) { return }

        Get-CurrentSelectionPreset | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8
        $command = "& ([scriptblock]::Create((irm $($sync.ScriptUrl)))) -Config '$($dialog.FileName)'"
        try { Set-Clipboard -Value $command } catch { }
        Add-GwtLog "Preset salvo em $($dialog.FileName). Comando de uso copiado para a área de transferência." 'Success'
        [System.Windows.MessageBox]::Show($Window, "Preset salvo!`n`nO comando para reaplicá-lo em outra máquina foi copiado para a área de transferência:`n`n$command", 'Preset exportado', 'OK', 'Information') | Out-Null
    }
    catch {
        Add-GwtLog "Falha ao exportar preset: $($_.Exception.Message)" 'Error'
    }
})

$sync.Controls['ImportPresetButton'].Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = 'Abrir preset'
        $dialog.Filter = 'Preset JSON (*.json)|*.json|Todos (*.*)|*.*'
        if ($dialog.ShowDialog($Window) -ne $true) { return }
        Import-PresetFrom -Source $dialog.FileName
    }
    catch {
        Add-GwtLog "Falha ao importar preset: $($_.Exception.Message)" 'Error'
        [System.Windows.MessageBox]::Show($Window, $_.Exception.Message, 'Erro no preset', 'OK', 'Error') | Out-Null
    }
})

$sync.Controls['RestoreRegButton'].Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = 'Escolha um arquivo .reg de backup'
        $dialog.InitialDirectory = $sync.BackupRoot
        $dialog.Filter = 'Arquivos de Registro (*.reg)|*.reg|Todos (*.*)|*.*'
        if ($dialog.ShowDialog($Window) -ne $true) { return }
        $msg = "Importar este backup de registro?`n`n$($dialog.FileName)"
        if ([System.Windows.MessageBox]::Show($Window, $msg, 'Restaurar registro', 'YesNo', 'Warning') -ne 'Yes') { return }
        $null = & reg.exe import $dialog.FileName 2>&1
        if ($LASTEXITCODE -eq 0) { Add-GwtLog "Backup importado: $($dialog.FileName)" 'Success' }
        else { Add-GwtLog "reg import retornou código $LASTEXITCODE" 'Error' }
    }
    catch {
        Add-GwtLog "Falha ao restaurar: $($_.Exception.Message)" 'Error'
    }
})

$sync.Controls['ElevateButton'].Add_Click({
    try {
        if (Test-GwtAdmin) {
            [System.Windows.MessageBox]::Show($Window, 'Esta janela já está como Administrador.', 'Administrador', 'OK', 'Information') | Out-Null
            return
        }
        $drive = Get-SelectedDrive
        $extra = ''
        if ($drive) { $extra += " -TargetDrive $drive" }
        if ($Preset) { $extra += " -Preset $Preset" }

        if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "& '$PSCommandPath'$extra -ScriptUrl '$($sync.ScriptUrl)'")
        }
        else {
            $cmd = "& ([scriptblock]::Create((irm '$($sync.ScriptUrl)')))$extra -ScriptUrl '$($sync.ScriptUrl)'"
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
        }
        Add-GwtLog 'Solicitada nova janela como Administrador (unidade e preset preservados).' 'Success'
    }
    catch {
        Add-GwtLog "Elevação cancelada ou falhou: $($_.Exception.Message)" 'Warn'
    }
})

$sync.Controls['OpenBackupsButton'].Add_Click({ Start-Process explorer.exe $sync.BackupRoot })
$sync.Controls['OpenLogsButton'].Add_Click({ Start-Process explorer.exe $sync.LogRoot })
$sync.Controls['OpenReportsButton'].Add_Click({ Start-Process explorer.exe $sync.ReportRoot })

#endregion

# ============================================================================
#region Timer da UI (drena log, progresso e ações pendentes dos runspaces)
# ============================================================================

$script:DialogOpen = $false

function Invoke-PendingUiAction {
    param($UiAction)

    switch ($UiAction.Action) {
        'PlanReady' {
            $sync.Controls['PlanGrid'].ItemsSource = @($sync.Plan)
            $pending = @($sync.Plan | Where-Object { -not $_.SamePath })
            $warnings = @($sync.Plan | Where-Object { $_.OneDrive }).Count
            $enough = ($sync.PlanFreeBytes -gt ($sync.PlanTotalBytes * 1.05))
            $verdict = if ($enough) { '✔ espaço OK' } else { '✖ ESPAÇO INSUFICIENTE' }
            $sync.Controls['FolderSummaryText'].Text = "$($pending.Count) pasta(s) a migrar • $(Format-GwtBytes $sync.PlanTotalBytes) em $('{0:N0}' -f $sync.PlanTotalFiles) arquivos • Livre em $($sync.PlanDrive) $(Format-GwtBytes $sync.PlanFreeBytes) • $verdict" + $(if ($warnings) { " • ⚠ $warnings sob OneDrive" } else { '' })
        }
        'Message' {
            $script:DialogOpen = $true
            try {
                $icon = switch ($UiAction.Kind) { 'Error' { 'Error' } 'Warning' { 'Warning' } default { 'Information' } }
                [System.Windows.MessageBox]::Show($Window, $UiAction.Text, $UiAction.Title, 'OK', $icon) | Out-Null
            }
            finally { $script:DialogOpen = $false }
        }
        'AskExplorerRestart' {
            $script:DialogOpen = $true
            try {
                if ([System.Windows.MessageBox]::Show($Window, 'Reiniciar o Explorer agora para aplicar as mudanças?', 'Reiniciar Explorer', 'YesNo', 'Question') -eq 'Yes') {
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 600
                    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
                    Add-GwtLog 'Explorer reiniciado.' 'Success'
                }
            }
            finally { $script:DialogOpen = $false }
        }
        'AskReboot' {
            $script:DialogOpen = $true
            try {
                if ([System.Windows.MessageBox]::Show($Window, 'Rotina de rede concluída. Reiniciar o computador agora? (recomendado)', 'Reinício recomendado', 'YesNo', 'Question') -eq 'Yes') {
                    Start-Process shutdown.exe -ArgumentList '/r', '/t', '10', '/c', 'Reiniciando para aplicar configurações do Genius Windows Toolkit'
                }
            }
            finally { $script:DialogOpen = $false }
        }
        'DiagReady' {
            $sync.Controls['DiagnosticText'].Text = $sync.DiagReport
            $sync.Controls['MainTabs'].SelectedIndex = 4
        }
    }
}

$ActionButtons = @('AnalyzeButton', 'MigrateButton', 'CopyOnlyButton', 'NetworkRunButton',
                   'WingetInstallButton', 'WingetUpgradeButton', 'TweaksApplyButton', 'DiagRunButton')

$UiTimer = New-Object System.Windows.Threading.DispatcherTimer
$UiTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$UiTimer.Add_Tick({
    # 1. Drena o log
    $line = $null
    $batch = New-Object System.Collections.Generic.List[string]
    while ($sync.LogQueue.TryDequeue([ref]$line)) { $batch.Add($line) }
    if ($batch.Count -gt 0) {
        $logBox = $sync.Controls['LogBox']
        $logBox.AppendText(($batch -join "`r`n") + "`r`n")
        if ($logBox.Text.Length -gt 500000) { $logBox.Text = $logBox.Text.Substring(250000) }
        $logBox.ScrollToEnd()
        try { Add-Content -LiteralPath $sync.LogFile -Value $batch -Encoding UTF8 } catch { }
    }

    # 2. Status e progresso
    $sync.Controls['StatusText'].Text = [string]$sync.StatusText
    $progress = $sync.Controls['Progress']
    if ([double]$sync.ProgressMax -gt 0) {
        $progress.IsIndeterminate = $false
        $progress.Maximum = [double]$sync.ProgressMax
        $progress.Value = [Math]::Min([double]$sync.ProgressValue, [double]$sync.ProgressMax)
        $pct = [Math]::Min(100, [Math]::Round(([double]$sync.ProgressValue / [double]$sync.ProgressMax) * 100))
        $sync.Controls['ProgressText'].Text = "$pct%"
    }
    else {
        $progress.IsIndeterminate = [bool]$sync.Busy
        $sync.Controls['ProgressText'].Text = ''
        if (-not $sync.Busy) { $progress.Value = 0 }
    }

    # 3. Habilita/desabilita botões de ação
    foreach ($name in $ActionButtons) {
        $sync.Controls[$name].IsEnabled = -not [bool]$sync.Busy
    }

    # 4. Processa uma ação de UI pendente por tick (evita diálogos empilhados)
    if (-not $script:DialogOpen) {
        $uiAction = $null
        if ($sync.PendingUi.TryDequeue([ref]$uiAction)) {
            Invoke-PendingUiAction -UiAction $uiAction
        }
    }
})

$Window.Add_Closed({
    $UiTimer.Stop()
    # Descarrega o restante do log para o arquivo
    $line = $null
    $rest = New-Object System.Collections.Generic.List[string]
    while ($sync.LogQueue.TryDequeue([ref]$line)) { $rest.Add($line) }
    if ($rest.Count -gt 0) {
        try { Add-Content -LiteralPath $sync.LogFile -Value $rest -Encoding UTF8 } catch { }
    }
    foreach ($job in $sync.Jobs) {
        try { $job.PowerShell.Dispose() } catch { }
    }
    if ($sync.RunspacePool) {
        try { $sync.RunspacePool.Close(); $sync.RunspacePool.Dispose() } catch { }
    }
})

#endregion

# ============================================================================
#region Inicialização
# ============================================================================

Add-GwtLog "Genius Windows Toolkit v$($sync.Version) carregado. Log da sessão: $($sync.LogFile)" 'Success'
Add-GwtLog "Perfil: $env:USERPROFILE • Administrador: $(Test-GwtAdmin)"
if (-not (Test-GwtAdmin)) {
    Add-GwtLog 'Migração de pastas e ajustes de usuário funcionam sem Administrador. A aba Rede exige elevação.' 'Info'
}

if ($Config) {
    try {
        Import-PresetFrom -Source $Config
        Add-GwtLog "Preset carregado de: $Config" 'Success'
    }
    catch {
        Add-GwtLog "Falha ao carregar preset '$Config': $($_.Exception.Message)" 'Error'
    }
}

if ($SmokeTest) {
    $issues = @()
    foreach ($name in @('MainTabs', 'DrivePanel', 'FolderList', 'NetworkList', 'PackageList', 'TweaksList', 'LogBox', 'Progress', 'StatusText') + $ActionButtons) {
        if (-not $sync.Controls.ContainsKey($name) -or $null -eq $sync.Controls[$name]) { $issues += $name }
    }
    if ($issues) {
        Write-Host "SMOKETEST FALHOU — controles ausentes: $($issues -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host ("SMOKETEST OK — janela construída, {0} controles, {1} pacotes, {2} pastas, {3} ações de rede, {4} ajustes." -f `
        $sync.Controls.Count, $Packages.Count, $KnownFolders.Count, $NetworkActions.Count, $WindowsTweaks.Count) -ForegroundColor Green
    exit 0
}

$UiTimer.Start()
[void]$Window.ShowDialog()

#endregion
