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

# Logo da marca (PNG em base64). Preenchido por tools\embed-logo.ps1 a partir de
# assets\genius-info-logo.png — mantém a execução via "irm | iex" autossuficiente.
$LogoBase64 = ''

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
$sync.OpData         = @{}   # dados de registro/serviço/ação por chave (acessível nos runspaces)

# Estado da aba Criar ISO (MicroWin)
$sync.IsoPath        = $null
$sync.IsoMountLetter = $null
$sync.IsoWimPath     = $null
$sync.IsoEditions    = @()
$sync.IsoWorkDir     = $null
$sync.IsoContentsDir = $null
$sync.IsoReady       = $false   # install.wim já modificado, pronto para exportar
$sync.IsoUsbDisks    = @()
$sync.KitUpdates     = @()      # apps do kit com atualização disponível
$sync.KitDir         = $null

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

# Preferências (aba Ajustes) — cada item aplica um valor benéfico; dados em $sync.OpData.
$Preferences = @(
    [pscustomobject]@{ Key='ShowExtensions';    Name='Mostrar extensões de arquivos';               Cat='Explorador';        Default=$true  }
    [pscustomobject]@{ Key='ShowHidden';        Name='Mostrar arquivos ocultos';                    Cat='Explorador';        Default=$false }
    [pscustomobject]@{ Key='ThisPc';            Name='Abrir Explorer em "Este Computador"';         Cat='Explorador';        Default=$true  }
    [pscustomobject]@{ Key='ClassicMenu';       Name='Menu de contexto clássico (Windows 11)';      Cat='Explorador';        Default=$false }
    [pscustomobject]@{ Key='Clipboard';         Name='Histórico da área de transferência (Win+V)';  Cat='Sistema';           Default=$true  }
    [pscustomobject]@{ Key='DarkMode';          Name='Modo escuro do Windows';                      Cat='Aparência';         Default=$false }
    [pscustomobject]@{ Key='Scrollbars';        Name='Barras de rolagem sempre visíveis';           Cat='Aparência';         Default=$false }
    [pscustomobject]@{ Key='TaskbarLeft';       Name='Barra de tarefas à esquerda (Win 11)';        Cat='Barra de tarefas';  Default=$false }
    [pscustomobject]@{ Key='HideTaskView';      Name='Ocultar botão "Visão de tarefas"';            Cat='Barra de tarefas';  Default=$false }
    [pscustomobject]@{ Key='HideSearchBox';     Name='Ocultar caixa de busca da barra';             Cat='Barra de tarefas';  Default=$false }
    [pscustomobject]@{ Key='EndTask';           Name='Botão "Finalizar tarefa" na barra';           Cat='Barra de tarefas';  Default=$false }
    [pscustomobject]@{ Key='BatteryPercentage'; Name='Porcentagem da bateria na bandeja';           Cat='Barra de tarefas';  Default=$false }
    [pscustomobject]@{ Key='NoBingSearch';      Name='Remover Bing da busca do Iniciar';            Cat='Iniciar e busca';   Default=$false }
    [pscustomobject]@{ Key='StartNoRecommend';  Name='Ocultar "Recomendados" do Iniciar';           Cat='Iniciar e busca';   Default=$false }
    [pscustomobject]@{ Key='VerboseLogon';      Name='Mensagens detalhadas no logon';               Cat='Sistema';           Default=$false }
    [pscustomobject]@{ Key='DetailedBSoD';      Name='Tela azul (BSoD) detalhada';                  Cat='Sistema';           Default=$false }
    [pscustomobject]@{ Key='LongPaths';         Name='Permitir caminhos longos (>260 caracteres)';  Cat='Sistema';           Default=$false }
    [pscustomobject]@{ Key='DisableLockscreen'; Name='Pular tela de bloqueio';                      Cat='Sistema';           Default=$false }
    [pscustomobject]@{ Key='FastStartup';       Name='Desativar inicialização rápida';              Cat='Sistema';           Default=$false }
    [pscustomobject]@{ Key='NumLock';           Name='Num Lock ligado ao iniciar';                  Cat='Teclado e mouse';   Default=$false }
    [pscustomobject]@{ Key='DisableMouseAccel'; Name='Desativar aceleração do mouse';               Cat='Teclado e mouse';   Default=$false }
    [pscustomobject]@{ Key='DisableStickyKeys'; Name='Desativar Teclas de Aderência';               Cat='Teclado e mouse';   Default=$false }
    [pscustomobject]@{ Key='GameMode';          Name='Ativar Game Mode';                            Cat='Desempenho e apps'; Default=$false }
    [pscustomobject]@{ Key='ClassicOutlook';    Name='Forçar Outlook clássico';                     Cat='Desempenho e apps'; Default=$false }
)

# Catálogo winget curado — IDs validados, sem duplicatas nem pacotes mortos.
$Packages = @(
    [pscustomobject]@{ Category='Navegadores'; Name='Brave'; Id='Brave.Brave'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Chrome'; Id='Google.Chrome'; Default=$true  }
    [pscustomobject]@{ Category='Navegadores'; Name='Chromium'; Id='Hibbiki.Chromium'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Edge'; Id='Microsoft.Edge'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Firefox'; Id='Mozilla.Firefox'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Firefox ESR'; Id='Mozilla.Firefox.ESR'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Floorp'; Id='Ablaze.Floorp'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Helium'; Id='ImputNet.Helium'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='LibreWolf'; Id='LibreWolf.LibreWolf'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Mullvad Browser'; Id='MullvadVPN.MullvadBrowser'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Tor Browser'; Id='TorProject.TorBrowser'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Ungoogled Chromium'; Id='eloston.ungoogled-chromium'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Vivaldi'; Id='Vivaldi.Vivaldi'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Waterfox'; Id='Waterfox.Waterfox'; Default=$false }
    [pscustomobject]@{ Category='Navegadores'; Name='Zen Browser'; Id='Zen-Team.Zen-Browser'; Default=$false }

    [pscustomobject]@{ Category='Comunicacao'; Name='Betterbird'; Id='Betterbird.Betterbird'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Chatterino'; Id='ChatterinoTeam.Chatterino'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Discord'; Id='Discord.Discord'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Dorion'; Id='SpikeHD.Dorion'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Element'; Id='Element.Element'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Proton Mail'; Id='Proton.ProtonMail'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='QTox'; Id='Tox.qTox'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Signal'; Id='OpenWhisperSystems.Signal'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Slack'; Id='SlackTechnologies.Slack'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Teams'; Id='Microsoft.Teams'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='TeamSpeak 3'; Id='TeamSpeakSystems.TeamSpeakClient'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Telegram'; Id='Telegram.TelegramDesktop'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Thunderbird'; Id='Mozilla.Thunderbird'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Vesktop'; Id='Vencord.Vesktop'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Viber'; Id='Rakuten.Viber'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='WhatsApp Desktop'; Id='msstore:9NKSQGP7F2NH'; Default=$false }
    [pscustomobject]@{ Category='Comunicacao'; Name='Zoom'; Id='Zoom.Zoom'; Default=$false }

    [pscustomobject]@{ Category='Multimidia'; Name='Adobe Acrobat Reader'; Id='Adobe.Acrobat.Reader.64-bit'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='AIMP (Music Player)'; Id='AIMP.AIMP'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Audacity'; Id='Audacity.Audacity'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Blender (3D Graphics)'; Id='BlenderFoundation.Blender'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Calibre'; Id='calibre.calibre'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='EarTrumpet (Audio)'; Id='File-New-Project.EarTrumpet'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='GIMP (Image Editor)'; Id='GIMP.GIMP.3'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='HandBrake'; Id='HandBrake.HandBrake'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='ImageGlass (Image Viewer)'; Id='DuongDieuPhap.ImageGlass'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='IrfanView'; Id='IrfanSkiljan.IrfanView'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='iTunes'; Id='Apple.iTunes'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='K-Lite Codec Standard'; Id='CodecGuide.K-LiteCodecPack.Standard'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='LibreOffice'; Id='TheDocumentFoundation.LibreOffice'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Media Player Classic - Home Cinema'; Id='clsid2.mpc-hc'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='mpc-qt'; Id='mpc-qt.mpc-qt'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='NAPS2 (Document Scanner)'; Id='Cyanfish.NAPS2'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='nomacs'; Id='nomacs.nomacs'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Notepad++'; Id='Notepad++.Notepad++'; Default=$true  }
    [pscustomobject]@{ Category='Multimidia'; Name='OBS Studio'; Id='OBSProject.OBSStudio'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Obsidian'; Id='Obsidian.Obsidian'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='ONLYOFFICE Desktop'; Id='ONLYOFFICE.DesktopEditors'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='Paint.NET'; Id='dotPDN.PaintDotNet'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='ShareX (Screenshots)'; Id='ShareX.ShareX'; Default=$false }
    [pscustomobject]@{ Category='Multimidia'; Name='VLC (Video Player)'; Id='VideoLAN.VLC'; Default=$true  }

    [pscustomobject]@{ Category='Utilitarios'; Name='1Password'; Id='AgileBits.1Password'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='7-Zip'; Id='7zip.7zip'; Default=$true  }
    [pscustomobject]@{ Category='Utilitarios'; Name='AnyDesk'; Id='AnyDesk.AnyDesk'; Default=$true  }
    [pscustomobject]@{ Category='Utilitarios'; Name='AutoHotkey'; Id='AutoHotkey.AutoHotkey'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Bitwarden'; Id='Bitwarden.Bitwarden'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='BlurAutoClicker'; Id='Blur009.BlurAutoClicker'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Bulk Crap Uninstaller'; Id='Klocman.BulkCrapUninstaller'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Crystal Disk Info'; Id='CrystalDewWorld.CrystalDiskInfo'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Crystal Disk Mark'; Id='CrystalDewWorld.CrystalDiskMark'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Deskflow'; Id='Deskflow.Deskflow'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Dropbox'; Id='Dropbox.Dropbox'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Ente Auth'; Id='ente-io.auth-desktop'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Everything'; Id='voidtools.Everything'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='F.lux'; Id='flux.flux'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Files'; Id='FilesCommunity.Files'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='GlazeWM'; Id='glzr-io.glazewm'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Google Drive'; Id='Google.GoogleDrive'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Hugo'; Id='Hugo.Hugo.Extended'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='HxD Hex Editor'; Id='MHNexus.HxD'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Internet Download Manager'; Id='Tonec.InternetDownloadManager'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='JPEG View'; Id='sylikc.JPEGView'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='KeePassXC'; Id='KeePassXCTeam.KeePassXC'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='MiniTool Partition Wizard'; Id='MiniTool.PartitionWizard.Free'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='MSEdgeRedirect'; Id='rcmaehl.MSEdgeRedirect'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='MSI Afterburner'; Id='Guru3D.Afterburner'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='NanaZip'; Id='M2Team.NanaZip'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Nilesoft Shell'; Id='Nilesoft.Shell'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='NVCleanstall'; Id='TechPowerUp.NVCleanstall'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='OFGB (Oh Frick Go Back)'; Id='xM4ddy.OFGB'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='OPAutoClicker'; Id='OPAutoClicker.OPAutoClicker'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='OpenRGB'; Id='OpenRGB.OpenRGB'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Oracle VirtualBox'; Id='Oracle.VirtualBox'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Parsec'; Id='Parsec.Parsec'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='PeaZip'; Id='Giorgiotani.Peazip'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Policy Plus'; Id='Fleex255.PolicyPlus'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Process Lasso'; Id='BitSum.ProcessLasso'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Proton Authenticator'; Id='Proton.ProtonAuthenticator'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Proton Drive'; Id='Proton.ProtonDrive'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Proton Pass'; Id='Proton.ProtonPass'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='qBittorrent'; Id='qBittorrent.qBittorrent'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Revo Uninstaller'; Id='RevoUninstaller.RevoUninstaller'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Rufus Imager'; Id='Rufus.Rufus'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='SignalRGB'; Id='WhirlwindFX.SignalRgb'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Snappy Driver Installer Origin'; Id='GlennDelahoy.SnappyDriverInstallerOrigin'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='StartAllBack'; Id='StartIsBack.StartAllBack'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='TeamViewer'; Id='TeamViewer.TeamViewer'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='TightVNC'; Id='GlavSoft.TightVNC'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Total Commander'; Id='Ghisler.TotalCommander'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='TranslucentTB'; Id='CharlesMilette.TranslucentTB'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='TreeSize Free'; Id='JAMSoftware.TreeSize.Free'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='UniGetUI'; Id='Devolutions.UniGetUI'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='WinRAR'; Id='RARLab.WinRAR'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='Wise Program Uninstaller (WiseCleaner)'; Id='WiseCleaner.WiseProgramUninstaller'; Default=$false }
    [pscustomobject]@{ Category='Utilitarios'; Name='WizTree'; Id='AntibodySoftware.WizTree'; Default=$false }

    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Advanced IP Scanner'; Id='Famatech.AdvancedIPScanner'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Angry IP Scanner'; Id='angryziber.AngryIPScanner'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Cinebench R23'; Id='Maxon.CinebenchR23'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='CPU-Z'; Id='CPUID.CPU-Z'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Display Driver Uninstaller'; Id='Wagnardsoft.DisplayDriverUninstaller'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='GPU-Z'; Id='TechPowerUp.GPU-Z'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='gsudo'; Id='gerardog.gsudo'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='HWiNFO'; Id='REALiX.HWiNFO'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='HWMonitor'; Id='CPUID.HWMonitor'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Mullvad VPN'; Id='MullvadVPN.MullvadVPN'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Nmap'; Id='Insecure.Nmap'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='OpenVPN Connect'; Id='OpenVPNTechnologies.OpenVPNConnect'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Proton VPN'; Id='Proton.ProtonVPN'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='PuTTY'; Id='PuTTY.PuTTY'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Simplewall'; Id='Henry++.simplewall'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Ventoy'; Id='Ventoy.Ventoy'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='WinSCP'; Id='WinSCP.WinSCP'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='WireGuard'; Id='WireGuard.WireGuard'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Pro'; Name='Wireshark'; Id='WiresharkFoundation.Wireshark'; Default=$false }

    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='.NET Desktop Runtime 10'; Id='Microsoft.DotNet.DesktopRuntime.10'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='.NET Desktop Runtime 6'; Id='Microsoft.DotNet.DesktopRuntime.6'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='.NET Desktop Runtime 8'; Id='Microsoft.DotNet.DesktopRuntime.8'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='.NET Desktop Runtime 9'; Id='Microsoft.DotNet.DesktopRuntime.9'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Autoruns'; Id='Microsoft.Sysinternals.Autoruns'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='DISMTools'; Id='CodingWondersSoftware.DISMTools.Stable'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='NTLite'; Id='Nlitesoft.NTLite'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='NuGet'; Id='Microsoft.NuGet'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='OneDrive'; Id='Microsoft.OneDrive'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='PowerShell'; Id='Microsoft.PowerShell'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='PowerToys'; Id='Microsoft.PowerToys'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Process Explorer'; Id='Microsoft.Sysinternals.ProcessExplorer'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Process Monitor'; Id='Microsoft.Sysinternals.ProcessMonitor'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='RDCMan'; Id='Microsoft.Sysinternals.RDCMan'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='TCPView'; Id='Microsoft.Sysinternals.TCPView'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Visual C++ 2015-2022 32-bit'; Id='Microsoft.VCRedist.2015+.x86'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Visual C++ 2015-2022 64-bit'; Id='Microsoft.VCRedist.2015+.x64'; Default=$false }
    [pscustomobject]@{ Category='Ferramentas Microsoft'; Name='Windows Terminal'; Id='Microsoft.WindowsTerminal'; Default=$false }

    [pscustomobject]@{ Category='Desenvolvimento'; Name='Amazon Corretto 21 (LTS)'; Id='Amazon.Corretto.21.JDK'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Amazon Corretto 25 (LTS)'; Id='Amazon.Corretto.25.JDK'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Amazon Corretto 8 (LTS)'; Id='Amazon.Corretto.8.JDK'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='ChatGPT Desktop'; Id='msstore:9NT1R1C2HH7J'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Claude Code'; Id='Anthropic.ClaudeCode'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Claude Desktop'; Id='Anthropic.Claude'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='CMake'; Id='Kitware.CMake'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Codex'; Id='OpenAI.Codex'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Cursor'; Id='Anysphere.Cursor'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Git'; Id='Git.Git'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='GitHub Desktop'; Id='GitHub.GitHubDesktop'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Go'; Id='GoLang.Go'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Jetbrains Toolbox'; Id='JetBrains.Toolbox'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='JRE Temurin 11'; Id='EclipseAdoptium.Temurin.11.JRE'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='JRE Temurin 17'; Id='EclipseAdoptium.Temurin.17.JRE'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='JRE Temurin 21'; Id='EclipseAdoptium.Temurin.21.JRE'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='JRE Temurin 8'; Id='EclipseAdoptium.Temurin.8.JRE'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Lazygit'; Id='JesseDuffield.lazygit'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Lua'; Id='rjpcomputing.luaforwindows'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Neovim'; Id='Neovim.Neovim'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='NodeJS'; Id='OpenJS.NodeJS'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='NodeJS LTS'; Id='OpenJS.NodeJS.LTS'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Oh My Posh (Prompt)'; Id='JanDeDobbeleer.OhMyPosh'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='pnpm'; Id='pnpm.pnpm'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Python3'; Id='Python.Python.3.14'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Ruby'; Id='RubyInstallerTeam.Ruby.4.0'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Rust'; Id='Rustlang.Rust.MSVC'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Sublime Text'; Id='SublimeHQ.SublimeText.4'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='System Informer'; Id='WinsiderSS.SystemInformer'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Unity Game Engine'; Id='Unity.UnityHub'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='uv'; Id='astral-sh.uv'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Visual Studio 2022'; Id='Microsoft.VisualStudio.2022.Community'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Visual Studio 2026'; Id='Microsoft.VisualStudio.Community'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='VS Code'; Id='Microsoft.VisualStudioCode'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='VS Codium'; Id='VSCodium.VSCodium'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Yarn'; Id='Yarn.Yarn'; Default=$false }
    [pscustomobject]@{ Category='Desenvolvimento'; Name='Zed'; Id='ZedIndustries.Zed'; Default=$false }

    [pscustomobject]@{ Category='Jogos'; Name='Cemu'; Id='Cemu.Cemu'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='EA App'; Id='ElectronicArts.EADesktop'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Epic Games Launcher'; Id='EpicGames.EpicGamesLauncher'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='GeForce NOW'; Id='Nvidia.GeForceNow'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='GOG Galaxy'; Id='GOG.Galaxy'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Heroic Games Launcher'; Id='HeroicGamesLauncher.HeroicGamesLauncher'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Itch.io'; Id='ItchIo.Itch'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Modrinth App'; Id='Modrinth.ModrinthApp'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Overwolf'; Id='Overwolf.CurseForge'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Playnite'; Id='Playnite.Playnite'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Prism Launcher'; Id='PrismLauncher.PrismLauncher'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Steam'; Id='Valve.Steam'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Ubisoft Connect'; Id='Ubisoft.Connect'; Default=$false }
    [pscustomobject]@{ Category='Jogos'; Name='Virtual Desktop Streamer'; Id='VirtualDesktop.Streamer'; Default=$false }

    [pscustomobject]@{ Category='Self-hosted'; Name='Jellyfin Media Player'; Id='Jellyfin.JellyfinMediaPlayer'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Jellyfin Server'; Id='Jellyfin.Server'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Kodi Media Center'; Id='XBMCFoundation.Kodi'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='LocalSend'; Id='LocalSend.LocalSend'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Moonlight/GameStream Client'; Id='MoonlightGameStreamingProject.Moonlight'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='NetBird'; Id='Netbird.Netbird'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Nextcloud Desktop'; Id='Nextcloud.NextcloudDesktop'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Plex Desktop'; Id='Plex.Plex'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Plex Media Server'; Id='Plex.PlexMediaServer'; Default=$false }
    [pscustomobject]@{ Category='Self-hosted'; Name='Sunshine/GameStream Server'; Id='LizardByte.Sunshine'; Default=$false }

    [pscustomobject]@{ Category='Backup e Seguranca'; Name='AdwCleaner'; Id='Malwarebytes.AdwCleaner'; Default=$false }
    [pscustomobject]@{ Category='Backup e Seguranca'; Name='Hasleo Backup Suite Free'; Id='Hasleo.BackupSuite'; Default=$false }
    [pscustomobject]@{ Category='Backup e Seguranca'; Name='Malwarebytes'; Id='Malwarebytes.Malwarebytes'; Default=$false }
)

# Chave única de cada pacote (Id + arquitetura quando houver)
foreach ($pkg in $Packages) {
    $arch = if ($pkg.PSObject.Properties.Name -contains 'Arch') { $pkg.Arch } else { $null }
    $key = if ($arch) { "$($pkg.Id)#$arch" } else { $pkg.Id }
    Add-Member -InputObject $pkg -NotePropertyName Key -NotePropertyValue $key -Force
}

# --- Privacidade e limpeza (aba Privacidade) ---
$PrivacyTweaks = @(
    [pscustomobject]@{ Key='Telemetry';        Name='Desativar telemetria da Microsoft';                 Cat='Essencial'; Default=$true  }
    [pscustomobject]@{ Key='ActivityHistory';  Name='Desativar histórico de atividades';                 Cat='Essencial'; Default=$true  }
    [pscustomobject]@{ Key='ConsumerFeatures'; Name='Desativar recursos de consumidor (sugestões)';      Cat='Essencial'; Default=$true  }
    [pscustomobject]@{ Key='DeliveryOpt';      Name='Desativar Delivery Optimization';                   Cat='Essencial'; Default=$true  }
    [pscustomobject]@{ Key='Location';         Name='Desativar rastreamento de localização';             Cat='Essencial'; Default=$true  }
    [pscustomobject]@{ Key='BackgroundApps';   Name='Desativar apps em segundo plano';                   Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='Hibernation';      Name='Desativar hibernação (libera espaço)';              Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='Widgets';          Name='Remover Widgets da barra de tarefas';               Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='WPBT';             Name='Desativar WPBT (segurança de firmware)';            Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='DeviceCompanion';  Name='Bloquear apps complementares de dispositivos';      Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='ServicesManual';   Name='Serviços não essenciais para Manual';               Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='StoreSearch';      Name='Bloquear recomendações da Store na busca';          Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='ExplorerDiscovery';Name='Desativar descoberta automática de pastas';         Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='DiskCleanup';      Name='Executar Limpeza de Disco';                         Cat='Essencial'; Default=$false }
    [pscustomobject]@{ Key='DeleteTemp';       Name='Apagar arquivos temporários';                       Cat='Essencial'; Default=$false }

    [pscustomobject]@{ Key='EdgeDebloat';      Name='Debloat do Microsoft Edge';                         Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='RemoveEdge';       Name='Remover Microsoft Edge';                            Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='RemoveOneDrive';   Name='Remover OneDrive';                                  Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='WindowsAI';        Name='Desativar e remover IA (Copilot/Recall)';           Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='VisualEffects';    Name='Efeitos visuais para melhor desempenho';            Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='StorageSense';     Name='Desativar Sensor de Armazenamento';                 Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='Notifications';    Name='Desativar notificações e calendário da bandeja';    Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='ReservedStorage';  Name='Desativar Armazenamento Reservado';                 Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='UTCTime';          Name='Relógio em UTC (dual boot com Linux)';              Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='HomeGallery';      Name='Remover Início e Galeria do Explorer';              Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='IPv4Preferred';    Name='Preferir IPv4 sobre IPv6';                          Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='Teredo';           Name='Desativar Teredo';                                  Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='DisableIPv6';      Name='Desativar IPv6 completamente';                      Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='RazerBlock';       Name='Bloquear auto-instalação de software Razer';        Cat='Avançado (cuidado)'; Default=$false }
    [pscustomobject]@{ Key='BraveDebloat';     Name='Debloat do navegador Brave';                        Cat='Avançado (cuidado)'; Default=$false }
)

# --- Apps da Store para remoção (aba Privacidade, coluna direita) ---
$AppxDebloat = @(
    [pscustomobject]@{ Id='Microsoft.WindowsFeedbackHub';          Name='Feedback Hub';            Cat='Apps da Microsoft'; Default=$true  }
    [pscustomobject]@{ Id='Microsoft.GetHelp';                     Name='Obter Ajuda';             Cat='Apps da Microsoft'; Default=$true  }
    [pscustomobject]@{ Id='Microsoft.OutlookForWindows';           Name='Outlook (novo)';          Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='MSTeams';                               Name='Microsoft Teams';         Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.MicrosoftOfficeHub';          Name='Microsoft 365 (Office Hub)'; Cat='Apps da Microsoft'; Default=$true }
    [pscustomobject]@{ Id='MicrosoftCorporationII.QuickAssist';    Name='Assistência Rápida';      Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.Todos';                       Name='Microsoft To Do';         Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.PowerAutomateDesktop';        Name='Power Automate';          Cat='Apps da Microsoft'; Default=$true  }
    [pscustomobject]@{ Id='Microsoft.Windows.DevHome';             Name='Dev Home';                Cat='Apps da Microsoft'; Default=$true  }
    [pscustomobject]@{ Id='Microsoft.MicrosoftStickyNotes';        Name='Notas Autoadesivas';      Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.WindowsSoundRecorder';        Name='Gravador de Som';         Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.WindowsAlarms';               Name='Relógio e Alarmes';       Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Microsoft.WindowsCamera';               Name='Câmera';                  Cat='Apps da Microsoft'; Default=$false }
    [pscustomobject]@{ Id='Clipchamp.Clipchamp';                   Name='Clipchamp';               Cat='Apps da Microsoft'; Default=$true  }
    [pscustomobject]@{ Id='Microsoft.ZuneMusic';                   Name='Media Player';            Cat='Apps da Microsoft'; Default=$false }

    [pscustomobject]@{ Id='Microsoft.BingSearch';                  Name='Bing na busca';           Cat='Bing e Web';        Default=$false }
    [pscustomobject]@{ Id='Microsoft.BingNews';                    Name='Notícias';                Cat='Bing e Web';        Default=$true  }
    [pscustomobject]@{ Id='Microsoft.BingWeather';                 Name='Clima';                   Cat='Bing e Web';        Default=$true  }
    [pscustomobject]@{ Id='Microsoft.Copilot';                     Name='Copilot';                 Cat='Bing e Web';        Default=$true  }
    [pscustomobject]@{ Id='Microsoft.StartExperiencesApp';         Name='Widgets (feed)';          Cat='Bing e Web';        Default=$true  }

    [pscustomobject]@{ Id='Microsoft.YourPhone';                   Name='Vincular ao Celular';     Cat='Ecossistema';       Default=$false }
    [pscustomobject]@{ Id='MicrosoftWindows.CrossDevice';          Name='Dispositivos Móveis';     Cat='Ecossistema';       Default=$false }

    [pscustomobject]@{ Id='Microsoft.GamingApp';                   Name='Xbox App';                Cat='Xbox e Jogos';      Default=$false }
    [pscustomobject]@{ Id='Microsoft.XboxGamingOverlay';           Name='Xbox Game Bar';           Cat='Xbox e Jogos';      Default=$false }
    [pscustomobject]@{ Id='Microsoft.XboxSpeechToTextOverlay';     Name='Xbox Voz para Texto';     Cat='Xbox e Jogos';      Default=$false }
    [pscustomobject]@{ Id='Microsoft.MicrosoftSolitaireCollection';Name='Coleção Solitaire';       Cat='Xbox e Jogos';      Default=$true  }
)

# --- Recursos opcionais do Windows (aba Recursos) ---
$WinFeatures = @(
    [pscustomobject]@{ Key='dotnet35';   Name='.NET Framework 3.5 (2.0/3.0)';               Features=@('NetFx3'); Default=$false }
    [pscustomobject]@{ Key='HyperV';     Name='Hyper-V (virtualização Microsoft)';          Features=@('Microsoft-Hyper-V-All'); Default=$false }
    [pscustomobject]@{ Key='WSL';        Name='Subsistema Linux (WSL)';                     Features=@('VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux'); Default=$false }
    [pscustomobject]@{ Key='Sandbox';    Name='Windows Sandbox';                            Features=@('Containers-DisposableClientVM'); Default=$false }
    [pscustomobject]@{ Key='NFS';        Name='Cliente NFS (Network File System)';          Features=@('ServicesForNFS-ClientOnly','ClientForNFS-Infrastructure','NFS-Administration'); Special='NFS'; Default=$false }
    [pscustomobject]@{ Key='LegacyMedia';Name='Componentes de mídia legados (WMP/DirectPlay)'; Features=@('WindowsMediaPlayer','MediaPlayback','DirectPlay','LegacyComponents'); Default=$false }
    [pscustomobject]@{ Key='TelnetClient';Name='Cliente Telnet';                            Features=@('TelnetClient'); Default=$false }
    [pscustomobject]@{ Key='SSHServer';  Name='Servidor OpenSSH (acesso remoto por SSH)';   Features=@(); Special='SSHServer'; Default=$false }
    [pscustomobject]@{ Key='RegBackup';  Name='Backup diário do registro (00:30)';          Features=@(); Special='RegBackup'; Default=$false }
    [pscustomobject]@{ Key='LegacyF8';   Name='Recuperação por F8 (menu de boot legado)';   Features=@(); Special='LegacyF8'; Default=$false }
)

# --- Painéis clássicos do Windows (aba Recursos) ---
$LegacyPanels = @(
    [pscustomobject]@{ Name='Painel de Controle';          Cmd='control' }
    [pscustomobject]@{ Name='Programas e Recursos';        Cmd='appwiz.cpl' }
    [pscustomobject]@{ Name='Gerenciamento do Computador'; Cmd='compmgmt.msc' }
    [pscustomobject]@{ Name='Gerenciador de Dispositivos'; Cmd='devmgmt.msc' }
    [pscustomobject]@{ Name='Gerenciamento de Disco';      Cmd='diskmgmt.msc' }
    [pscustomobject]@{ Name='Serviços';                    Cmd='services.msc' }
    [pscustomobject]@{ Name='Opções de Energia';           Cmd='powercfg.cpl' }
    [pscustomobject]@{ Name='Som';                         Cmd='mmsys.cpl' }
    [pscustomobject]@{ Name='Conexões de Rede';            Cmd='ncpa.cpl' }
    [pscustomobject]@{ Name='Propriedades do Sistema';     Cmd='sysdm.cpl' }
    [pscustomobject]@{ Name='Firewall do Windows';         Cmd='firewall.cpl' }
    [pscustomobject]@{ Name='Restauração do Sistema';      Cmd='rstrui.exe' }
    [pscustomobject]@{ Name='Data e Hora';                 Cmd='timedate.cpl' }
    [pscustomobject]@{ Name='Região';                      Cmd='intl.cpl' }
)

# --- Servidores DNS (aba Recursos) ---
$DnsProviders = [ordered]@{
    'Padrão (automático/DHCP)'        = $null
    'Google'                          = @{ V4=@('8.8.8.8','8.8.4.4');             V6=@('2001:4860:4860::8888','2001:4860:4860::8844') }
    'Cloudflare'                      = @{ V4=@('1.1.1.1','1.0.0.1');             V6=@('2606:4700:4700::1111','2606:4700:4700::1001') }
    'Cloudflare (bloqueia malware)'   = @{ V4=@('1.1.1.2','1.0.0.2');             V6=@('2606:4700:4700::1112','2606:4700:4700::1002') }
    'OpenDNS'                         = @{ V4=@('208.67.222.222','208.67.220.220'); V6=@('2620:119:35::35','2620:119:53::53') }
    'Quad9'                           = @{ V4=@('9.9.9.9','149.112.112.112');     V6=@('2620:fe::fe','2620:fe::9') }
    'AdGuard (bloqueia anúncios)'     = @{ V4=@('94.140.14.14','94.140.15.15');   V6=@('2a10:50c0::ad1:ff','2a10:50c0::ad2:ff') }
}

# ---------------------------------------------------------------------------
# Construção de $sync.OpData — mapa chave -> operações (registro/serviço/ação).
# Acessível por referência dentro dos runspaces (via $sync).
# Cada entrada: @{ Reg=@(@{P;N;V;T}); Svc=@(@{N;S}); Special='Nome'; Explorer=$true }
# ---------------------------------------------------------------------------
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$sync.OpData = @{
    # Preferências
    'ShowExtensions'    = @{ Reg=@(@{P=$adv; N='HideFileExt'; V=0; T='DWord'}); Explorer=$true }
    'ShowHidden'        = @{ Reg=@(@{P=$adv; N='Hidden'; V=1; T='DWord'}); Explorer=$true }
    'ThisPc'            = @{ Reg=@(@{P=$adv; N='LaunchTo'; V=1; T='DWord'}); Explorer=$true }
    'ClassicMenu'       = @{ Special='ClassicMenu'; Explorer=$true }
    'Clipboard'         = @{ Reg=@(@{P='HKCU:\Software\Microsoft\Clipboard'; N='EnableClipboardHistory'; V=1; T='DWord'}) }
    'DarkMode'          = @{ Reg=@(
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N='AppsUseLightTheme'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N='SystemUsesLightTheme'; V=0; T='DWord'}
                            ); Explorer=$true }
    'Scrollbars'        = @{ Reg=@(@{P='HKCU:\Control Panel\Accessibility'; N='DynamicScrollbars'; V=0; T='DWord'}) }
    'TaskbarLeft'       = @{ Reg=@(@{P=$adv; N='TaskbarAl'; V=0; T='DWord'}); Explorer=$true }
    'HideTaskView'      = @{ Reg=@(@{P=$adv; N='ShowTaskViewButton'; V=0; T='DWord'}); Explorer=$true }
    'HideSearchBox'     = @{ Reg=@(@{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N='SearchboxTaskbarMode'; V=0; T='DWord'}); Explorer=$true }
    'EndTask'           = @{ Reg=@(@{P="$adv\TaskbarDeveloperSettings"; N='TaskbarEndTask'; V=1; T='DWord'}) }
    'BatteryPercentage' = @{ Reg=@(@{P=$adv; N='IsBatteryPercentageEnabled'; V=1; T='DWord'}) }
    'NoBingSearch'      = @{ Reg=@(
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N='BingSearchEnabled'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N='DisableSearchBoxSuggestions'; V=1; T='DWord'}
                            ) }
    'StartNoRecommend'  = @{ Reg=@(
                                @{P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; N='HideRecommendedSection'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; N='HideRecommendedSection'; V=1; T='DWord'}
                            ); Explorer=$true }
    'VerboseLogon'      = @{ Reg=@(@{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; N='VerboseStatus'; V=1; T='DWord'}) }
    'DetailedBSoD'      = @{ Reg=@(
                                @{P='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; N='DisplayParameters'; V=1; T='DWord'},
                                @{P='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; N='DisableEmoticon'; V=1; T='DWord'}
                            ) }
    'LongPaths'         = @{ Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; N='LongPathsEnabled'; V=1; T='DWord'}) }
    'DisableLockscreen' = @{ Reg=@(@{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'; N='NoLockScreen'; V=1; T='DWord'}) }
    'FastStartup'       = @{ Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; N='HiberbootEnabled'; V=0; T='DWord'}) }
    'NumLock'           = @{ Reg=@(@{P='HKCU:\Control Panel\Keyboard'; N='InitialKeyboardIndicators'; V='2'; T='String'}) }
    'DisableMouseAccel' = @{ Reg=@(
                                @{P='HKCU:\Control Panel\Mouse'; N='MouseSpeed'; V='0'; T='String'},
                                @{P='HKCU:\Control Panel\Mouse'; N='MouseThreshold1'; V='0'; T='String'},
                                @{P='HKCU:\Control Panel\Mouse'; N='MouseThreshold2'; V='0'; T='String'}
                            ) }
    'DisableStickyKeys' = @{ Reg=@(@{P='HKCU:\Control Panel\Accessibility\StickyKeys'; N='Flags'; V='506'; T='String'}) }
    'GameMode'          = @{ Reg=@(
                                @{P='HKCU:\Software\Microsoft\GameBar'; N='AllowAutoGameMode'; V=1; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\GameBar'; N='AutoGameModeEnabled'; V=1; T='DWord'}
                            ) }
    'ClassicOutlook'    = @{ Reg=@(@{P='HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Preferences'; N='UseNewOutlook'; V=0; T='DWord'}) }

    # Privacidade — essenciais
    'Telemetry'         = @{ Special='TelemetryExtra'; Reg=@(
                                @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N='AllowTelemetry'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N='Enabled'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; N='TailoredExperiencesWithDiagnosticDataEnabled'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; N='HasAccepted'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Input\TIPC'; N='Enabled'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\InputPersonalization'; N='RestrictImplicitInkCollection'; V=1; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\InputPersonalization'; N='RestrictImplicitTextCollection'; V=1; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N='Start_TrackProgs'; V=0; T='DWord'}
                            ) }
    'ActivityHistory'   = @{ Reg=@(
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='EnableActivityFeed'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='PublishUserActivities'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N='UploadUserActivities'; V=0; T='DWord'}
                            ) }
    'ConsumerFeatures'  = @{ Reg=@(@{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N='DisableWindowsConsumerFeatures'; V=1; T='DWord'}) }
    'DeliveryOpt'       = @{ Reg=@(@{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N='DODownloadMode'; V=0; T='DWord'}) }
    'Location'          = @{ Svc=@(@{N='lfsvc'; S='Disabled'}); Reg=@(
                                @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; N='Value'; V='Deny'; T='String'},
                                @{P='HKLM:\SYSTEM\Maps'; N='AutoUpdateEnabled'; V=0; T='DWord'}
                            ) }
    'BackgroundApps'    = @{ Reg=@(@{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; N='GlobalUserDisabled'; V=1; T='DWord'}) }
    'Hibernation'       = @{ Special='HiberOff'; Reg=@(@{P='HKLM:\System\CurrentControlSet\Control\Session Manager\Power'; N='HibernateEnabled'; V=0; T='DWord'}) }
    'Widgets'           = @{ Special='RemoveWidgets' }
    'WPBT'              = @{ Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; N='DisableWpbtExecution'; V=1; T='DWord'}) }
    'DeviceCompanion'   = @{ Reg=@(@{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N='PreventDeviceMetadataFromNetwork'; V=1; T='DWord'}) }
    'ServicesManual'    = @{ Special='SvcHostSplit'; Svc=@(
                                @{N='DiagTrack'; S='Disabled'}, @{N='MapsBroker'; S='Manual'},
                                @{N='StorSvc'; S='Manual'}, @{N='SharedAccess'; S='Disabled'}
                            ) }
    'StoreSearch'       = @{ Special='StoreSearchBlock' }
    'ExplorerDiscovery' = @{ Special='ExplorerDiscovery' }
    'DiskCleanup'       = @{ Special='DiskCleanup' }
    'DeleteTemp'        = @{ Special='DeleteTemp' }

    # Privacidade — avançados
    'EdgeDebloat'       = @{ Reg=@(
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='PersonalizationReportingEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='ShowRecommendationsEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='HideFirstRunExperience'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='UserFeedbackAllowed'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='EdgeCollectionsEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='EdgeShoppingAssistantEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='ShowMicrosoftRewards'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='WebWidgetAllowed'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='DiagnosticData'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N='DefaultBrowserSettingsCampaignEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; N='CreateDesktopShortcutDefault'; V=0; T='DWord'}
                            ) }
    'RemoveEdge'        = @{ Special='RemoveEdge' }
    'RemoveOneDrive'    = @{ Special='RemoveOneDrive' }
    'WindowsAI'         = @{ Special='WindowsAI'; Reg=@(
                                @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; N='SettingsPageVisibility'; V='hide:aicomponents'; T='String'},
                                @{P='HKLM:\SOFTWARE\Policies\WindowsNotepad'; N='DisableAIFeatures'; V=1; T='DWord'}
                            ) }
    'VisualEffects'     = @{ Special='VisualFxMask'; Reg=@(
                                @{P='HKCU:\Control Panel\Desktop'; N='DragFullWindows'; V='0'; T='String'},
                                @{P='HKCU:\Control Panel\Desktop\WindowMetrics'; N='MinAnimate'; V='0'; T='String'},
                                @{P="$adv"; N='ListviewAlphaSelect'; V=0; T='DWord'},
                                @{P="$adv"; N='ListviewShadow'; V=0; T='DWord'},
                                @{P="$adv"; N='TaskbarAnimations'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; N='VisualFXSetting'; V=3; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\DWM'; N='EnableAeroPeek'; V=0; T='DWord'}
                            ) }
    'StorageSense'      = @{ Reg=@(@{P='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; N='01'; V=0; T='DWord'}) }
    'Notifications'     = @{ Reg=@(
                                @{P='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; N='DisableNotificationCenter'; V=1; T='DWord'},
                                @{P='HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; N='ToastEnabled'; V=0; T='DWord'}
                            ) }
    'ReservedStorage'   = @{ Special='ReservedStorage' }
    'UTCTime'           = @{ Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'; N='RealTimeIsUniversal'; V=1; T='QWord'}) }
    'HomeGallery'       = @{ Reg=@(
                                @{P='HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'; N='System.IsPinnedToNameSpaceTree'; V=0; T='DWord'},
                                @{P='HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'; N='System.IsPinnedToNameSpaceTree'; V=0; T='DWord'},
                                @{P="$adv"; N='LaunchTo'; V=1; T='DWord'}
                            ); Explorer=$true }
    'IPv4Preferred'     = @{ Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'; N='DisabledComponents'; V=32; T='DWord'}) }
    'Teredo'            = @{ Special='Teredo' }
    'DisableIPv6'       = @{ Special='DisableIPv6'; Reg=@(@{P='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'; N='DisabledComponents'; V=255; T='DWord'}) }
    'RazerBlock'        = @{ Special='RazerBlock'; Reg=@(
                                @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; N='SearchOrderConfig'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer'; N='DisableCoInstallers'; V=1; T='DWord'}
                            ) }
    'BraveDebloat'      = @{ Reg=@(
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveRewardsDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveWalletDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveVPNDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveAIChatEnabled'; V=0; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveNewsDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveTalkDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='TorDisabled'; V=1; T='DWord'},
                                @{P='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; N='BraveP3AEnabled'; V=0; T='DWord'}
                            ) }
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

            # IDs no formato "msstore:XXXX" vêm da Microsoft Store (não do repositório winget)
            $pkgId = [string]$pkg.Id
            $source = 'winget'
            if ($pkgId -like 'msstore:*') {
                $pkgId = $pkgId.Substring(8)
                $source = 'msstore'
            }
            $wgArgs = @('install', '--id', $pkgId, '-e', '--silent', '--source', $source,
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

function Invoke-GwtWingetUninstallWorker {
    param([object[]]$Selected)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]$Selected.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ DESINSTALAÇÃO VIA WINGET ($($Selected.Count) pacote(s)) ================"

        $okList = New-Object System.Collections.Generic.List[string]
        $failList = New-Object System.Collections.Generic.List[string]
        $index = 0

        foreach ($pkg in $Selected) {
            $index++
            $pkgId = [string]$pkg.Id
            if ($pkgId -like 'msstore:*') { $pkgId = $pkgId.Substring(8) }
            $sync.StatusText = "Desinstalando $($pkg.Name) ($index de $($Selected.Count))..."
            Add-GwtLog "▶ [$index/$($Selected.Count)] $($pkg.Name) ($pkgId)"

            & winget.exe uninstall --id $pkgId -e --silent --disable-interactivity --accept-source-agreements 2>&1 | ForEach-Object {
                $line = ([string]$_).Trim()
                if ($line -and $line.Length -le 220 -and $line -notmatch '^[\s\-\\|/█▒░]+$') { Add-GwtLog "    $line" }
            }
            $code = $LASTEXITCODE
            if ($code -eq 0) { $okList.Add($pkg.Name); Add-GwtLog "$($pkg.Name): desinstalado." 'Success' }
            else { $failList.Add($pkg.Name); Add-GwtLog "$($pkg.Name): não desinstalado (código 0x$('{0:X8}' -f $code) — talvez não esteja instalado)." 'Warn' }
            $sync.ProgressValue = [double]$index
        }

        Add-GwtLog "================ RESULTADO: $($okList.Count) removido(s), $($failList.Count) sem ação ================" $(if ($failList.Count -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'Message'; Title = 'Desinstalação concluída'; Kind = 'Info'
                         Text = "Removidos: $($okList.Count)`nSem ação (talvez ausentes): $($failList.Count)" }
    }
    catch {
        Add-GwtLog "Falha na desinstalação: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Get-GwtWingetLatestVersion {
    # Lê a versão mais recente publicada no winget para um id (independente do idioma).
    param([string]$Id)
    try {
        $out = & winget.exe show --id $Id -e --disable-interactivity --accept-source-agreements 2>&1
        foreach ($line in $out) {
            $m = [regex]::Match([string]$line, '(?i)vers(?:ion|[aã]o)\s*:\s*(\S+)')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
    }
    catch { }
    return ''
}

function Get-GwtInstallerInType {
    # Descobre o tipo do instalador lendo o manifesto YAML que o winget download salva.
    param([string]$AppDir)
    $type = ''
    $yaml = Get-ChildItem -LiteralPath $AppDir -Recurse -Filter '*.yaml' -ErrorAction SilentlyContinue |
            Select-String -Pattern 'InstallerType:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($yaml -and $yaml.Matches.Count -gt 0) { $type = $yaml.Matches[0].Groups[1].Value.Trim().ToLower() }
    return $type
}

function Get-GwtKitInstallerFile {
    param([string]$AppDir)
    return Get-ChildItem -LiteralPath $AppDir -Recurse -ErrorAction SilentlyContinue -Include '*.msi', '*.exe', '*.msix', '*.appx', '*.msixbundle', '*.appxbundle' |
           Sort-Object Length -Descending | Select-Object -First 1
}

function Invoke-GwtKitDownloadWorker {
    param([object[]]$Selected, [string]$KitDir)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]$Selected.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ BAIXAR KIT OFFLINE ($($Selected.Count)) ================"
        Add-GwtLog "Pasta do kit: $KitDir"
        New-Item -ItemType Directory -Path $KitDir -Force | Out-Null

        $apps = New-Object System.Collections.Generic.List[object]
        $okList = New-Object System.Collections.Generic.List[string]
        $failList = New-Object System.Collections.Generic.List[string]
        $index = 0

        foreach ($pkg in $Selected) {
            $index++
            $pkgId = [string]$pkg.Id
            if ($pkgId -like 'msstore:*') {
                Add-GwtLog "$($pkg.Name): é da Microsoft Store — não dá para baixar para o kit offline. Pulando." 'Warn'
                $failList.Add("$($pkg.Name) (Store)")
                $sync.ProgressValue = [double]$index
                continue
            }
            $folderName = ($pkgId -replace '[\\/:*?"<>| ]', '_')
            $appDir = Join-Path $KitDir $folderName
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null

            $sync.StatusText = "Baixando $($pkg.Name) ($index de $($Selected.Count))..."
            Add-GwtLog "▶ [$index/$($Selected.Count)] $($pkg.Name) ($pkgId)"
            & winget.exe download -e --id $pkgId --download-directory $appDir --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | ForEach-Object {
                $line = ([string]$_).Trim()
                if ($line -and $line.Length -le 220 -and $line -notmatch '^[\s\-\\|/█▒░]+$') { Add-GwtLog "    $line" }
            }
            $code = $LASTEXITCODE

            $file = Get-GwtKitInstallerFile -AppDir $appDir
            if ($code -eq 0 -and $file) {
                $type = Get-GwtInstallerInType -AppDir $appDir
                $ver = Get-GwtWingetLatestVersion -Id $pkgId
                $apps.Add([pscustomobject]@{ Id = $pkgId; Name = $pkg.Name; Folder = $folderName; Type = $type; Version = $ver })
                $okList.Add($pkg.Name)
                Add-GwtLog "$($pkg.Name): baixado ($($file.Name), v$ver, tipo '$type')." 'Success'
            }
            else {
                $failList.Add($pkg.Name)
                Add-GwtLog "$($pkg.Name): download falhou (código 0x$('{0:X8}' -f $code))." 'Error'
            }
            $sync.ProgressValue = [double]$index
        }

        # Grava/atualiza o perfil kit.json (mescla com o que já existir)
        $kitFile = Join-Path $KitDir 'kit.json'
        $existing = @()
        if (Test-Path $kitFile) {
            try { $existing = @((Get-Content $kitFile -Raw | ConvertFrom-Json).Apps) } catch { }
        }
        $byId = @{}
        foreach ($a in $existing) { if ($a.Id) { $byId[$a.Id] = $a } }
        foreach ($a in $apps) { $byId[$a.Id] = $a }

        [pscustomobject]@{
            Tool      = 'GeniusWindowsToolkit'
            CreatedAt = (Get-Date).ToString('o')
            Apps      = @($byId.Values | Sort-Object Name)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $kitFile -Encoding UTF8

        Add-GwtLog "================ KIT: $($okList.Count) baixado(s), $($failList.Count) falha(s). Perfil: $kitFile ================" $(if ($failList.Count -eq 0) { 'Success' } else { 'Warn' })
        $summary = "Baixados: $($okList.Count)`nFalhas/pulados: $($failList.Count)`n`nPasta: $KitDir`n`nAgora você pode levar essa pasta no pendrive e usar 'Instalar do kit offline' em qualquer máquina, sem internet."
        Request-GwtUi @{ Action = 'Message'; Title = 'Kit offline pronto'; Text = $summary; Kind = $(if ($failList.Count -eq 0) { 'Info' } else { 'Warning' }) }
    }
    catch {
        Add-GwtLog "Falha ao baixar o kit: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro no kit'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtKitInstallWorker {
    param([string]$KitDir)

    try {
        $sync.Busy = $true
        $kitFile = Join-Path $KitDir 'kit.json'
        if (-not (Test-Path $kitFile)) { throw "Perfil kit.json não encontrado em $KitDir. Baixe um kit primeiro." }

        $kit = Get-Content $kitFile -Raw | ConvertFrom-Json
        $apps = @($kit.Apps)
        $sync.ProgressMax = [double]$apps.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ INSTALAR DO KIT OFFLINE ($($apps.Count)) ================"

        $okList = New-Object System.Collections.Generic.List[string]
        $failList = New-Object System.Collections.Generic.List[string]
        $index = 0

        foreach ($app in $apps) {
            $index++
            $appDir = Join-Path $KitDir ([string]$app.Folder)
            $sync.StatusText = "Instalando $($app.Name) ($index de $($apps.Count))..."
            Add-GwtLog "▶ [$index/$($apps.Count)] $($app.Name)"

            $file = Get-GwtKitInstallerFile -AppDir $appDir
            if (-not $file) {
                $failList.Add($app.Name)
                Add-GwtLog "$($app.Name): instalador não encontrado em $appDir." 'Error'
                $sync.ProgressValue = [double]$index
                continue
            }

            $type = ([string]$app.Type).ToLower()
            $ext = $file.Extension.ToLower()
            try {
                if ($ext -eq '.msi') {
                    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($file.FullName)`"", '/qn', '/norestart') -Wait -PassThru
                    $rc = $p.ExitCode
                }
                elseif ($ext -in '.msix', '.appx', '.msixbundle', '.appxbundle') {
                    Add-AppxPackage -Path $file.FullName -ErrorAction Stop
                    $rc = 0
                }
                else {
                    # .exe — usa o switch silencioso conforme o tipo do manifesto
                    $silent = switch -Regex ($type) {
                        'nullsoft'   { @('/S') }
                        'inno'       { @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
                        'burn|wix|msi' { @('/quiet', '/norestart') }
                        default      { $null }
                    }
                    if ($null -ne $silent) {
                        $p = Start-Process $file.FullName -ArgumentList $silent -Wait -PassThru
                        $rc = $p.ExitCode
                    }
                    else {
                        Add-GwtLog "$($app.Name): tipo de instalador desconhecido — abrindo de forma interativa." 'Warn'
                        $p = Start-Process $file.FullName -Wait -PassThru
                        $rc = $p.ExitCode
                    }
                }

                if ($rc -eq 0 -or $rc -eq 3010) {
                    $okList.Add($app.Name)
                    Add-GwtLog "$($app.Name): instalado$(if ($rc -eq 3010) { ' (reinício pendente)' })." 'Success'
                }
                else {
                    $failList.Add($app.Name)
                    Add-GwtLog "$($app.Name): instalador retornou código $rc." 'Warn'
                }
            }
            catch {
                $failList.Add($app.Name)
                Add-GwtLog "$($app.Name): $($_.Exception.Message)" 'Error'
            }
            $sync.ProgressValue = [double]$index
        }

        Add-GwtLog "================ KIT INSTALADO: $($okList.Count) ok, $($failList.Count) falha(s) ================" $(if ($failList.Count -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'Message'; Title = 'Instalação offline concluída'; Kind = $(if ($failList.Count -eq 0) { 'Info' } else { 'Warning' })
                         Text = "Instalados: $($okList.Count)`nFalhas: $($failList.Count)" }
    }
    catch {
        Add-GwtLog "Falha ao instalar do kit: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro no kit offline'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtKitCheckWorker {
    param([string]$KitDir)

    try {
        $sync.Busy = $true
        $kitFile = Join-Path $KitDir 'kit.json'
        if (-not (Test-Path $kitFile)) { throw "Perfil kit.json não encontrado em $KitDir." }
        $kit = Get-Content $kitFile -Raw | ConvertFrom-Json
        $apps = @($kit.Apps)
        $sync.ProgressMax = [double]$apps.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ VERIFICAR ATUALIZAÇÕES DO KIT ($($apps.Count)) ================"

        $updates = New-Object System.Collections.Generic.List[object]
        $index = 0
        foreach ($app in $apps) {
            $index++
            $sync.StatusText = "Verificando $($app.Name) ($index de $($apps.Count))..."
            $current = [string]$app.Version
            $latest = Get-GwtWingetLatestVersion -Id ([string]$app.Id)
            if (-not $latest) {
                Add-GwtLog "$($app.Name): não foi possível consultar a versão (pulando)." 'Warn'
            }
            elseif ([string]::IsNullOrWhiteSpace($current) -or ($latest -ne $current)) {
                $fromText = if ($current) { "v$current" } else { 'versão desconhecida' }
                Add-GwtLog "$($app.Name): ATUALIZAÇÃO — $fromText → v$latest" 'Warn'
                $updates.Add([pscustomobject]@{ Id = [string]$app.Id; Name = [string]$app.Name; From = $current; To = $latest })
            }
            else {
                Add-GwtLog "$($app.Name): já está na última (v$current)." 'Success'
            }
            $sync.ProgressValue = [double]$index
        }

        $sync.KitDir = $KitDir
        $sync.KitUpdates = @($updates)
        Add-GwtLog "Verificação concluída: $($updates.Count) com atualização de $($apps.Count)." $(if ($updates.Count -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'KitUpdatesFound' }
    }
    catch {
        Add-GwtLog "Falha ao verificar atualizações: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro na verificação'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtKitUpdateWorker {
    param([string]$KitDir, [object[]]$Updates)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]$Updates.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ ATUALIZAR INSTALADORES DO KIT ($($Updates.Count)) ================"

        $kitFile = Join-Path $KitDir 'kit.json'
        $kit = Get-Content $kitFile -Raw | ConvertFrom-Json
        $byId = @{}
        foreach ($a in @($kit.Apps)) { $byId[[string]$a.Id] = $a }

        $ok = 0; $fail = 0; $index = 0
        foreach ($upd in $Updates) {
            $index++
            $id = [string]$upd.Id
            $entry = $byId[$id]
            if (-not $entry) { $sync.ProgressValue = [double]$index; continue }
            $folderName = [string]$entry.Folder
            $appDir = Join-Path $KitDir $folderName

            $sync.StatusText = "Atualizando $($upd.Name) ($index de $($Updates.Count))..."
            Add-GwtLog "▶ [$index/$($Updates.Count)] $($upd.Name): baixando v$($upd.To)..."

            # Remove os instaladores antigos antes de baixar o novo (substituição limpa)
            if (Test-Path $appDir) {
                Get-ChildItem -LiteralPath $appDir -Recurse -Include '*.msi', '*.exe', '*.msix', '*.appx', '*.msixbundle', '*.appxbundle', '*.yaml' -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null

            & winget.exe download -e --id $id --download-directory $appDir --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | ForEach-Object {
                $line = ([string]$_).Trim()
                if ($line -and $line.Length -le 220 -and $line -notmatch '^[\s\-\\|/█▒░]+$') { Add-GwtLog "    $line" }
            }
            $code = $LASTEXITCODE
            $file = Get-GwtKitInstallerFile -AppDir $appDir

            if ($code -eq 0 -and $file) {
                $entry.Type = Get-GwtInstallerInType -AppDir $appDir
                if ($entry.PSObject.Properties.Name -contains 'Version') { $entry.Version = [string]$upd.To }
                else { Add-Member -InputObject $entry -NotePropertyName Version -NotePropertyValue ([string]$upd.To) -Force }
                $ok++
                Add-GwtLog "$($upd.Name): instalador substituído (agora v$($upd.To))." 'Success'
            }
            else {
                $fail++
                Add-GwtLog "$($upd.Name): falha ao baixar a nova versão (código 0x$('{0:X8}' -f $code)) — mantido o antigo." 'Error'
            }
            $sync.ProgressValue = [double]$index
        }

        # Regrava o kit.json com as versões atualizadas
        [pscustomobject]@{
            Tool      = 'GeniusWindowsToolkit'
            CreatedAt = (Get-Date).ToString('o')
            Apps      = @($byId.Values | Sort-Object Name)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $kitFile -Encoding UTF8

        Add-GwtLog "================ ATUALIZAÇÃO: $ok substituído(s), $fail falha(s) ================" $(if ($fail -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'Message'; Title = 'Kit atualizado'; Kind = $(if ($fail -eq 0) { 'Info' } else { 'Warning' })
                         Text = "Instaladores substituídos: $ok`nFalhas: $fail" }
    }
    catch {
        Add-GwtLog "Falha ao atualizar o kit: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro ao atualizar'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtDetectInstalledWorker {
    try {
        $sync.Busy = $true
        $sync.StatusText = 'Detectando programas instalados...'
        Add-GwtLog 'Consultando o winget para detectar o que já está instalado...'

        $installed = @{}
        & winget.exe list --disable-interactivity --accept-source-agreements 2>&1 | ForEach-Object {
            $line = [string]$_
            # Captura tokens que parecem IDs winget (Editor.Produto)
            foreach ($m in [regex]::Matches($line, '[A-Za-z0-9][A-Za-z0-9\.\-\+]+\.[A-Za-z0-9][A-Za-z0-9\.\-\+]+')) {
                $installed[$m.Value.ToLower()] = $true
            }
        }
        $sync['DetectedInstalled'] = $installed
        Add-GwtLog "Detecção concluída ($($installed.Count) identificadores encontrados)." 'Success'
        Request-GwtUi @{ Action = 'MarkInstalled' }
    }
    catch {
        Add-GwtLog "Falha na detecção: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtUpdatePolicyWorker {
    param([string]$Mode)

    try {
        $sync.Busy = $true
        $sync.StatusText = "Aplicando política de Windows Update ($Mode)..."
        Add-GwtLog "================ WINDOWS UPDATE: $Mode ================"

        $backup = Backup-GwtRegistrySet -Name 'winupdate' -Keys @(
            'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
            'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
            'HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching',
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
        )
        Add-GwtLog "Backup criado em: $backup" 'Success'

        $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $drvPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
        $doPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
        $updateTasks = @(
            '\Microsoft\Windows\InstallService\*', '\Microsoft\Windows\UpdateOrchestrator\*',
            '\Microsoft\Windows\UpdateAssistant\*', '\Microsoft\Windows\WaaSMedic\*',
            '\Microsoft\Windows\WindowsUpdate\*', '\Microsoft\WindowsUpdate\*'
        )

        switch ($Mode) {
            'Disable' {
                Add-GwtLog 'Desativando o Windows Update (serviços, tarefas e políticas)...'
                Set-GwtRegistryEntry -Path $auPath -Name 'NoAutoUpdate' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $auPath -Name 'AUOptions' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $doPath -Name 'DODownloadMode' -Value 0 -Type DWord
                foreach ($svc in 'BITS', 'wuauserv', 'UsoSvc') {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
                }
                Remove-Item -Path 'C:\Windows\SoftwareDistribution\*' -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($t in $updateTasks) { Get-ScheduledTask -TaskPath $t -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue }
                Add-GwtLog 'Windows Update DESATIVADO. Reinício recomendado. (Não recomendado a longo prazo.)' 'Warn'
            }
            'Security' {
                Add-GwtLog 'Aplicando modo recomendado (só segurança, adia recursos por 1 ano)...'
                # Reativa serviços/tarefas primeiro
                Remove-ItemProperty -Path $auPath -Name 'NoAutoUpdate' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $doPath -Name 'DODownloadMode' -ErrorAction SilentlyContinue
                Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue
                Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
                Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name UsoSvc -ErrorAction SilentlyContinue
                foreach ($t in $updateTasks) { Get-ScheduledTask -TaskPath $t -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue }
                # Não oferecer drivers pelo Windows Update
                Set-GwtRegistryEntry -Path $drvPath -Name 'DontPromptForWindowsUpdate' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $drvPath -Name 'DontSearchWindowsUpdate' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $drvPath -Name 'DriverUpdateWizardWuSearchEnabled' -Value 0 -Type DWord
                Set-GwtRegistryEntry -Path $wuPath -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord
                # Adiar recursos 365 dias, qualidade 4 dias
                Set-GwtRegistryEntry -Path $wuPath -Name 'DeferFeatureUpdates' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $wuPath -Name 'DeferFeatureUpdatesPeriodInDays' -Value 365 -Type DWord
                Set-GwtRegistryEntry -Path $wuPath -Name 'DeferQualityUpdates' -Value 1 -Type DWord
                Set-GwtRegistryEntry -Path $wuPath -Name 'DeferQualityUpdatesPeriodInDays' -Value 4 -Type DWord
                # Não reiniciar com usuário logado
                Set-GwtRegistryEntry -Path $auPath -Name 'AUOptions' -Value 4 -Type DWord
                Set-GwtRegistryEntry -Path $auPath -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
                Add-GwtLog 'Windows Update em modo recomendado (segurança em dia, recursos adiados).' 'Success'
            }
            'Default' {
                Add-GwtLog 'Restaurando as configurações padrão do Windows Update...'
                $reset = @(
                    @{ P=$auPath; N=@('NoAutoUpdate', 'AUOptions', 'NoAutoRebootWithLoggedOnUsers', 'AUPowerManagement') },
                    @{ P=$wuPath; N=@('ExcludeWUDriversInQualityUpdate', 'DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays') },
                    @{ P=$drvPath; N=@('DontPromptForWindowsUpdate', 'DontSearchWindowsUpdate', 'DriverUpdateWizardWuSearchEnabled') },
                    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N=@('PreventDeviceMetadataFromNetwork') },
                    @{ P=$doPath; N=@('DODownloadMode') }
                )
                foreach ($e in $reset) { foreach ($n in $e.N) { Remove-ItemProperty -Path $e.P -Name $n -ErrorAction SilentlyContinue } }
                foreach ($svc in 'BITS', 'wuauserv') { Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue }
                Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
                foreach ($t in $updateTasks) { Get-ScheduledTask -TaskPath $t -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue }
                Add-GwtLog 'Windows Update restaurado ao padrão.' 'Success'
            }
        }
        Request-GwtUi @{ Action = 'Message'; Title = 'Windows Update'; Kind = 'Info'; Text = "Política aplicada: $Mode.`nUm reinício pode ser necessário." }
    }
    catch {
        Add-GwtLog "Falha na política de Update: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

# ---- Aplicadores genéricos (usados por Ajustes e Privacidade) ----

function Set-GwtRegistryEntry {
    param([string]$Path, [string]$Name, $Value, [string]$Type)

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $data = switch ($Type) {
        'Binary' { [byte[]]$Value }
        'QWord'  { [int64]$Value }
        'DWord'  { [int32]$Value }
        default  { [string]$Value }
    }
    New-ItemProperty -Path $Path -Name $Name -Value $data -PropertyType $Type -Force | Out-Null
}

function Set-GwtServiceStartup {
    param([string]$Name, [string]$Startup)
    $normalized = switch ($Startup) {
        'Disable'   { 'Disabled' }
        'Disabled'  { 'Disabled' }
        'Manual'    { 'Manual' }
        default     { 'Automatic' }
    }
    Set-Service -Name $Name -StartupType $normalized -ErrorAction Stop
}

function Invoke-GwtOpSpecial {
    param([string]$Special)

    switch ($Special) {
        'ClassicMenu' {
            $clsid = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            New-Item -Path $clsid -Force | Out-Null
            Set-ItemProperty -Path $clsid -Name '(Default)' -Value '' | Out-Null
        }
        'TelemetryExtra' {
            try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop } catch { }
            foreach ($svc in 'DiagTrack', 'dmwappushservice') {
                try { Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop } catch { }
            }
            [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
        }
        'HiberOff'   { & powercfg.exe /hibernate off | Out-Null }
        'RemoveWidgets' {
            Get-Process *Widget* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Get-AppxPackage 'Microsoft.WidgetsPlatformRuntime' -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxPackage 'MicrosoftWindows.Client.WebExperience' -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        }
        'SvcHostSplit' {
            $memKb = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value ([int64]$memKb) -Force
        }
        'StoreSearchBlock' {
            $db = "$env:LocalAppData\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db"
            if (Test-Path -LiteralPath $db) { & icacls.exe $db /deny 'Everyone:F' | Out-Null }
        }
        'ExplorerDiscovery' {
            foreach ($p in @(
                'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags',
                'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
            )) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
            $allFolders = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
            New-Item -Path $allFolders -Force | Out-Null
            New-ItemProperty -Path $allFolders -Name 'FolderType' -Value 'NotSpecified' -PropertyType String -Force | Out-Null
        }
        'DiskCleanup' {
            & cleanmgr.exe /d $env:SystemDrive /VERYLOWDISK | Out-Null
            & Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
        }
        'DeleteTemp' {
            Remove-Item -Path "$env:Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        'RemoveEdge' {
            $setup = Resolve-Path -Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($setup) {
                New-Item -Path "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force -ErrorAction SilentlyContinue | Out-Null
                Start-Process -FilePath $setup.Path -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' -Wait
            } else { Add-GwtLog 'Microsoft Edge não encontrado.' 'Warn' }
        }
        'RemoveOneDrive' {
            $setup = "$env:SystemRoot\System32\OneDriveSetup.exe"
            if (-not (Test-Path $setup)) { $setup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" }
            if (Test-Path $setup) {
                Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait
                Set-Service -Name OneSyncSvc -StartupType Disabled -ErrorAction SilentlyContinue
            } else { Add-GwtLog 'Instalador do OneDrive não encontrado.' 'Warn' }
        }
        'WindowsAI' {
            Get-AppxPackage -AllUsers '*Copilot*' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            try { Set-Service -Name WSAIFabricSvc -StartupType Disabled -ErrorAction Stop } catch { }
            try { Disable-WindowsOptionalFeature -FeatureName 'Recall' -Online -NoRestart -ErrorAction Stop | Out-Null } catch { }
        }
        'VisualFxMask' {
            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'UserPreferencesMask' -Type Binary -Value ([byte[]](144, 18, 3, 128, 16, 0, 0, 0)) -Force
        }
        'ReservedStorage' { & DISM.exe /Online /Set-ReservedStorageState /State:Disabled | Out-Null }
        'Teredo'          { & netsh.exe interface teredo set state disabled | Out-Null }
        'DisableIPv6'     { Disable-NetAdapterBinding -Name '*' -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue }
        'RazerBlock' {
            $razer = "$env:SystemRoot\Installer\Razer"
            if (Test-Path $razer) { Remove-Item "$razer\*" -Recurse -Force -ErrorAction SilentlyContinue }
            else { New-Item -Path $razer -ItemType Directory -Force | Out-Null }
            & icacls.exe $razer /deny 'Everyone:(W)' | Out-Null
        }
    }
}

function Invoke-GwtOpData {
    param([string]$Key)

    $op = $sync.OpData[$Key]
    if (-not $op) { Add-GwtLog "Operação '$Key' não encontrada." 'Warn'; return }

    if ($op.ContainsKey('Reg')) {
        foreach ($r in $op.Reg) { Set-GwtRegistryEntry -Path $r.P -Name $r.N -Value $r.V -Type $r.T }
    }
    if ($op.ContainsKey('Svc')) {
        foreach ($s in $op.Svc) {
            try { Set-GwtServiceStartup -Name $s.N -Startup $s.S }
            catch { Add-GwtLog "Serviço $($s.N): $($_.Exception.Message)" 'Warn' }
        }
    }
    if ($op.ContainsKey('Special')) { Invoke-GwtOpSpecial -Special $op.Special }
}

function Invoke-GwtApplyKeysWorker {
    param([string[]]$Keys, [string]$Title, [string]$BackupName)

    try {
        $sync.Busy = $true
        $sync.StatusText = "Aplicando: $Title..."
        Add-GwtLog "================ $($Title.ToUpper()) ================"

        $backupKeys = @(
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Search',
            'HKCU\Control Panel\Desktop',
            'HKCU\Control Panel\Mouse',
            'HKLM\SOFTWARE\Policies\Microsoft\Windows\System',
            'HKLM\SOFTWARE\Policies\Microsoft\Edge',
            'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        )
        $backup = Backup-GwtRegistrySet -Name $BackupName -Keys $backupKeys
        Add-GwtLog "Backup criado em: $backup" 'Success'

        $needExplorer = $false
        $failed = 0
        foreach ($key in $Keys) {
            try {
                Invoke-GwtOpData -Key $key
                if ($sync.OpData[$key] -and $sync.OpData[$key].ContainsKey('Explorer')) { $needExplorer = $true }
                Add-GwtLog "${key}: aplicado." 'Success'
            }
            catch {
                $failed++
                Add-GwtLog "${key}: falhou — $($_.Exception.Message)" 'Error'
            }
        }

        Add-GwtLog "$Title concluído ($($Keys.Count - $failed) ok, $failed falha(s))." $(if ($failed -eq 0) { 'Success' } else { 'Warn' })
        if ($needExplorer) { Request-GwtUi @{ Action = 'AskExplorerRestart' } }
        else { Request-GwtUi @{ Action = 'Message'; Title = $Title; Kind = $(if ($failed -eq 0) { 'Info' } else { 'Warning' })
                               Text = "Concluído.`nAplicados: $($Keys.Count - $failed)`nFalhas: $failed" } }
    }
    catch {
        Add-GwtLog "Falha em '$Title': $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtDebloatWorker {
    param([object[]]$Packages)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]$Packages.Count
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ REMOÇÃO DE APPS DA STORE ($($Packages.Count)) ================"

        $ok = 0; $index = 0
        foreach ($pkg in $Packages) {
            $index++
            $sync.StatusText = "Removendo $($pkg.Name)..."
            try {
                Get-AppxPackage -AllUsers -Name $pkg.Id -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq $pkg.Id } |
                    Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                Add-GwtLog "$($pkg.Name): removido (ou já ausente)." 'Success'
                $ok++
            }
            catch { Add-GwtLog "$($pkg.Name): $($_.Exception.Message)" 'Warn' }
            $sync.ProgressValue = [double]$index
        }

        Add-GwtLog "Remoção concluída ($ok de $($Packages.Count))." 'Success'
        Request-GwtUi @{ Action = 'Message'; Title = 'Apps removidos'; Kind = 'Info'
                         Text = "Processados: $($Packages.Count)`n`nSe algum app não sumiu na hora, reinicie o Explorer ou faça logoff." }
    }
    catch {
        Add-GwtLog "Falha na remoção: $($_.Exception.Message)" 'Error'
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtFeatureWorker {
    param([object[]]$Features)

    try {
        $sync.Busy = $true
        Add-GwtLog "================ RECURSOS DO WINDOWS ================"
        $failed = 0
        foreach ($feat in $Features) {
            $sync.StatusText = "Ativando $($feat.Name)..."
            Add-GwtLog "▶ $($feat.Name)"
            try {
                foreach ($fn in $feat.Features) {
                    Enable-WindowsOptionalFeature -Online -FeatureName $fn -All -NoRestart -ErrorAction Stop | Out-Null
                }
                if ($feat.PSObject.Properties.Name -contains 'Special' -and $feat.Special) {
                    Invoke-GwtFeatureSpecial -Special $feat.Special
                }
                Add-GwtLog "$($feat.Name): ativado." 'Success'
            }
            catch {
                $failed++
                Add-GwtLog "$($feat.Name): $($_.Exception.Message)" 'Error'
            }
        }
        Add-GwtLog "Recursos concluídos ($($Features.Count - $failed) ok, $failed falha(s))." $(if ($failed -eq 0) { 'Success' } else { 'Warn' })
        Request-GwtUi @{ Action = 'AskReboot' }
    }
    catch { Add-GwtLog "Falha nos recursos: $($_.Exception.Message)" 'Error' }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtFeatureSpecial {
    param([string]$Special)

    switch ($Special) {
        'NFS' {
            & nfsadmin.exe client stop 2>&1 | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ClientForNFS\CurrentVersion\Default' -Name 'AnonymousUID' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ClientForNFS\CurrentVersion\Default' -Name 'AnonymousGID' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
            & nfsadmin.exe client start 2>&1 | Out-Null
        }
        'RegBackup' {
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force | Out-Null
            $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn "\Microsoft\Windows\Registry\RegIdleBackup"'
            $trigger = New-ScheduledTaskTrigger -Daily -At 00:30
            Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'GeniusRegBackup' -Description 'Backup diário do registro' -User 'System' -Force | Out-Null
        }
        'LegacyF8' { & bcdedit.exe /set '{current}' bootmenupolicy legacy | Out-Null }
        'SSHServer' {
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null
            Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name sshd -ErrorAction SilentlyContinue
            if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
            }
            Add-GwtLog 'Servidor OpenSSH ativo (serviço sshd automático, porta 22 liberada no firewall).' 'Success'
        }
    }
}

function Invoke-GwtFixWorker {
    param([string]$Fix)

    try {
        $sync.Busy = $true
        switch ($Fix) {
            'SystemRepair' {
                $sync.StatusText = 'Reparo do sistema (DISM + SFC)...'
                Add-GwtLog '================ REPARO DO SISTEMA ================'
                Invoke-GwtNativeCommand -FilePath 'DISM.exe' -Arguments @('/Online', '/Cleanup-Image', '/RestoreHealth') -Description 'DISM RestoreHealth' | Out-Null
                Invoke-GwtNativeCommand -FilePath 'sfc.exe' -Arguments @('/scannow') -Description 'SFC scannow' | Out-Null
                Add-GwtLog 'Reparo do sistema concluído.' 'Success'
            }
            'UpdateReset' {
                $sync.StatusText = 'Resetando o Windows Update...'
                Add-GwtLog '================ RESET DO WINDOWS UPDATE ================'
                foreach ($svc in 'wuauserv', 'bits', 'cryptsvc') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
                $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                foreach ($dir in @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")) {
                    if (Test-Path $dir) { try { Rename-Item -LiteralPath $dir -NewName "$(Split-Path $dir -Leaf).old-$stamp" -Force } catch { Add-GwtLog "Não foi possível renomear $dir" 'Warn' } }
                }
                foreach ($svc in 'cryptsvc', 'bits', 'wuauserv') { Start-Service -Name $svc -ErrorAction SilentlyContinue }
                Add-GwtLog 'Windows Update resetado. Reinício recomendado.' 'Success'
            }
            'WingetFix' {
                $sync.StatusText = 'Reinstalando o winget (App Installer)...'
                Add-GwtLog '================ REINSTALAR WINGET ================'
                try {
                    Get-AppxPackage -AllUsers 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
                        ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }
                    Add-GwtLog 'App Installer reregistrado. Se persistir, atualize pela Microsoft Store.' 'Success'
                } catch { Add-GwtLog "Não foi possível reregistrar: $($_.Exception.Message). Atualize o App Installer pela Store." 'Warn' }
            }
            'NtpFix' {
                $sync.StatusText = 'Ajustando servidor de horário (NTP)...'
                Add-GwtLog '================ SERVIDOR NTP ================'
                & w32tm.exe /config /manualpeerlist:'pool.ntp.org' /syncfromflags:manual /update | Out-Null
                Restart-Service w32time -ErrorAction SilentlyContinue
                & w32tm.exe /resync | Out-Null
                Add-GwtLog 'Servidor NTP ajustado para pool.ntp.org.' 'Success'
            }
        }
        Request-GwtUi @{ Action = 'Message'; Title = 'Correção concluída'; Kind = 'Info'; Text = 'A rotina foi finalizada. Veja o log para detalhes.' }
    }
    catch { Add-GwtLog "Falha na correção: $($_.Exception.Message)" 'Error' }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtDnsWorker {
    param([string]$Provider, $Servers)

    try {
        $sync.Busy = $true
        Add-GwtLog "================ DNS: $Provider ================"
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
        if (-not $adapters) { $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }

        foreach ($adapter in $adapters) {
            if ($null -eq $Servers) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                Add-GwtLog "$($adapter.Name): DNS voltou ao automático (DHCP)." 'Success'
            }
            else {
                $all = @($Servers.V4) + @($Servers.V6)
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $all -ErrorAction Stop
                Add-GwtLog "$($adapter.Name): DNS -> $($Servers.V4 -join ', ')." 'Success'
            }
        }
        & ipconfig.exe /flushdns | Out-Null
        Add-GwtLog 'DNS aplicado e cache limpo.' 'Success'
    }
    catch { Add-GwtLog "Falha ao aplicar DNS: $($_.Exception.Message)" 'Error' }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtPerfWorker {
    param([string]$Mode)

    try {
        $sync.Busy = $true
        $guid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'  # Ultimate Performance
        if ($Mode -eq 'Enable') {
            Add-GwtLog 'Ativando plano de energia Desempenho Máximo...'
            & powercfg.exe -duplicatescheme $guid | Out-Null
            & powercfg.exe /setactive $guid | Out-Null
            Add-GwtLog 'Plano Desempenho Máximo ativado.' 'Success'
        }
        else {
            Add-GwtLog 'Removendo plano Desempenho Máximo...'
            & powercfg.exe -delete $guid | Out-Null
            Add-GwtLog 'Plano removido. Voltando ao Equilibrado.' 'Success'
            & powercfg.exe /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' | Out-Null
        }
    }
    catch { Add-GwtLog "Falha no plano de energia: $($_.Exception.Message)" 'Error' }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

# ============================================================================
# Criar ISO (MicroWin) — monta uma ISO do Windows, enxuga o install.wim e recria.
# ============================================================================

function Set-GwtOfflineReg {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value)
    & reg.exe add $Path /v $Name /t $Type /d $Value /f 2>&1 | Out-Null
}

function Get-GwtAutounattendXml {
    param([string]$AccountName = 'Usuario')

    # autounattend.xml enxuto: pula todo o OOBE, cria conta local Administrador
    # SEM senha (o técnico define depois) e configura locale pt-BR.
    $safe = ($AccountName -replace '[^A-Za-z0-9_. -]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Usuario' }

    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0416:00010416</InputLocale>
      <SystemLocale>pt-BR</SystemLocale>
      <UILanguage>pt-BR</UILanguage>
      <UserLocale>pt-BR</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Home</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>E. South America Standard Time</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$safe</Name>
            <DisplayName>$safe</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value></Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function Invoke-GwtIsoUsbWorker {
    param([int]$DiskNumber, [string]$ContentsDir)

    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]100
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ CRIAR ISO: gravar no pendrive (Disco $DiskNumber) ================"

        # 1. Limpar o disco
        $sync.StatusText = 'Limpando o pendrive...'
        $sync.ProgressValue = [double]10
        Add-GwtLog "Limpando o Disco $DiskNumber (diskpart clean)..."
        $dp = Join-Path $env:TEMP "gwt_dp_$(Get-Random).txt"
        "select disk $DiskNumber`r`nclean`r`nexit" | Set-Content -Path $dp -Encoding ASCII
        & diskpart.exe /s $dp 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { Add-GwtLog "  diskpart: $($_.Trim())" }
        Remove-Item $dp -Force -ErrorAction SilentlyContinue

        # 2. Inicializar como GPT
        Start-Sleep -Seconds 2
        Update-Disk -Number $DiskNumber
        $disk = Get-Disk -Number $DiskNumber
        if ($disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle GPT }
        else { Set-Disk -Number $DiskNumber -PartitionStyle GPT }
        Add-GwtLog "Disco inicializado como GPT." 'Success'

        # 3. Criar partição FAT32 (limitada a 32 GB, exigência do FAT32)
        $sync.StatusText = 'Criando partição...'
        $sync.ProgressValue = [double]22
        $label = 'GWT-' + (Get-Date).ToString('yyMMdd')
        $diskMB = [int][Math]::Floor((Get-Disk -Number $DiskNumber).Size / 1MB)
        $createCmd = if ($diskMB -gt 32768) { 'create partition primary size=32768' } else { 'create partition primary' }
        $dp2 = Join-Path $env:TEMP "gwt_dp2_$(Get-Random).txt"
        "select disk $DiskNumber`r`n$createCmd`r`nexit" | Set-Content -Path $dp2 -Encoding ASCII
        & diskpart.exe /s $dp2 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { Add-GwtLog "  diskpart: $($_.Trim())" }
        Remove-Item $dp2 -Force -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 3
        Update-Disk -Number $DiskNumber
        $part = Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Type -eq 'Basic' } | Select-Object -Last 1
        if (-not $part) { throw "Partição não encontrada no Disco $DiskNumber após a criação." }

        # 4. Formatar FAT32
        $sync.StatusText = 'Formatando FAT32...'
        $sync.ProgressValue = [double]30
        Add-GwtLog "Formatando como FAT32 (rótulo $label)..."
        Get-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber |
            Format-Volume -FileSystem FAT32 -NewFileSystemLabel $label -Force -Confirm:$false | Out-Null

        # 5. Atribuir letra
        Start-Sleep -Seconds 2
        Update-Disk -Number $DiskNumber
        $used = (Get-PSDrive -PSProvider FileSystem).Name
        $letter = $null
        foreach ($c in [char[]](68..90)) { if ($used -notcontains [string]$c) { $letter = [string]$c; break } }
        if (-not $letter) { throw 'Sem letras de unidade livres (D-Z).' }
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
        $usb = "${letter}:"
        for ($i = 0; $i -lt 6 -and -not (Test-Path $usb); $i++) { Start-Sleep -Seconds 2 }
        if (-not (Test-Path $usb)) { throw "A unidade $usb não ficou acessível." }
        Add-GwtLog "Pendrive em $usb" 'Success'

        # 6. Copiar (com split do install.wim > 3800 MB, limite do FAT32)
        $sync.StatusText = 'Copiando arquivos para o pendrive...'
        $sync.ProgressValue = [double]45
        $wim = Join-Path $ContentsDir 'sources\install.wim'
        if ((Test-Path $wim) -and ([math]::Round((Get-Item $wim).Length / 1MB) -gt 3800)) {
            Add-GwtLog 'install.wim > 4 GB: dividindo em install.swm para caber no FAT32...'
            New-Item -ItemType Directory -Path (Join-Path $usb 'sources') -Force | Out-Null
            Split-WindowsImage -ImagePath $wim -SplitImagePath (Join-Path $usb 'sources\install.swm') -FileSize 3800 | Out-Null
            Add-GwtLog 'Divisão concluída. Copiando o restante...'
            & robocopy.exe $ContentsDir $usb /E /XF install.wim /NFL /NDL /NJH /NJS /NP | Out-Null
        }
        else {
            & robocopy.exe $ContentsDir $usb /E /NFL /NDL /NJH /NJS /NP | Out-Null
        }

        $sync.ProgressValue = [double]100
        Add-GwtLog 'Pendrive pronto para boot e instalação.' 'Success'
        Request-GwtUi @{ Action = 'Message'; Title = 'Pendrive pronto'; Kind = 'Info'
                         Text = "Pendrive criado com sucesso em $usb`n`nJá pode dar boot por ele para instalar o Windows." }
    }
    catch {
        Add-GwtLog "Falha ao gravar no pendrive: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro no pendrive'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtIsoMountWorker {
    param([string]$IsoPath)

    try {
        $sync.Busy = $true
        $sync.StatusText = 'Montando a ISO...'
        Add-GwtLog "================ CRIAR ISO: montar e verificar ================"
        Add-GwtLog "ISO: $IsoPath"

        Mount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
        $letter = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $letter = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
            if ($letter) { break }
        }
        if (-not $letter) { throw 'Não foi possível obter a letra da unidade montada.' }
        $drive = "${letter}:"
        Add-GwtLog "Montada em $drive" 'Success'

        $wim = Join-Path $drive 'sources\install.wim'
        $esd = Join-Path $drive 'sources\install.esd'
        $active = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else { $null }
        if (-not $active) {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
            throw 'install.wim/install.esd não encontrado — não é uma ISO do Windows válida.'
        }

        $sync.StatusText = 'Lendo edições da imagem...'
        $editions = @(Get-WindowsImage -ImagePath $active | Select-Object ImageIndex, ImageName)
        Add-GwtLog "Edições encontradas: $($editions.Count)" 'Success'
        foreach ($e in $editions) { Add-GwtLog ("  [{0}] {1}" -f $e.ImageIndex, $e.ImageName) }

        $sync.IsoPath = $IsoPath
        $sync.IsoMountLetter = $drive
        $sync.IsoWimPath = $active
        $sync.IsoEditions = @($editions | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" })

        Request-GwtUi @{ Action = 'IsoEditions' }
    }
    catch {
        Add-GwtLog "Falha ao montar/verificar: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro na ISO'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtIsoApplyDebloat {
    param([string]$MountDir, [string]$IsoContents, [string]$EditionId)

    # 1. Remover AppX provisionados (bloatware)
    Add-GwtLog 'Removendo pacotes AppX provisionados...'
    $prefixes = @(
        'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingSearch', 'Microsoft.BingWeather',
        'Microsoft.GetHelp', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes', 'Microsoft.OutlookForWindows', 'Microsoft.PowerAutomateDesktop',
        'Microsoft.StartExperiencesApp', 'Microsoft.Todos', 'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsSoundRecorder', 'Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist', 'MSTeams'
    )
    $provisioned = & dism /English "/image:$MountDir" /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $Matches[1] } }
    foreach ($pkg in $provisioned) {
        if ($prefixes | Where-Object { $pkg -like "*$_*" }) {
            & dism /English "/image:$MountDir" /Remove-ProvisionedAppxPackage "/PackageName:$pkg" 2>&1 | Out-Null
            Add-GwtLog "  removido: $pkg"
        }
    }

    # 2. Tweaks offline via hives montadas
    Add-GwtLog 'Carregando hives offline do registro...'
    & reg.exe load 'HKLM\zDEFAULT' "$MountDir\Windows\System32\config\default" 2>&1 | Out-Null
    & reg.exe load 'HKLM\zNTUSER'  "$MountDir\Users\Default\ntuser.dat" 2>&1 | Out-Null
    & reg.exe load 'HKLM\zSOFTWARE' "$MountDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
    & reg.exe load 'HKLM\zSYSTEM'  "$MountDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null

    Add-GwtLog 'Aplicando bypass de requisitos (TPM/SecureBoot/CPU/RAM)...'
    $labconfig = 'HKLM\zSYSTEM\Setup\LabConfig'
    foreach ($n in 'BypassCPUCheck', 'BypassRAMCheck', 'BypassSecureBootCheck', 'BypassStorageCheck', 'BypassTPMCheck') {
        Set-GwtOfflineReg -Path $labconfig -Name $n -Type 'REG_DWORD' -Value '1'
    }
    Set-GwtOfflineReg -Path 'HKLM\zSYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'

    Add-GwtLog 'Desativando apps patrocinados e sugestões...'
    $cdm = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'SilentInstalledAppsEnabled',
                   'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'PreInstalledAppsEverEnabled',
                   'SoftLandingEnabled', 'SubscribedContentEnabled', 'SystemPaneSuggestionsEnabled') {
        Set-GwtOfflineReg -Path $cdm -Name $n -Type 'REG_DWORD' -Value '0'
    }
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent' -Type 'REG_DWORD' -Value '1'

    Add-GwtLog 'Permitindo conta local no OOBE...'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'BypassNRO' -Type 'REG_DWORD' -Value '1'

    Add-GwtLog 'Desativando telemetria...'
    Set-GwtOfflineReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' -Name 'Start' -Type 'REG_DWORD' -Value '4'

    Add-GwtLog 'Desativando Copilot, Chat e backup do OneDrive...'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' -Name 'ChatIcon' -Type 'REG_DWORD' -Value '3'
    Set-GwtOfflineReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type 'REG_DWORD' -Value '1'

    Add-GwtLog 'Desativando Armazenamento Reservado e criptografia automática...'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Type 'REG_DWORD' -Value '0'
    Set-GwtOfflineReg -Path 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' -Name 'PreventDeviceEncryption' -Type 'REG_DWORD' -Value '1'

    Add-GwtLog 'Impedindo instalação de Teams e novo Outlook...'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' -Name 'DisableInstallation' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Set-GwtOfflineReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'

    # NOTA DE SEGURANÇA: NÃO desativamos os serviços do Windows Update aqui.
    # Fazer isso deixaria a instalação sem atualizações; preferimos o WU funcional.

    Add-GwtLog 'Descarregando hives offline...'
    [gc]::Collect()
    foreach ($h in 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') {
        & reg.exe unload "HKLM\$h" 2>&1 | Out-Null
    }

    # 3. Apagar tarefas de telemetria/CEIP (não mexemos nas de Windows Update)
    Add-GwtLog 'Removendo tarefas agendadas de telemetria...'
    $tasks = "$MountDir\Windows\System32\Tasks\Microsoft\Windows"
    foreach ($t in @(
        'Application Experience\Microsoft Compatibility Appraiser',
        'Application Experience\ProgramDataUpdater',
        'Customer Experience Improvement Program',
        'Windows Error Reporting\QueueReporting'
    )) {
        $full = Join-Path $tasks $t
        if (Test-Path $full) { Remove-Item $full -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 4. ei.cfg para a edição escolhida (evita chave de produto embutida errada)
    if ($IsoContents -and $EditionId) {
        $sources = Join-Path $IsoContents 'sources'
        $eiCfg = "[EditionID]`r`n$EditionId`r`n[Channel]`r`nRetail`r`n[VL]`r`n0"
        Set-Content -Path (Join-Path $sources 'ei.cfg') -Value $eiCfg -Encoding ASCII -Force
        $pidFile = Join-Path $sources 'PID.txt'
        if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-GwtIsoModifyWorker {
    param([int]$Index, [string]$EditionName, [bool]$InjectDrivers, [bool]$SkipOobe, [string]$AccountName)

    $mountDir = $null
    try {
        $sync.Busy = $true
        $sync.ProgressMax = [double]100
        $sync.ProgressValue = [double]0
        Add-GwtLog "================ CRIAR ISO: modificar install.wim ================"
        Add-GwtLog "Edição: $EditionName (índice $Index)"

        $workDir = Join-Path $env:TEMP ("GeniusISO_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $isoContents = Join-Path $workDir 'iso_contents'
        $mountDir = Join-Path $workDir 'wim_mount'
        New-Item -ItemType Directory -Path $isoContents, $mountDir -Force | Out-Null

        $sync.StatusText = 'Copiando conteúdo da ISO...'
        $sync.ProgressValue = [double]8
        Add-GwtLog "Copiando ISO ($($sync.IsoMountLetter)) para a pasta de trabalho..."
        & robocopy.exe $sync.IsoMountLetter $isoContents /E /NFL /NDL /NJH /NJS /NP | Out-Null

        $leaf = Split-Path $sync.IsoWimPath -Leaf
        $localWim = Join-Path $isoContents "sources\$leaf"
        if (-not (Test-Path $localWim)) { throw "Imagem copiada não encontrada: sources\$leaf" }
        Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false

        # install.esd precisa virar install.wim exportando a edição escolhida
        if ($leaf -ieq 'install.esd') {
            $sync.StatusText = 'Convertendo install.esd para install.wim...'
            Add-GwtLog 'Convertendo install.esd para install.wim (edição escolhida)...'
            $newWim = Join-Path $isoContents 'sources\install.wim'
            Export-WindowsImage -SourceImagePath $localWim -SourceIndex $Index -DestinationImagePath $newWim -CompressionType Max | Out-Null
            Remove-Item $localWim -Force
            $localWim = $newWim
            $Index = 1
        }

        $sync.StatusText = 'Montando install.wim...'
        $sync.ProgressValue = [double]25
        Add-GwtLog "Montando install.wim (índice $Index)..."
        Mount-WindowsImage -ImagePath $localWim -Index $Index -Path $mountDir | Out-Null

        # EditionID a partir da imagem montada
        $editionId = ''
        $cur = & dism /English "/Image:$mountDir" /Get-CurrentEdition 2>&1
        foreach ($line in $cur) { if ($line -match 'Current Edition\s*:\s*(.+?)\s*$') { $editionId = $Matches[1].Trim(); break } }

        $sync.StatusText = 'Aplicando modificações...'
        $sync.ProgressValue = [double]45
        Invoke-GwtIsoApplyDebloat -MountDir $mountDir -IsoContents $isoContents -EditionId $editionId

        if ($SkipOobe) {
            Add-GwtLog "Gravando autounattend.xml (pula OOBE, conta local '$AccountName')..."
            Get-GwtAutounattendXml -AccountName $AccountName | Set-Content -Path (Join-Path $isoContents 'autounattend.xml') -Encoding UTF8 -Force
            Add-GwtLog 'autounattend.xml gravado na raiz da ISO.' 'Success'
        }

        if ($InjectDrivers) {
            $sync.StatusText = 'Injetando drivers do sistema atual...'
            Add-GwtLog 'Exportando e injetando drivers do sistema atual...'
            $drv = Join-Path $workDir 'drivers'
            New-Item -ItemType Directory -Path $drv -Force | Out-Null
            Export-WindowsDriver -Online -Destination $drv | Out-Null
            & dism /English "/image:$mountDir" /Add-Driver "/Driver:$drv" /Recurse 2>&1 | Out-Null
            Add-GwtLog 'Drivers injetados no install.wim.' 'Success'
        }

        $sync.StatusText = 'Limpando component store (WinSxS)...'
        $sync.ProgressValue = [double]58
        Add-GwtLog 'Limpando component store (/ResetBase)...'
        & dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null

        $sync.StatusText = 'Salvando install.wim (pode demorar)...'
        $sync.ProgressValue = [double]66
        Add-GwtLog 'Desmontando e salvando install.wim...'
        Dismount-WindowsImage -Path $mountDir -Save | Out-Null

        $sync.StatusText = 'Removendo edições não usadas...'
        $sync.ProgressValue = [double]78
        Add-GwtLog "Exportando somente a edição '$EditionName'..."
        $exportWim = Join-Path $isoContents 'sources\install_export.wim'
        Export-WindowsImage -SourceImagePath $localWim -SourceIndex $Index -DestinationImagePath $exportWim | Out-Null
        Remove-Item $localWim -Force
        Rename-Item $exportWim -NewName 'install.wim' -Force

        $sync.StatusText = 'Desmontando ISO de origem...'
        Add-GwtLog 'Desmontando a ISO de origem...'
        Dismount-DiskImage -ImagePath $sync.IsoPath -ErrorAction SilentlyContinue | Out-Null

        $sync.IsoWorkDir = $workDir
        $sync.IsoContentsDir = $isoContents
        $sync.IsoReady = $true
        $sync.ProgressValue = [double]100
        Add-GwtLog 'install.wim modificado com sucesso. Agora exporte a ISO final.' 'Success'
        Request-GwtUi @{ Action = 'IsoModified' }
    }
    catch {
        Add-GwtLog "Falha ao modificar: $($_.Exception.Message)" 'Error'
        # Limpeza defensiva
        try {
            if ($mountDir -and (Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir })) {
                Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
            }
        } catch { }
        try { Dismount-DiskImage -ImagePath $sync.IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { }
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro ao modificar'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.ProgressMax = [double]0
        $sync.StatusText = 'Pronto.'
    }
}

function Find-GwtOscdimg {
    $found = Get-ChildItem 'C:\Program Files (x86)\Windows Kits' -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) {
        $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                 Select-Object -First 1 -ExpandProperty FullName
    }
    return $found
}

function Invoke-GwtIsoExportWorker {
    param([string]$OutputPath)

    try {
        $sync.Busy = $true
        $sync.StatusText = 'Preparando exportação da ISO...'
        Add-GwtLog "================ CRIAR ISO: exportar ================"

        $oscdimg = Find-GwtOscdimg
        if (-not $oscdimg) {
            Add-GwtLog 'oscdimg.exe não encontrado. Instalando via winget (Microsoft.OSCDIMG)...' 'Warn'
            if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
                & winget.exe install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                $oscdimg = Find-GwtOscdimg
            }
        }
        if (-not $oscdimg) {
            throw 'oscdimg.exe não disponível. Instale com "winget install -e --id Microsoft.OSCDIMG" ou o Windows ADK.'
        }
        Add-GwtLog "oscdimg: $oscdimg" 'Success'

        $contents = $sync.IsoContentsDir
        $bootData = "2#p0,e,b`"$contents\boot\etfsboot.com`"#pEF,e,b`"$contents\efi\microsoft\boot\efisys.bin`""
        $oscArgs = @('-m', '-o', '-u2', '-udfver102', "-bootdata:$bootData", "$contents", "$OutputPath")

        $sync.StatusText = 'Gerando a ISO (oscdimg)...'
        Add-GwtLog 'Executando oscdimg...'
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $oscdimg
        $psi.Arguments = ($oscArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        [void]$proc.Start()
        while (-not $proc.StandardOutput.EndOfStream) {
            $l = $proc.StandardOutput.ReadLine()
            if ($l -and $l.Trim()) { Add-GwtLog $l.Trim() }
        }
        $proc.WaitForExit()

        if ($proc.ExitCode -eq 0) {
            Add-GwtLog "ISO gerada com sucesso: $OutputPath" 'Success'
            Request-GwtUi @{ Action = 'Message'; Title = 'ISO criada'; Kind = 'Info'
                             Text = "ISO gerada com sucesso!`n`n$OutputPath`n`nUse o Rufus ou o Criador de Mídia para gravar em pendrive." }
        }
        else {
            throw "oscdimg retornou código $($proc.ExitCode)."
        }
    }
    catch {
        Add-GwtLog "Falha ao exportar: $($_.Exception.Message)" 'Error'
        Request-GwtUi @{ Action = 'Message'; Title = 'Erro ao exportar'; Text = $_.Exception.Message; Kind = 'Error' }
    }
    finally {
        $sync.Busy = $false
        $sync.StatusText = 'Pronto.'
    }
}

function Invoke-GwtIsoCleanWorker {
    try {
        $sync.Busy = $true
        $sync.StatusText = 'Limpando trabalho da ISO...'
        Add-GwtLog 'Limpando pasta de trabalho da ISO...'

        if ($sync.IsoWorkDir -and (Test-Path $sync.IsoWorkDir)) {
            $mountDir = Join-Path $sync.IsoWorkDir 'wim_mount'
            try {
                $mounted = Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$($sync.IsoWorkDir)*" }
                foreach ($m in $mounted) { Dismount-WindowsImage -Path $m.Path -Discard | Out-Null }
            } catch { & dism /English /Cleanup-Wim 2>&1 | Out-Null }
            Remove-Item $sync.IsoWorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($sync.IsoPath) { try { Dismount-DiskImage -ImagePath $sync.IsoPath -ErrorAction SilentlyContinue | Out-Null } catch { } }

        $sync.IsoWorkDir = $null; $sync.IsoContentsDir = $null; $sync.IsoReady = $false
        $sync.IsoPath = $null; $sync.IsoMountLetter = $null; $sync.IsoWimPath = $null; $sync.IsoEditions = @()
        Add-GwtLog 'Limpeza concluída. Pronto para uma nova ISO.' 'Success'
        Request-GwtUi @{ Action = 'IsoReset' }
    }
    catch { Add-GwtLog "Falha na limpeza: $($_.Exception.Message)" 'Error' }
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
        Title="Genius Windows Toolkit — by Ricardo Valério S."
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
                <Image Name="TitleLogo" Height="24" Margin="0,0,10,0" VerticalAlignment="Center" Stretch="Uniform" Visibility="Collapsed"/>
                <TextBlock Name="TitleEmoji" Text="🧞" FontSize="20" VerticalAlignment="Center"/>
                <TextBlock Text="Genius Windows Toolkit" FontSize="15" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                <TextBlock Name="TitleVersionText" Text="v0.0.0" FontSize="12" Foreground="{StaticResource MutedBrush}" Margin="10,2,0,0" VerticalAlignment="Center"/>
                <Border Width="1" Height="16" Background="{StaticResource LineBrush}" Margin="12,0,12,0" VerticalAlignment="Center"/>
                <TextBlock Text="by Ricardo Valério S." FontSize="12" Foreground="{StaticResource GoldBrush}" FontWeight="SemiBold" VerticalAlignment="Center"/>
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
                        <Border Name="LogoPlate" Background="#F4F6F8" CornerRadius="12" Padding="14,12" Margin="0,0,0,14" Visibility="Collapsed">
                            <Image Name="LogoImage" Stretch="Uniform" MaxHeight="120" HorizontalAlignment="Center"/>
                        </Border>
                        <TextBlock Name="BrandKicker" Text="Ferramenta de bancada" Foreground="{StaticResource GoldBrush}" FontWeight="SemiBold" FontSize="12"/>
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

                            <StackPanel Grid.Row="2" Margin="0,12,0,0">
                                <WrapPanel>
                                    <Button Name="WingetInstallButton" Style="{StaticResource GoldButton}" Content="📦  Instalar selecionados" Margin="0,0,8,8"/>
                                    <Button Name="WingetUninstallButton" Style="{StaticResource GhostButton}" Content="🗑️  Desinstalar selecionados" Margin="0,0,8,8"/>
                                    <Button Name="WingetUpgradeButton" Style="{StaticResource GhostButton}" Content="⬆️  Atualizar tudo" Margin="0,0,8,8"/>
                                    <Button Name="WingetDetectButton" Style="{StaticResource GhostButton}" Content="🔍  Detectar instalados" Margin="0,0,8,8"/>
                                    <TextBlock Name="PackageCountText" Text="" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="4,0,0,8"/>
                                </WrapPanel>
                                <Border Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="10" Margin="0,2,0,0">
                                    <WrapPanel>
                                        <TextBlock Text="💾 Kit offline (pendrive):" Foreground="{StaticResource GoldBrush}" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                        <Button Name="KitDownloadButton" Style="{StaticResource GhostButton}" Content="⬇️  Baixar instaladores dos marcados" Margin="0,0,8,0"/>
                                        <Button Name="KitUpdateButton" Style="{StaticResource GhostButton}" Content="🔄  Verificar atualizações" Margin="0,0,8,0"/>
                                        <Button Name="KitInstallButton" Style="{StaticResource GoldButton}" Content="📥  Instalar do kit offline" Margin="0,0,8,0"/>
                                        <Button Name="KitOpenButton" Style="{StaticResource GhostButton}" Content="🗂️ Abrir pasta" Margin="0"/>
                                    </WrapPanel>
                                </Border>
                            </StackPanel>
                        </Grid>
                    </TabItem>

                    <TabItem Header="⚙️  Ajustes">
                        <Grid Margin="0,4,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource Card}" Padding="14" Margin="0,0,0,12">
                                <StackPanel>
                                    <TextBlock Text="Ajustes e preferências" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Preferências reversíveis de interface e sistema. Backup .reg é criado antes de aplicar; o Explorer reinicia ao final quando necessário." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Row="1" Style="{StaticResource Card}">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <WrapPanel Name="PreferencesList" Orientation="Vertical" ItemHeight="30" MaxHeight="99999"/>
                                </ScrollViewer>
                            </Border>
                            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
                                <Button Name="PreferencesApplyButton" Style="{StaticResource GoldButton}" Content="✨  Aplicar ajustes"/>
                                <Button Name="PreferencesNoneButton" Style="{StaticResource GhostButton}" Content="Limpar seleção" Margin="0"/>
                            </StackPanel>
                        </Grid>
                    </TabItem>

                    <TabItem Header="🧹  Privacidade">
                        <Grid Margin="0,4,0,0">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="14"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="*"/>
                                        </Grid.RowDefinitions>
                                        <StackPanel Grid.Row="0" Margin="0,0,0,8">
                                            <TextBlock Text="Privacidade e limpeza" FontSize="18" FontWeight="Bold"/>
                                            <TextBlock Text="Telemetria, rastreamento, bloat e ajustes de desempenho. Backup .reg antes de aplicar." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                        </StackPanel>
                                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                            <StackPanel Name="PrivacyList"/>
                                        </ScrollViewer>
                                    </Grid>
                                </Border>
                                <Border Grid.Column="2" Style="{StaticResource Card}">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="*"/>
                                        </Grid.RowDefinitions>
                                        <StackPanel Grid.Row="0" Margin="0,0,0,8">
                                            <TextBlock Text="Remover apps da Store" FontSize="18" FontWeight="Bold"/>
                                            <TextBlock Text="Desinstala apps pré-instalados do Windows para o usuário atual e novos usuários." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                        </StackPanel>
                                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                            <StackPanel Name="AppxList"/>
                                        </ScrollViewer>
                                    </Grid>
                                </Border>
                            </Grid>
                            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
                                <Button Name="PrivacyApplyButton" Style="{StaticResource GoldButton}" Content="🧹  Aplicar privacidade"/>
                                <Button Name="DebloatRemoveButton" Style="{StaticResource GoldButton}" Content="🗑️  Remover apps marcados"/>
                                <Button Name="PrivacyEssentialButton" Style="{StaticResource GhostButton}" Content="⭐ Só essenciais"/>
                                <Button Name="PrivacyNoneButton" Style="{StaticResource GhostButton}" Content="Limpar" Margin="0"/>
                                <TextBlock Text="Ações avançadas exigem cautela — leia a descrição de cada item." Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </Grid>
                    </TabItem>

                    <TabItem Header="🧩  Recursos">
                        <Grid Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
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
                                    <StackPanel Grid.Row="0" Margin="0,0,0,8">
                                        <TextBlock Text="Recursos do Windows" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Ativa recursos opcionais. Alguns pedem reinício." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                    </StackPanel>
                                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                        <StackPanel Name="FeatureList"/>
                                    </ScrollViewer>
                                    <Button Grid.Row="2" Name="FeatureInstallButton" Style="{StaticResource GoldButton}" Content="🧩  Ativar recursos marcados" Margin="0,12,0,0"/>
                                </Grid>
                            </Border>

                            <Border Grid.Column="2" Style="{StaticResource Card}">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <StackPanel>
                                        <TextBlock Text="Correções rápidas" FontSize="18" FontWeight="Bold" Margin="0,0,0,8"/>
                                        <WrapPanel>
                                            <Button Name="SystemRepairButton" Style="{StaticResource GhostButton}" Content="🩹 Reparar sistema (DISM+SFC)" Margin="0,0,8,8"/>
                                            <Button Name="UpdateResetButton" Style="{StaticResource GhostButton}" Content="♻️ Resetar Windows Update" Margin="0,0,8,8"/>
                                            <Button Name="WingetFixButton" Style="{StaticResource GhostButton}" Content="📦 Reinstalar winget" Margin="0,0,8,8"/>
                                            <Button Name="NtpFixButton" Style="{StaticResource GhostButton}" Content="🕒 Corrigir relógio (NTP)" Margin="0,0,8,8"/>
                                        </WrapPanel>

                                        <TextBlock Text="Política de Windows Update" FontSize="18" FontWeight="Bold" Margin="0,16,0,8"/>
                                        <WrapPanel>
                                            <Button Name="UpdateDefaultButton" Style="{StaticResource GhostButton}" Content="✅ Padrão" Margin="0,0,8,8" ToolTip="Restaura as configurações padrão do Windows Update."/>
                                            <Button Name="UpdateSecurityButton" Style="{StaticResource GhostButton}" Content="🛡️ Só segurança" Margin="0,0,8,8" ToolTip="Mantém correções de segurança, adia recursos por 1 ano, não reinicia com você logado."/>
                                            <Button Name="UpdateDisableButton" Style="{StaticResource GhostButton}" Content="⛔ Desativar" Margin="0,0,8,8" ToolTip="Desativa completamente o Windows Update (não recomendado a longo prazo)."/>
                                        </WrapPanel>

                                        <TextBlock Text="Servidor DNS" FontSize="18" FontWeight="Bold" Margin="0,16,0,8"/>
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Name="DnsCombo" Height="36" Margin="0,0,8,0"/>
                                            <Button Grid.Column="1" Name="DnsApplyButton" Style="{StaticResource GhostButton}" Content="Aplicar DNS" Margin="0"/>
                                        </Grid>

                                        <TextBlock Text="Plano de energia" FontSize="18" FontWeight="Bold" Margin="0,16,0,8"/>
                                        <WrapPanel>
                                            <Button Name="PerfEnableButton" Style="{StaticResource GhostButton}" Content="⚡ Desempenho Máximo" Margin="0,0,8,8"/>
                                            <Button Name="PerfDisableButton" Style="{StaticResource GhostButton}" Content="Remover plano" Margin="0,0,8,8"/>
                                        </WrapPanel>
                                        <TextBlock Text="Desempenho Máximo não é recomendado para notebooks." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,4"/>

                                        <TextBlock Text="Painéis clássicos do Windows" FontSize="18" FontWeight="Bold" Margin="0,16,0,8"/>
                                        <WrapPanel Name="LegacyPanelList"/>
                                    </StackPanel>
                                </ScrollViewer>
                            </Border>
                        </Grid>
                    </TabItem>

                    <TabItem Header="🪟  Criar ISO">
                        <Grid Margin="0,4,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="14"/>
                                <ColumnDefinition Width="380"/>
                            </Grid.ColumnDefinitions>

                            <Border Grid.Column="0" Style="{StaticResource Card}">
                                <ScrollViewer VerticalScrollBarVisibility="Auto">
                                    <StackPanel>
                                        <TextBlock Text="Criar uma ISO enxuta do Windows 11" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Monta uma ISO oficial, remove bloatware e telemetria, aplica bypass de requisitos (TPM/Secure Boot/CPU/RAM) e recria a imagem. Requer Administrador." Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" Margin="0,4,0,14"/>

                                        <Border Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="14" Margin="0,0,0,10">
                                            <StackPanel>
                                                <TextBlock Text="1 · Selecionar ISO" FontWeight="Bold" Margin="0,0,0,8"/>
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBox Name="IsoPathBox" IsReadOnly="True" VerticalContentAlignment="Center" Text="Nenhuma ISO selecionada..." Margin="0,0,8,0"/>
                                                    <Button Grid.Column="1" Name="IsoBrowseButton" Content="Procurar..." Margin="0"/>
                                                </Grid>
                                            </StackPanel>
                                        </Border>

                                        <Border Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="14" Margin="0,0,0,10">
                                            <StackPanel>
                                                <TextBlock Text="2 · Montar e verificar" FontWeight="Bold" Margin="0,0,0,8"/>
                                                <Button Name="IsoMountButton" Content="🔎  Montar e listar edições" HorizontalAlignment="Left"/>
                                                <TextBlock Text="Edição a manter na ISO final:" Foreground="{StaticResource MutedBrush}" Margin="0,10,0,4"/>
                                                <ComboBox Name="IsoEditionCombo" Height="36" IsEnabled="False"/>
                                            </StackPanel>
                                        </Border>

                                        <Border Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="14" Margin="0,0,0,10">
                                            <StackPanel>
                                                <TextBlock Text="3 · Modificar a imagem" FontWeight="Bold" Margin="0,0,0,8"/>
                                                <CheckBox Name="IsoInjectDriversCheck" Content="Injetar os drivers desta máquina na ISO" Margin="0,0,0,6"
                                                          ToolTip="Exporta os drivers do sistema atual e injeta no install.wim (útil para o mesmo modelo de máquina)."/>
                                                <CheckBox Name="IsoSkipOobeCheck" Content="Pular OOBE e criar conta local automática" Margin="0,0,0,6" IsChecked="True"
                                                          ToolTip="Gera um autounattend.xml que pula toda a configuração inicial e cria uma conta local Administrador (sem senha — defina depois)."/>
                                                <Grid Margin="0,0,0,10">
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="Auto"/>
                                                        <ColumnDefinition Width="*"/>
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock Text="Nome da conta:" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                    <TextBox Grid.Column="1" Name="IsoAccountBox" Text="Usuario" VerticalContentAlignment="Center"/>
                                                </Grid>
                                                <Button Name="IsoModifyButton" Style="{StaticResource GoldButton}" Content="🛠️  Modificar install.wim" HorizontalAlignment="Left" IsEnabled="False"/>
                                            </StackPanel>
                                        </Border>

                                        <Border Background="{StaticResource SoftBrush}" CornerRadius="10" Padding="14">
                                            <StackPanel>
                                                <TextBlock Text="4 · Gerar a saída" FontWeight="Bold" Margin="0,0,0,8"/>
                                                <TextBlock Text="Salvar como arquivo ISO:" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,4"/>
                                                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                                    <Button Name="IsoExportButton" Style="{StaticResource GoldButton}" Content="💿  Salvar ISO..." IsEnabled="False"/>
                                                    <Button Name="IsoCleanButton" Style="{StaticResource GhostButton}" Content="🧽  Limpar e recomeçar" Margin="0"/>
                                                </StackPanel>
                                                <TextBlock Text="Ou gravar direto em um pendrive (apaga tudo nele):" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,4"/>
                                                <Grid Margin="0,0,0,8">
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    <ComboBox Name="IsoUsbCombo" Height="36" Margin="0,0,8,0"/>
                                                    <Button Grid.Column="1" Name="IsoUsbRefreshButton" Style="{StaticResource GhostButton}" Content="🔄" Margin="0" ToolTip="Atualizar lista de pendrives"/>
                                                </Grid>
                                                <Button Name="IsoUsbWriteButton" Style="{StaticResource GoldButton}" Content="🔌  Gravar no pendrive" HorizontalAlignment="Left" IsEnabled="False"/>
                                            </StackPanel>
                                        </Border>
                                    </StackPanel>
                                </ScrollViewer>
                            </Border>

                            <Border Grid.Column="2" Style="{StaticResource Card}">
                                <StackPanel>
                                    <TextBlock Text="Como funciona" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>
                                    <TextBlock Foreground="{StaticResource MutedBrush}" TextWrapping="Wrap" LineHeight="21"><Run Text="• Use uma ISO oficial do Windows 11 (baixe pelo site da Microsoft)."/><LineBreak/><Run Text="• A imagem final remove apps pré-instalados (Teams, Copilot, Office Hub, Xbox, etc.), telemetria e sugestões, e permite conta local no OOBE."/><LineBreak/><Run Text="• O bypass de requisitos permite instalar em máquinas sem TPM 2.0/Secure Boot."/><LineBreak/><Run Text="• O processo leva vários minutos e usa bastante espaço em disco temporário (~10 GB) e o oscdimg (instalado via winget se faltar)."/></TextBlock>
                                    <Border Background="#2D2113" BorderBrush="{StaticResource GoldBrush}" BorderThickness="1" CornerRadius="10" Padding="14" Margin="0,16,0,0">
                                        <TextBlock Foreground="#FFE7B0" TextWrapping="Wrap" LineHeight="20"><Run Text="Diferente de outras ferramentas, o Windows Update continua funcional na ISO gerada — não desativamos os serviços de atualização. O acompanhamento aparece no log abaixo."/></TextBlock>
                                    </Border>
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

# Logo da marca: usa o base64 embutido (funciona via irm|iex) ou o arquivo local
# assets\genius-info-logo.png (ao lado do script, no pendrive). Sem logo, mostra o fallback.
function Show-GwtLogo {
    $bytes = $null
    if (-not [string]::IsNullOrWhiteSpace($LogoBase64)) {
        try { $bytes = [Convert]::FromBase64String($LogoBase64) } catch { $bytes = $null }
    }
    if (-not $bytes -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $localLogo = Join-Path (Split-Path -Parent $PSCommandPath) 'assets\genius-info-logo.png'
        if (Test-Path -LiteralPath $localLogo) { try { $bytes = [IO.File]::ReadAllBytes($localLogo) } catch { } }
    }
    if (-not $bytes) { return }

    try {
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.StreamSource = $ms
        $img.EndInit()
        $img.Freeze()

        $sync.Controls['LogoImage'].Source = $img
        $sync.Controls['LogoPlate'].Visibility = 'Visible'
        $sync.Controls['TitleLogo'].Source = $img
        $sync.Controls['TitleLogo'].Visibility = 'Visible'
        $sync.Controls['TitleEmoji'].Visibility = 'Collapsed'
        $sync.Controls['BrandKicker'].Visibility = 'Collapsed'
    }
    catch { }
}
Show-GwtLogo

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

# Adiciona um cabeçalho de categoria (texto dourado) a um painel.
function Add-GwtCategoryHeader {
    param([System.Windows.Controls.Panel]$Panel, [string]$Text, [string]$Margin = '0,8,24,4')
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontWeight = 'Bold'
    $label.FontSize = 13
    $label.Margin = $Margin
    $label.Foreground = $Window.Resources['GoldBrush']
    [void]$Panel.Children.Add($label)
}

# --- Ajustes (preferências, em grade por categoria) ---
$lastCategory = $null
foreach ($pref in $Preferences) {
    if ($pref.Cat -ne $lastCategory) {
        Add-GwtCategoryHeader -Panel $sync.Controls['PreferencesList'] -Text $pref.Cat
        $lastCategory = $pref.Cat
    }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $pref.Name
    $check.Tag = $pref.Key
    $check.IsChecked = [bool]$pref.Default
    $check.Margin = '0,2,24,2'
    [void]$sync.Controls['PreferencesList'].Children.Add($check)
}

# --- Privacidade (por categoria) ---
$lastCategory = $null
foreach ($tw in $PrivacyTweaks) {
    if ($tw.Cat -ne $lastCategory) {
        Add-GwtCategoryHeader -Panel $sync.Controls['PrivacyList'] -Text $tw.Cat -Margin '0,10,0,4'
        $lastCategory = $tw.Cat
    }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $tw.Name
    $check.Tag = $tw.Key
    $check.IsChecked = [bool]$tw.Default
    [void]$sync.Controls['PrivacyList'].Children.Add($check)
}

# --- Apps da Store (por categoria) ---
$lastCategory = $null
foreach ($app in $AppxDebloat) {
    if ($app.Cat -ne $lastCategory) {
        Add-GwtCategoryHeader -Panel $sync.Controls['AppxList'] -Text $app.Cat -Margin '0,10,0,4'
        $lastCategory = $app.Cat
    }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $app.Name
    $check.Tag = $app
    $check.ToolTip = $app.Id
    $check.IsChecked = [bool]$app.Default
    [void]$sync.Controls['AppxList'].Children.Add($check)
}

# --- Recursos do Windows ---
foreach ($feat in $WinFeatures) {
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $feat.Name
    $check.Tag = $feat
    $check.IsChecked = [bool]$feat.Default
    [void]$sync.Controls['FeatureList'].Children.Add($check)
}

# --- DNS ---
foreach ($name in $DnsProviders.Keys) {
    [void]$sync.Controls['DnsCombo'].Items.Add($name)
}
$sync.Controls['DnsCombo'].SelectedIndex = 0

# --- Painéis clássicos ---
foreach ($panelDef in $LegacyPanels) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $panelDef.Name
    $btn.Tag = $panelDef.Cmd
    $btn.Style = $Window.Resources['GhostButton']
    $btn.Margin = '0,0,8,8'
    $btn.Add_Click({ try { Start-Process $this.Tag } catch { Add-GwtLog "Não foi possível abrir: $($this.Tag)" 'Warn' } })
    [void]$sync.Controls['LegacyPanelList'].Children.Add($btn)
}

function Set-GwtPanelChecks {
    param([System.Windows.Controls.Panel]$Panel, [bool]$Checked)
    foreach ($child in $Panel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = $Checked }
    }
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

function Get-CheckedTags {
    param([System.Windows.Controls.Panel]$Panel, [string]$Property = $null)
    $vals = @()
    foreach ($child in $Panel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
            $vals += if ($Property) { [string]$child.Tag.$Property } else { [string]$child.Tag }
        }
    }
    return $vals
}

function Get-CurrentSelectionPreset {
    [pscustomobject]@{
        Version     = 2
        Tool        = 'GeniusWindowsToolkit'
        SavedAt     = (Get-Date).ToString('o')
        TargetDrive = Get-SelectedDrive
        Folders     = @((Get-SelectedFolderDefs).Key)
        Network     = @(Get-CheckedKeys -Panel $sync.Controls['NetworkList'])
        Preferences = @(Get-CheckedKeys -Panel $sync.Controls['PreferencesList'])
        Privacy     = @(Get-CheckedKeys -Panel $sync.Controls['PrivacyList'])
        RemoveApps  = @(Get-CheckedTags -Panel $sync.Controls['AppxList'] -Property 'Id')
        Features    = @(Get-CheckedTags -Panel $sync.Controls['FeatureList'] -Property 'Key')
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
    # 'Tweaks' (preset v1) e 'Preferences' (v2) apontam para a aba Ajustes.
    $prefList = if ($PresetData.PSObject.Properties.Name -contains 'Preferences') { $PresetData.Preferences }
                elseif ($PresetData.PSObject.Properties.Name -contains 'Tweaks') { $PresetData.Tweaks } else { $null }
    if ($null -ne $prefList) {
        foreach ($child in $sync.Controls['PreferencesList'].Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = (@($prefList) -contains [string]$child.Tag) }
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Privacy') {
        foreach ($child in $sync.Controls['PrivacyList'].Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = (@($PresetData.Privacy) -contains [string]$child.Tag) }
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'RemoveApps') {
        foreach ($child in $sync.Controls['AppxList'].Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = (@($PresetData.RemoveApps) -contains [string]$child.Tag.Id) }
        }
    }
    if ($PresetData.PSObject.Properties.Name -contains 'Features') {
        foreach ($child in $sync.Controls['FeatureList'].Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) { $child.IsChecked = (@($PresetData.Features) -contains [string]$child.Tag.Key) }
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

$sync.Controls['WingetUninstallButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'winget não foi encontrado nesta máquina.', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    $selected = Get-SelectedPackages
    if (-not $selected) { Add-GwtLog 'Nenhum programa marcado para desinstalar.' 'Warn'; return }
    if ([System.Windows.MessageBox]::Show($Window, "Desinstalar $($selected.Count) programa(s) marcado(s)? (Só remove os que estiverem instalados.)", 'Confirmar desinstalação', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($packages)
        Invoke-GwtWingetUninstallWorker -Selected $packages
    } -Argument $selected
})

$sync.Controls['WingetDetectButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'winget não foi encontrado nesta máquina.', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtDetectInstalledWorker }
})

# Pasta do kit offline: ao lado do app (pendrive) quando roda de arquivo; senão, pergunta.
function Get-GwtKitDir {
    param([bool]$MustExist = $false)
    $base = $null
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $base = Split-Path -Parent $PSCommandPath }
    if ($base) { return (Join-Path $base 'GeniusOfflineKit') }

    # Sem caminho de script (execução via irm|iex): pede a pasta
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = if ($MustExist) { 'Selecione a pasta GeniusOfflineKit (com o kit.json)' } else { 'Escolha onde salvar o kit offline (será criada a pasta GeniusOfflineKit)' }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    if ($MustExist -and (Test-Path (Join-Path $dlg.SelectedPath 'kit.json'))) { return $dlg.SelectedPath }
    return (Join-Path $dlg.SelectedPath 'GeniusOfflineKit')
}

$sync.Controls['KitDownloadButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'Baixar o kit exige o winget (e internet).', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    $selected = Get-SelectedPackages
    if (-not $selected) { Add-GwtLog 'Nenhum programa marcado para baixar.' 'Warn'; return }
    $kitDir = Get-GwtKitDir
    if (-not $kitDir) { return }
    if ([System.Windows.MessageBox]::Show($Window, "Baixar os instaladores de $($selected.Count) programa(s) para o kit offline?`n`nPasta: $kitDir`n`nDepois é só levar essa pasta no pendrive.", 'Baixar kit offline', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($arg)
        Invoke-GwtKitDownloadWorker -Selected $arg.Selected -KitDir $arg.KitDir
    } -Argument @{ Selected = $selected; KitDir = $kitDir }
})

$sync.Controls['KitInstallButton'].Add_Click({
    if ($sync.Busy) { return }
    $kitDir = Get-GwtKitDir -MustExist $true
    if (-not $kitDir) { return }
    if (-not (Test-Path (Join-Path $kitDir 'kit.json'))) {
        [System.Windows.MessageBox]::Show($Window, "Nenhum kit encontrado em:`n$kitDir`n`nBaixe um kit primeiro (com internet) ou aponte para a pasta GeniusOfflineKit do pendrive.", 'Kit não encontrado', 'OK', 'Warning') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, "Instalar todos os programas do kit offline?`n`nPasta: $kitDir", 'Instalar do kit offline', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($dir)
        Invoke-GwtKitInstallWorker -KitDir $dir
    } -Argument $kitDir
})

$sync.Controls['KitUpdateButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show($Window, 'Verificar atualizações exige o winget (e internet).', 'winget indisponível', 'OK', 'Warning') | Out-Null
        return
    }
    $kitDir = Get-GwtKitDir -MustExist $true
    if (-not $kitDir) { return }
    if (-not (Test-Path (Join-Path $kitDir 'kit.json'))) {
        [System.Windows.MessageBox]::Show($Window, "Nenhum kit encontrado em:`n$kitDir", 'Kit não encontrado', 'OK', 'Warning') | Out-Null
        return
    }
    Invoke-GwtRunspace -ScriptBlock {
        param($dir)
        Invoke-GwtKitCheckWorker -KitDir $dir
    } -Argument $kitDir
})

$sync.Controls['KitOpenButton'].Add_Click({
    $kitDir = Get-GwtKitDir
    if (-not $kitDir) { return }
    New-Item -ItemType Directory -Path $kitDir -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Process explorer.exe $kitDir
})

$sync.Controls['PackageDefaultButton'].Add_Click({ Set-PackageSelection -Mode Default })
$sync.Controls['PackageAllButton'].Add_Click({ Set-PackageSelection -Mode All })
$sync.Controls['PackageNoneButton'].Add_Click({ Set-PackageSelection -Mode None })
$sync.Controls['PackageSearchBox'].Add_TextChanged({ Update-PackageFilter })

$sync.Controls['PreferencesApplyButton'].Add_Click({
    if ($sync.Busy) { return }
    $selected = Get-CheckedKeys -Panel $sync.Controls['PreferencesList']
    if (-not $selected) { Add-GwtLog 'Nenhum ajuste selecionado.' 'Warn'; return }
    if ([System.Windows.MessageBox]::Show($Window, "Aplicar $($selected.Count) ajuste(s)? Um backup .reg será criado antes.", 'Confirmar ajustes', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($keys)
        Invoke-GwtApplyKeysWorker -Keys $keys -Title 'Ajustes do Windows' -BackupName 'preferences'
    } -Argument $selected
})
$sync.Controls['PreferencesNoneButton'].Add_Click({ Set-GwtPanelChecks -Panel $sync.Controls['PreferencesList'] -Checked $false })

$sync.Controls['PrivacyApplyButton'].Add_Click({
    if ($sync.Busy) { return }
    $selected = Get-CheckedKeys -Panel $sync.Controls['PrivacyList']
    if (-not $selected) { Add-GwtLog 'Nenhum item de privacidade selecionado.' 'Warn'; return }
    $advanced = @($selected | Where-Object { $sync.OpData[$_] -and $sync.OpData[$_].ContainsKey('Special') })
    $msg = "Aplicar $($selected.Count) item(ns) de privacidade/limpeza?`n`nUm backup .reg será criado antes. Alguns itens exigem Administrador e alguns são de ação avançada (remover Edge/OneDrive, IA, etc.).`n`nContinuar?"
    if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confirmar privacidade', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($keys)
        Invoke-GwtApplyKeysWorker -Keys $keys -Title 'Privacidade e limpeza' -BackupName 'privacy'
    } -Argument $selected
})

$sync.Controls['DebloatRemoveButton'].Add_Click({
    if ($sync.Busy) { return }
    $selected = @()
    foreach ($child in $sync.Controls['AppxList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) { $selected += $child.Tag }
    }
    if (-not $selected) { Add-GwtLog 'Nenhum app marcado para remoção.' 'Warn'; return }
    if ([System.Windows.MessageBox]::Show($Window, "Remover $($selected.Count) app(s) da Store para o usuário atual e novos usuários?", 'Confirmar remoção', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($packages)
        Invoke-GwtDebloatWorker -Packages $packages
    } -Argument $selected
})

$sync.Controls['PrivacyEssentialButton'].Add_Click({
    foreach ($child in $sync.Controls['PrivacyList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $def = $PrivacyTweaks | Where-Object { $_.Key -eq [string]$child.Tag }
            $child.IsChecked = ($def -and $def.Cat -eq 'Essencial')
        }
    }
})
$sync.Controls['PrivacyNoneButton'].Add_Click({
    Set-GwtPanelChecks -Panel $sync.Controls['PrivacyList'] -Checked $false
    Set-GwtPanelChecks -Panel $sync.Controls['AppxList'] -Checked $false
})

$sync.Controls['FeatureInstallButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'Ativar recursos do Windows exige Administrador. Use "Abrir como Administrador".', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    $selected = @()
    foreach ($child in $sync.Controls['FeatureList'].Children) {
        if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) { $selected += $child.Tag }
    }
    if (-not $selected) { Add-GwtLog 'Nenhum recurso selecionado.' 'Warn'; return }
    if ([System.Windows.MessageBox]::Show($Window, "Ativar $($selected.Count) recurso(s) do Windows? Pode exigir reinício.", 'Confirmar recursos', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($features)
        Invoke-GwtFeatureWorker -Features $features
    } -Argument $selected
})

function Start-GwtFix {
    param([string]$Fix, [string]$Label, [bool]$NeedAdmin = $true)
    if ($sync.Busy) { return }
    if ($NeedAdmin -and -not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, "$Label exige Administrador. Use ""Abrir como Administrador"".", 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, "Executar: $Label?", 'Confirmar', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($f)
        Invoke-GwtFixWorker -Fix $f
    } -Argument $Fix
}
$sync.Controls['SystemRepairButton'].Add_Click({ Start-GwtFix -Fix 'SystemRepair' -Label 'Reparo do sistema (DISM + SFC)' })
$sync.Controls['UpdateResetButton'].Add_Click({ Start-GwtFix -Fix 'UpdateReset' -Label 'Reset do Windows Update' })
$sync.Controls['WingetFixButton'].Add_Click({ Start-GwtFix -Fix 'WingetFix' -Label 'Reinstalar winget' })
$sync.Controls['NtpFixButton'].Add_Click({ Start-GwtFix -Fix 'NtpFix' -Label 'Corrigir relógio (NTP)' })

function Start-GwtUpdatePolicy {
    param([string]$Mode, [string]$Label, [string]$Icon = 'Question')
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'Alterar a política de Windows Update exige Administrador.', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show($Window, "Aplicar política de Windows Update: $Label?`n`nUm backup .reg é criado antes.", 'Windows Update', 'YesNo', $Icon) -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($m)
        Invoke-GwtUpdatePolicyWorker -Mode $m
    } -Argument $Mode
}
$sync.Controls['UpdateDefaultButton'].Add_Click({ Start-GwtUpdatePolicy -Mode 'Default' -Label 'Padrão (restaurar)' })
$sync.Controls['UpdateSecurityButton'].Add_Click({ Start-GwtUpdatePolicy -Mode 'Security' -Label 'Só segurança (recomendado)' })
$sync.Controls['UpdateDisableButton'].Add_Click({ Start-GwtUpdatePolicy -Mode 'Disable' -Label 'Desativar (não recomendado)' -Icon 'Warning' })

$sync.Controls['DnsApplyButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'Alterar DNS exige Administrador.', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    $name = [string]$sync.Controls['DnsCombo'].SelectedItem
    if (-not $name) { return }
    $servers = $DnsProviders[$name]
    Invoke-GwtRunspace -ScriptBlock {
        param($arg)
        Invoke-GwtDnsWorker -Provider $arg.Name -Servers $arg.Servers
    } -Argument @{ Name = $name; Servers = $servers }
})

$sync.Controls['PerfEnableButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) { [System.Windows.MessageBox]::Show($Window, 'Alterar plano de energia exige Administrador.', 'Administrador necessário', 'OK', 'Warning') | Out-Null; return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtPerfWorker -Mode 'Enable' }
})
$sync.Controls['PerfDisableButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) { [System.Windows.MessageBox]::Show($Window, 'Alterar plano de energia exige Administrador.', 'Administrador necessário', 'OK', 'Warning') | Out-Null; return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtPerfWorker -Mode 'Disable' }
})

$sync.Controls['DiagRunButton'].Add_Click({
    if ($sync.Busy) { return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtDiagnosticWorker }
})

# ---- Criar ISO (MicroWin) ----
$sync.Controls['IsoBrowseButton'].Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Selecione a ISO do Windows 11'
    $dialog.Filter = 'Imagens ISO (*.iso)|*.iso|Todos (*.*)|*.*'
    if ($dialog.ShowDialog($Window) -ne $true) { return }
    $sync.Controls['IsoPathBox'].Text = $dialog.FileName
    $sizeGb = [math]::Round((Get-Item $dialog.FileName).Length / 1GB, 2)
    Add-GwtLog "ISO selecionada: $($dialog.FileName) ($sizeGb GB)"
})

$sync.Controls['IsoMountButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'Criar ISO exige Administrador. Use "Abrir como Administrador".', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    $iso = $sync.Controls['IsoPathBox'].Text
    if (-not $iso -or $iso -eq 'Nenhuma ISO selecionada...' -or -not (Test-Path $iso)) {
        [System.Windows.MessageBox]::Show($Window, 'Selecione uma ISO válida primeiro.', 'ISO', 'OK', 'Warning') | Out-Null
        return
    }
    Invoke-GwtRunspace -ScriptBlock {
        param($p)
        Invoke-GwtIsoMountWorker -IsoPath $p
    } -Argument $iso
})

$sync.Controls['IsoModifyButton'].Add_Click({
    if ($sync.Busy) { return }
    $item = [string]$sync.Controls['IsoEditionCombo'].SelectedItem
    if (-not $item) { return }
    $index = 1
    if ($item -match '^(\d+):') { $index = [int]$Matches[1] }
    $name = ($item -replace '^\d+:\s*', '')
    $inject = [bool]$sync.Controls['IsoInjectDriversCheck'].IsChecked
    $skipOobe = [bool]$sync.Controls['IsoSkipOobeCheck'].IsChecked
    $account = [string]$sync.Controls['IsoAccountBox'].Text
    $msg = "Modificar a install.wim da edição:`n$name`n`nIsso copia a ISO (~5-6 GB), remove bloatware, aplica os ajustes e recria a imagem. Pode levar de 15 a 40 minutos e usa bastante disco temporário.`n`nContinuar?"
    if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confirmar modificação', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($arg)
        Invoke-GwtIsoModifyWorker -Index $arg.Index -EditionName $arg.Name -InjectDrivers $arg.Inject -SkipOobe $arg.SkipOobe -AccountName $arg.Account
    } -Argument @{ Index = $index; Name = $name; Inject = $inject; SkipOobe = $skipOobe; Account = $account }
})

$sync.Controls['IsoUsbRefreshButton'].Add_Click({
    $combo = $sync.Controls['IsoUsbCombo']
    $combo.Items.Clear()
    if (-not (Test-GwtAdmin)) {
        $combo.Items.Add('Requer Administrador') | Out-Null
        $combo.SelectedIndex = 0
        $sync.Controls['IsoUsbWriteButton'].IsEnabled = $false
        return
    }
    $disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Sort-Object Number)
    $sync.IsoUsbDisks = $disks
    if ($disks.Count -eq 0) {
        $combo.Items.Add('Nenhum pendrive detectado') | Out-Null
        $combo.SelectedIndex = 0
        $sync.Controls['IsoUsbWriteButton'].IsEnabled = $false
        Add-GwtLog 'Nenhum pendrive USB detectado.' 'Warn'
        return
    }
    foreach ($d in $disks) {
        $gb = [math]::Round($d.Size / 1GB, 1)
        [void]$combo.Items.Add("Disco $($d.Number): $($d.FriendlyName)  [$gb GB]")
    }
    $combo.SelectedIndex = 0
    $sync.Controls['IsoUsbWriteButton'].IsEnabled = $true
    Add-GwtLog "$($disks.Count) pendrive(s) encontrado(s)." 'Success'
})

$sync.Controls['IsoUsbWriteButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not (Test-GwtAdmin)) {
        [System.Windows.MessageBox]::Show($Window, 'Gravar em pendrive exige Administrador.', 'Administrador necessário', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $sync.IsoReady) {
        [System.Windows.MessageBox]::Show($Window, 'Modifique a imagem (passo 3) antes de gravar.', 'Ainda não pronto', 'OK', 'Warning') | Out-Null
        return
    }
    $idx = $sync.Controls['IsoUsbCombo'].SelectedIndex
    $disks = @($sync.IsoUsbDisks)
    if ($idx -lt 0 -or $idx -ge $disks.Count) {
        [System.Windows.MessageBox]::Show($Window, 'Selecione um pendrive na lista (clique em 🔄 para atualizar).', 'Pendrive', 'OK', 'Warning') | Out-Null
        return
    }
    $disk = $disks[$idx]
    $gb = [math]::Round($disk.Size / 1GB, 1)
    $msg = "TODOS os dados do Disco $($disk.Number) ($($disk.FriendlyName), $gb GB) serão APAGADOS PERMANENTEMENTE.`n`nTem certeza que deseja continuar?"
    if ([System.Windows.MessageBox]::Show($Window, $msg, 'Confirmar apagamento do pendrive', 'YesNo', 'Warning') -ne 'Yes') {
        Add-GwtLog 'Gravação em pendrive cancelada.' 'Warn'
        return
    }
    Invoke-GwtRunspace -ScriptBlock {
        param($arg)
        Invoke-GwtIsoUsbWorker -DiskNumber $arg.Disk -ContentsDir $arg.Dir
    } -Argument @{ Disk = [int]$disk.Number; Dir = $sync.IsoContentsDir }
})

$sync.Controls['IsoExportButton'].Add_Click({
    if ($sync.Busy) { return }
    if (-not $sync.IsoReady) {
        [System.Windows.MessageBox]::Show($Window, 'Modifique a imagem (passo 3) antes de exportar.', 'Ainda não pronto', 'OK', 'Warning') | Out-Null
        return
    }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Salvar a ISO modificada'
    $dialog.Filter = 'Imagens ISO (*.iso)|*.iso'
    $dialog.FileName = "Windows11_Genius_$(Get-Date -Format 'yyyyMMdd').iso"
    if ($dialog.ShowDialog($Window) -ne $true) { return }
    Invoke-GwtRunspace -ScriptBlock {
        param($out)
        Invoke-GwtIsoExportWorker -OutputPath $out
    } -Argument $dialog.FileName
})

$sync.Controls['IsoCleanButton'].Add_Click({
    if ($sync.Busy) { return }
    if ([System.Windows.MessageBox]::Show($Window, 'Descartar o trabalho atual da ISO e apagar a pasta temporária?', 'Limpar e recomeçar', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-GwtRunspace -ScriptBlock { Invoke-GwtIsoCleanWorker }
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
            $sync.Controls['MainTabs'].SelectedIndex = 7
        }
        'IsoEditions' {
            $combo = $sync.Controls['IsoEditionCombo']
            $combo.Items.Clear()
            foreach ($e in $sync.IsoEditions) { [void]$combo.Items.Add($e) }
            $proIdx = -1
            for ($i = 0; $i -lt $combo.Items.Count; $i++) {
                if ($combo.Items[$i] -match 'Windows 11 Pro(?![\w ])') { $proIdx = $i; break }
            }
            if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = [Math]::Max($proIdx, 0) }
            $combo.IsEnabled = $true
            $sync.Controls['IsoModifyButton'].IsEnabled = $true
        }
        'IsoModified' {
            $sync.Controls['IsoExportButton'].IsEnabled = $true
            if ($sync.Controls['IsoUsbCombo'].Items.Count -gt 0 -and $sync.IsoUsbDisks.Count -gt 0) {
                $sync.Controls['IsoUsbWriteButton'].IsEnabled = $true
            }
        }
        'KitUpdatesFound' {
            $updates = @($sync.KitUpdates)
            if ($updates.Count -eq 0) {
                [System.Windows.MessageBox]::Show($Window, 'Todos os instaladores do kit já estão na versão mais recente. ✔', 'Kit atualizado', 'OK', 'Information') | Out-Null
                break
            }
            $lines = ($updates | Select-Object -First 20 | ForEach-Object {
                $from = if ($_.From) { "v$($_.From)" } else { '?' }
                "• $($_.Name):  $from → v$($_.To)"
            }) -join "`n"
            if ($updates.Count -gt 20) { $lines += "`n… e mais $($updates.Count - 20)." }
            $msg = "$($updates.Count) programa(s) com atualização disponível:`n`n$lines`n`nBaixar e SUBSTITUIR os instaladores desatualizados no kit?"
            $script:DialogOpen = $true
            try {
                if ([System.Windows.MessageBox]::Show($Window, $msg, 'Atualizações do kit', 'YesNo', 'Question') -eq 'Yes') {
                    $dir = $sync.KitDir
                    Invoke-GwtRunspace -ScriptBlock {
                        param($arg)
                        Invoke-GwtKitUpdateWorker -KitDir $arg.Dir -Updates $arg.Updates
                    } -Argument @{ Dir = $dir; Updates = $updates }
                }
            }
            finally { $script:DialogOpen = $false }
        }
        'MarkInstalled' {
            $installed = $sync['DetectedInstalled']
            if (-not $installed) { return }
            $count = 0
            foreach ($child in $sync.Controls['PackageList'].Children) {
                if ($child -is [System.Windows.Controls.CheckBox]) {
                    $id = ([string]$child.Tag.Id)
                    if ($id -like 'msstore:*') { $id = $id.Substring(8) }
                    if ($installed.ContainsKey($id.ToLower())) { $child.IsChecked = $true; $count++ }
                }
            }
            Update-PackageCount
            Add-GwtLog "$count programa(s) do catálogo detectado(s) como instalado(s) e marcado(s)." 'Success'
        }
        'IsoReset' {
            $sync.Controls['IsoPathBox'].Text = 'Nenhuma ISO selecionada...'
            $sync.Controls['IsoEditionCombo'].Items.Clear()
            $sync.Controls['IsoEditionCombo'].IsEnabled = $false
            $sync.Controls['IsoModifyButton'].IsEnabled = $false
            $sync.Controls['IsoExportButton'].IsEnabled = $false
            $sync.Controls['IsoUsbWriteButton'].IsEnabled = $false
        }
    }
}

$ActionButtons = @('AnalyzeButton', 'MigrateButton', 'CopyOnlyButton', 'NetworkRunButton',
                   'WingetInstallButton', 'WingetUninstallButton', 'WingetUpgradeButton', 'WingetDetectButton',
                   'KitDownloadButton', 'KitInstallButton', 'KitUpdateButton',
                   'PreferencesApplyButton', 'PrivacyApplyButton', 'DebloatRemoveButton', 'FeatureInstallButton',
                   'SystemRepairButton', 'UpdateResetButton', 'WingetFixButton', 'NtpFixButton',
                   'UpdateDefaultButton', 'UpdateSecurityButton', 'UpdateDisableButton',
                   'DnsApplyButton', 'PerfEnableButton', 'PerfDisableButton', 'DiagRunButton',
                   'IsoMountButton', 'IsoModifyButton', 'IsoExportButton', 'IsoCleanButton', 'IsoUsbWriteButton')

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

# Detecção rápida de internet (para avisar sobre recursos que precisam de rede).
$sync.Online = $false
try {
    $req = [System.Net.WebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
    $req.Timeout = 1500
    $resp = $req.GetResponse(); $resp.Close(); $sync.Online = $true
}
catch { $sync.Online = $false }

if ($sync.Online) {
    Add-GwtLog 'Internet detectada — todos os recursos disponíveis.' 'Success'
}
else {
    Add-GwtLog 'Sem internet (modo offline). Funcionam normalmente: migração de pastas, rede, ajustes, privacidade, diagnóstico, e modificar/gravar uma ISO local.' 'Warn'
    Add-GwtLog 'Precisam de internet: instalar/atualizar programas (winget), baixar o oscdimg para exportar ISO, e ativar alguns recursos (.NET 3.5).' 'Warn'
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
    $required = @('MainTabs', 'DrivePanel', 'FolderList', 'NetworkList', 'PackageList',
                  'PreferencesList', 'PrivacyList', 'AppxList', 'FeatureList', 'DnsCombo',
                  'LegacyPanelList', 'IsoPathBox', 'IsoEditionCombo', 'IsoInjectDriversCheck',
                  'IsoSkipOobeCheck', 'IsoAccountBox', 'IsoUsbCombo', 'IsoUsbRefreshButton',
                  'KitOpenButton', 'LogBox', 'Progress', 'StatusText') + $ActionButtons
    foreach ($name in $required) {
        if (-not $sync.Controls.ContainsKey($name) -or $null -eq $sync.Controls[$name]) { $issues += $name }
    }
    # Toda operação em OpData precisa de dados válidos (Reg/Svc/Special).
    foreach ($k in $sync.OpData.Keys) {
        $op = $sync.OpData[$k]
        if (-not ($op.ContainsKey('Reg') -or $op.ContainsKey('Svc') -or $op.ContainsKey('Special'))) {
            $issues += "OpData:$k"
        }
    }
    # O autounattend.xml precisa ser XML válido.
    try { [xml](Get-GwtAutounattendXml -AccountName 'Teste') | Out-Null }
    catch { $issues += 'autounattend-xml-invalido' }
    if ($issues) {
        Write-Host "SMOKETEST FALHOU — problemas: $($issues -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host ("SMOKETEST OK — {0} controles, {1} pacotes, {2} pastas, {3} ações rede, {4} preferências, {5} privacidade, {6} apps, {7} recursos, {8} operações." -f `
        $sync.Controls.Count, $Packages.Count, $KnownFolders.Count, $NetworkActions.Count, `
        $Preferences.Count, $PrivacyTweaks.Count, $AppxDebloat.Count, $WinFeatures.Count, $sync.OpData.Count) -ForegroundColor Green
    exit 0
}

$UiTimer.Start()
[void]$Window.ShowDialog()

#endregion
