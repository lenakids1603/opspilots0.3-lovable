param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$File
)
$ErrorActionPreference = 'Stop'
$token = (Get-Content "$PSScriptRoot\..\.mcp.json" -Raw | ConvertFrom-Json).mcpServers.supabase.env.SUPABASE_ACCESS_TOKEN
$sql = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
$chunks = [regex]::Split($sql, '(?m)^-- @@SPLIT@@[^\r\n]*')
$i = 0
foreach ($chunk in $chunks) {
  $i++
  if ($chunk.Trim().Length -eq 0) { continue }
  $body = @{ query = $chunk } | ConvertTo-Json -Depth 3
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  Write-Host "--- chunk $i ($($bytes.Length) bytes) ---"
  try {
    $resp = Invoke-RestMethod -Method Post `
      -Uri "https://api.supabase.com/v1/projects/$Ref/database/query" `
      -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
      -Body $bytes
    Write-Host "OK: $($resp | ConvertTo-Json -Compress -Depth 5)"
  } catch {
    Write-Host "FAILED chunk ${i}: $($_.Exception.Message)"
    $stream = $_.Exception.Response.GetResponseStream()
    if ($stream) { (New-Object System.IO.StreamReader($stream)).ReadToEnd() | Write-Host }
    exit 1
  }
}
Write-Host "ALL CHUNKS APPLIED"
