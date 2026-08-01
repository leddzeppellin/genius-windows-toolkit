param([string]$Url = 'https://bit.ly/genius-toolkit')

# Segue redirecionamentos manualmente e mostra a cadeia, sem executar conteúdo.
$current = $Url
for ($i = 0; $i -lt 8; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $current -MaximumRedirection 0 -ErrorAction Stop
        Write-Host ("[{0}] {1}  ->  {2} (final)" -f $i, $current, $resp.StatusCode)
        break
    }
    catch {
        $r = $_.Exception.Response
        if ($null -eq $r) { Write-Host "Erro: $($_.Exception.Message)"; break }
        $code = [int]$r.StatusCode
        $loc = $r.Headers.Location
        Write-Host ("[{0}] {1}  ->  {2} {3}" -f $i, $current, $code, $loc)
        if (-not $loc) { break }
        $current = if ($loc -match '^https?://') { $loc } else { ([Uri]::new([Uri]$current, $loc)).AbsoluteUri }
    }
}
Write-Host ""
Write-Host "Destino final: $current"

# Confirma se o conteúdo final é o loader ASCII (get.ps1)
try {
    $body = Invoke-RestMethod -Uri $current
    $firstIsBom = ($body.Length -gt 0 -and $body[0] -eq [char]0xFEFF)
    $hasParam = $body -match '\$loaderUrl' -and $body -match 'Substring'
    Write-Host ("Começa com BOM? {0}" -f $firstIsBom)
    Write-Host ("Parece ser o get.ps1 (loader)? {0}" -f $hasParam)
}
catch { Write-Host "Não foi possível baixar o conteúdo final: $($_.Exception.Message)" }
