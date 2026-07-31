# Abre a janela real por alguns segundos, tira uma captura e fecha sozinha.
# Uso: powershell -File tools/test-render.ps1 [-Seconds 5] [-Shot caminho.png]
param(
    [int]$Seconds = 5,
    [string]$Shot = (Join-Path $PSScriptRoot 'render-test.png'),
    [int]$Tab = -1
)

$toolkit = Join-Path $PSScriptRoot '..\GeniusToolkit.ps1'
$content = [IO.File]::ReadAllText($toolkit, [Text.Encoding]::UTF8)

# Injeta um encerramento automático + captura logo antes do ShowDialog
$hook = @"
`$AutoCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
`$AutoCloseTimer.Interval = [TimeSpan]::FromSeconds($Seconds)
`$AutoCloseTimer.Add_Tick({
    `$AutoCloseTimer.Stop()
    try {
        `$Window.Topmost = `$true
        `$Window.Activate()
        # Deixa o WPF processar o layout/redesenho (Start-Sleep bloquearia a UI)
        for (`$i = 0; `$i -lt 12; `$i++) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
            [System.Threading.Thread]::Sleep(60)
        }
        Add-Type -AssemblyName System.Drawing, System.Windows.Forms
        `$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        `$bmp = New-Object System.Drawing.Bitmap `$bounds.Width, `$bounds.Height
        `$gfx = [System.Drawing.Graphics]::FromImage(`$bmp)
        `$gfx.CopyFromScreen(`$bounds.Location, [System.Drawing.Point]::Empty, `$bounds.Size)
        `$bmp.Save('$($Shot -replace "'","''")', [System.Drawing.Imaging.ImageFormat]::Png)
        `$gfx.Dispose(); `$bmp.Dispose()
        Write-Host 'CAPTURA SALVA'
    } catch { Write-Host "CAPTURA FALHOU: `$(`$_.Exception.Message)" }
    `$Window.Close()
})
`$AutoCloseTimer.Start()
if ($Tab -ge 0) { `$sync.Controls['MainTabs'].SelectedIndex = $Tab }
[void]`$Window.ShowDialog()
"@

$patched = $content.Replace('[void]$Window.ShowDialog()', $hook)
& ([scriptblock]::Create($patched))
Write-Host 'RENDER OK - janela abriu e fechou sem erros.'
