param(
  [Parameter(Mandatory=$true)][string]$Ref,
  [Parameter(Mandatory=$true)][string]$Query
)
$ErrorActionPreference = 'Stop'
$token = (Get-Content "$PSScriptRoot\..\.mcp.json" -Raw | ConvertFrom-Json).mcpServers.supabase.env.SUPABASE_ACCESS_TOKEN
$body = @{ query = $Query } | ConvertTo-Json -Depth 3
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
  $resp = Invoke-WebRequest -Method Post `
    -Uri "https://api.supabase.com/v1/projects/$Ref/database/query" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $bytes
  [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
} catch {
  Write-Host "FAILED: $($_.Exception.Message)"
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
  else {
    $stream = $_.Exception.Response.GetResponseStream()
    if ($stream) { (New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)).ReadToEnd() | Write-Host }
  }
  exit 1
}
