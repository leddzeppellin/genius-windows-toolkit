# Abre a janela real por alguns segundos, tira uma captura e fecha sozinha.
# Uso: powershell -File tools/test-render.ps1 [-Seconds 5] [-Shot caminho.png]
param(
    [int]$Seconds = 5,
    [string]$Shot = (Join-Path $PSScriptRoot 'render-test.png')
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
[void]`$Window.ShowDialog()
"@

$patched = $content.Replace('[void]$Window.ShowDialog()', $hook)
& ([scriptblock]::Create($patched))
Write-Host 'RENDER OK - janela abriu e fechou sem erros.'
