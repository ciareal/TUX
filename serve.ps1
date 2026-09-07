<#
  Static file server for the SuperTuxKart launcher, for Windows.

  The game is compiled with threads, so the browser only gives it
  SharedArrayBuffer on a cross-origin isolated page. That needs two response
  headers that no ordinary "open the file" route can supply:

      Cross-Origin-Opener-Policy: same-origin
      Cross-Origin-Embedder-Policy: require-corp

  This uses a raw TcpListener rather than HttpListener on purpose. HttpListener
  goes through HTTP.sys, which wants a URL reservation and can refuse to bind
  without an elevated prompt. A loopback socket never needs admin rights, so
  double-clicking START-GAME.bat just works.

  Written for Windows PowerShell 5.1, which ships with Windows, so it avoids
  newer syntax.
#>
[CmdletBinding()]
param(
  [int]$Port = 8000,
  [string]$Root = $PSScriptRoot,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

if (-not $Root) { $Root = (Get-Location).Path }
$Root = (Resolve-Path -LiteralPath $Root).Path

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".htm"  = "text/html; charset=utf-8"
  ".js"   = "text/javascript"
  ".mjs"  = "text/javascript"
  ".css"  = "text/css"
  ".json" = "application/json"
  ".wasm" = "application/wasm"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".ico"  = "image/x-icon"
  ".svg"  = "image/svg+xml"
  ".txt"      = "text/plain; charset=utf-8"
  ".manifest" = "text/plain; charset=utf-8"
}

function Get-ContentType {
  param([string]$Path)
  $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($mime.ContainsKey($ext)) { return $mime[$ext] }
  # The asset bundle parts are named data_low.tar.gz.00 and friends. They must
  # go out as opaque bytes: labelling them gzip would make the browser inflate
  # them on the way in, and the launcher does that itself.
  return "application/octet-stream"
}

function Send-Response {
  param(
    $Stream,
    [int]$Code,
    [string]$Reason,
    [string]$ContentType,
    [byte[]]$Body,
    [bool]$NoCache = $false,
    [bool]$HeadOnly = $false
  )
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("HTTP/1.1 " + $Code + " " + $Reason + "`r`n")
  [void]$sb.Append("Content-Type: " + $ContentType + "`r`n")
  [void]$sb.Append("Content-Length: " + $Body.Length + "`r`n")
  [void]$sb.Append("Cross-Origin-Opener-Policy: same-origin`r`n")
  [void]$sb.Append("Cross-Origin-Embedder-Policy: require-corp`r`n")
  [void]$sb.Append("Cross-Origin-Resource-Policy: same-origin`r`n")
  if ($NoCache) { [void]$sb.Append("Cache-Control: no-cache`r`n") }
  [void]$sb.Append("Connection: close`r`n`r`n")

  $head = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
  $Stream.Write($head, 0, $head.Length)
  if ((-not $HeadOnly) -and $Body.Length -gt 0) {
    $Stream.Write($Body, 0, $Body.Length)
  }
  $Stream.Flush()
}

function Resolve-Requested {
  param([string]$Target)

  # strip the query string, then percent-decode
  $path = $Target
  $q = $path.IndexOf("?")
  if ($q -ge 0) { $path = $path.Substring(0, $q) }
  try { $path = [System.Uri]::UnescapeDataString($path) } catch { }
  if ($path -eq "/" -or $path -eq "") { $path = "/index.html" }

  $relative = $path.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $relative))

  # never serve anything outside the folder this script sits in
  $rootPrefix = $Root
  if (-not $rootPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $rootPrefix += [System.IO.Path]::DirectorySeparatorChar
  }
  if (-not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  return $full
}

# Bind loopback, stepping forward if the port is taken.
$listener = $null
$bound = 0
for ($p = $Port; $p -lt ($Port + 25); $p++) {
  try {
    $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
    $candidate.Start()
    $listener = $candidate
    $bound = $p
    break
  } catch {
    if ($candidate) { try { $candidate.Stop() } catch { } }
  }
}
if (-not $listener) {
  Write-Host ""
  Write-Host "Could not open a port between $Port and $($Port + 24)." -ForegroundColor Red
  Write-Host "Close whatever is using them and try again."
  exit 1
}

$url = "http://localhost:$bound/"

if (-not (Test-Path -LiteralPath (Join-Path $Root "game"))) {
  Write-Host ""
  Write-Host "Warning: there is no 'game' folder here, so the page will report" -ForegroundColor Yellow
  Write-Host "the build as missing. See README.md." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  SuperTuxKart is being served from:" -ForegroundColor Green
Write-Host "  $url" -ForegroundColor White
Write-Host ""
Write-Host "  Leave this window open while you play."
Write-Host "  Close it, or press Ctrl+C, to stop."
Write-Host ""

if (-not $NoBrowser) {
  try { Start-Process $url | Out-Null } catch { Write-Host "  Open $url yourself." }
}

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $client.NoDelay = $true
      $stream = $client.GetStream()
      $stream.ReadTimeout = 15000

      # read up to the end of the request headers
      $text = New-Object System.Text.StringBuilder
      $buffer = New-Object byte[] 4096
      $deadline = [DateTime]::UtcNow.AddSeconds(15)
      while ($text.ToString().IndexOf("`r`n`r`n") -lt 0) {
        if ([DateTime]::UtcNow -gt $deadline) { break }
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        [void]$text.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read))
      }

      $request = $text.ToString()
      if ($request.Length -eq 0) { continue }

      $firstLine = $request.Split("`n")[0].Trim()
      $parts = $firstLine.Split(" ")
      if ($parts.Length -lt 2) { continue }
      $method = $parts[0].ToUpperInvariant()
      $target = $parts[1]

      if ($method -ne "GET" -and $method -ne "HEAD") {
        $body = [System.Text.Encoding]::UTF8.GetBytes("method not allowed")
        Send-Response $stream 405 "Method Not Allowed" "text/plain; charset=utf-8" $body $false $false
        continue
      }

      $file = Resolve-Requested $target
      $headOnly = ($method -eq "HEAD")

      if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $type = Get-ContentType $file
        $noCache = ($type -like "text/html*") -or ($type -like "application/json*")
        Send-Response $stream 200 "OK" $type $bytes $noCache $headOnly
      } else {
        $body = [System.Text.Encoding]::UTF8.GetBytes("404 not found")
        Send-Response $stream 404 "Not Found" "text/plain; charset=utf-8" $body $false $headOnly
      }
    } catch {
      # a dropped connection is normal; keep serving
    } finally {
      try { $client.Close() } catch { }
    }
  }
} finally {
  try { $listener.Stop() } catch { }
}
