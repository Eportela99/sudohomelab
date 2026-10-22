#Requires -Version 5.1
<#
  sudo homelab - Media Stack installer (Windows 11 / Windows Server 2019+)
  https://github.com/Eportela99/sudohomelab

  Native Windows apps, each running as a Windows service (WinSW), wired together
  exactly like the Ubuntu/TrueNAS/Proxmox versions:
    Jellyfin and/or Plex - qBittorrent and/or SABnzbd - Radarr - Sonarr - Prowlarr
    extras: Lidarr - Bazarr - Tdarr - and Seerr (built from source, set up last)

  Run in PowerShell (it asks for admin rights itself):
    irm https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/windows/media-stack.ps1 | iex
  With options:
    & ([scriptblock]::Create((irm <url>))) -Server jellyfin -Downloader qbittorrent -Yes
    & ([scriptblock]::Create((irm <url>))) -Uninstall [-Purge]

  This file must stay plain ASCII with no BOM: a BOM breaks `irm | iex`, and
  Windows PowerShell 5.1 would misread any non-ASCII text without one. The
  symbols are built from char codes ($Script:G) instead.
#>
[CmdletBinding()]
param(
  [ValidateSet('', 'jellyfin', 'plex', 'both')] [string]$Server = '',
  [string[]]$Downloader = @(),          # qbittorrent | sabnzbd | both (comma list accepted)
  [string[]]$Extras = @(),              # lidarr, bazarr, tdarr, seerr | none
  [string]$SubtitleLangs = '',
  [string]$DataDir = '',
  [string]$Username = '',
  [string]$Password = '',
  [ValidateSet('', 'sudohomelab', 'localsystem')] [string]$ServiceAccount = '',
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Script:Version   = '0.2.0-windows'
$Script:ScriptUrl = 'https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/windows/media-stack.ps1'
$Script:Root      = Join-Path $env:ProgramData 'sudohomelab'
$Script:Settings  = Join-Path $Script:Root 'media-stack'          # app settings (kept on uninstall)
$Script:ConfigDir = Join-Path $Script:Settings 'config'
$Script:AppsDir   = Join-Path $env:ProgramFiles 'sudohomelab'     # program files (removed on uninstall)
$Script:SvcDir    = Join-Path $Script:AppsDir 'services'
$Script:LogDir    = Join-Path $Script:Root 'logs'
$Script:LogFile   = Join-Path $Script:LogDir ("media-stack-windows-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$Script:SvcUser   = 'sudohomelab'
$Script:FwGroup   = 'sudo homelab media stack'
$Script:Secrets   = New-Object System.Collections.Generic.List[string]
$Script:Step      = 0
$Script:Steps     = 9
$Script:Started   = Get-Date
$Script:BoundParams = $PSBoundParameters
$Script:CurrentStep = ''; $Script:LastRun = ''; $Script:HostIp = ''; $Script:SabKey = ''; $Script:BazarrKey = ''; $Script:TdarrKey = ''
$Script:Removed = @(); $Script:GeneratedPass = $false; $Script:SeerrManual = $false; $Script:TdarrManual = $false; $Script:IsServer = $false
$Script:AppUser = ''; $Script:AppPass = ''; $Script:SvcPass = ''; $Script:Choice = $null

# Ports (host = what you open in the browser; the apps all run on this machine).
$Script:Ports = [ordered]@{
  jellyfin = 8096; plex = 32400; qbittorrent = 8080; torrent = 6881; sabnzbd = 8085
  radarr = 7878; sonarr = 8989; prowlarr = 9696; seerr = 5055; lidarr = 8686; bazarr = 6767; tdarr = 8265; tdarrsrv = 8266
}
$Script:FixedPorts = @('jellyfin', 'plex')   # these don't move on conflict

# Symbols are built from char codes so this file stays plain ASCII: no BOM needed,
# and `irm | iex` works (a BOM at the start of the text breaks Invoke-Expression).
$Script:G = @{
  Ok = [string][char]0x2713; Bad = [string][char]0x2717; Arrow = [string][char]0x203A; Bar = [string][char]0x2501
  Pipe = [string][char]0x2502; VBar = [string][char]0x2503; Top = [string][char]0x250F; Bottom = [string][char]0x2517
  Star = [string][char]0x2605; Prompt = [string][char]0x276F
}

# -- UI -----------------------------------------------------------------------
function Write-ShlLog([string]$m) {
  foreach ($s in $Script:Secrets) { if ($s -and $s.Length -ge 6) { $m = $m.Replace($s, '***') } }
  try { Add-Content -LiteralPath $Script:LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch { }
}
function Add-Secret([string]$s) { if ($s) { [void]$Script:Secrets.Add($s) } }
function Ok([string]$m)   { Write-Host "  $($G.Ok) " -ForegroundColor Green -NoNewline; Write-Host $m; Write-ShlLog "OK   $m" }
function Info([string]$m) { Write-Host "  $($G.Arrow) " -ForegroundColor Cyan -NoNewline; Write-Host $m; Write-ShlLog "INFO $m" }
function Warn([string]$m) { Write-Host '  ! ' -ForegroundColor Yellow -NoNewline; Write-Host $m; Write-ShlLog "WARN $m" }
function Err([string]$m)  { Write-Host "  $($G.Bad) " -ForegroundColor Red -NoNewline; Write-Host $m; Write-ShlLog "ERR  $m" }
function Die([string]$m)  { Err $m; Write-Host "`n  Full log: $Script:LogFile`n" -ForegroundColor DarkGray; throw "sudohomelab-abort" }
function Step([string]$t) {
  $Script:Step++; $Script:CurrentStep = $t
  Write-Host ''; Write-Host "$($G.Bar)$($G.Bar) " -ForegroundColor Magenta -NoNewline
  Write-Host ("[{0}/{1}] " -f $Script:Step, $Script:Steps) -ForegroundColor DarkGray -NoNewline
  Write-Host $t -ForegroundColor White
  Write-ShlLog "==== STEP $($Script:Step)/$($Script:Steps): $t"
}
function Show-Banner {
  Write-Host @'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
'@ -ForegroundColor Green
  Write-Host "    $($G.Prompt) " -ForegroundColor Green -NoNewline
  Write-Host 'Media Stack' -ForegroundColor White -NoNewline
  Write-Host " installer v$Script:Version - Windows`n" -ForegroundColor DarkGray
}

function Ask([string]$q, [string]$def = '') {
  if ($Yes) { return $def }
  Write-Host '  ? ' -ForegroundColor Magenta -NoNewline; Write-Host "$q " -NoNewline; Write-Host "[$def] " -ForegroundColor DarkGray -NoNewline
  $a = Read-Host
  if ([string]::IsNullOrWhiteSpace($a)) { return $def } else { return $a.Trim() }
}
function Ask-Secret([string]$q) {
  Write-Host '  ? ' -ForegroundColor Magenta -NoNewline; Write-Host "$q " -NoNewline
  $s = Read-Host -AsSecureString
  return [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
function Confirm-Yes([string]$q) { $a = Ask "$q (Y/n)" 'y'; return ($a -match '^(y|yes)$') }
function Menu([string]$title, [int]$def, [string[]]$options) {
  if ($Yes) { return $def }
  Write-Host "`n  $title" -ForegroundColor White
  for ($i = 0; $i -lt $options.Count; $i++) {
    $label, $desc = $options[$i] -split '\|', 2
    Write-Host ("    {0}) " -f ($i + 1)) -ForegroundColor Green -NoNewline
    Write-Host ("{0,-14} " -f $label) -NoNewline; Write-Host $desc -ForegroundColor DarkGray
  }
  while ($true) {
    Write-Host "  $($G.Arrow) " -ForegroundColor Cyan -NoNewline; Write-Host ("Choose [1-{0}] " -f $options.Count) -NoNewline
    Write-Host "(default $def): " -ForegroundColor DarkGray -NoNewline
    $c = Read-Host
    if ([string]::IsNullOrWhiteSpace($c)) { return $def }
    $n = 0
    if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $n }
    Write-Host "    Please enter a number between 1 and $($options.Count)." -ForegroundColor Yellow
  }
}

# Runs a script block, streams its output indented, logs everything, reports ok/failed.
function Run([string]$msg, [scriptblock]$block) {
  Write-Host "  $($G.Arrow) " -ForegroundColor Cyan -NoNewline; Write-Host $msg
  Write-ShlLog "RUN  $msg"
  try {
    & $block 2>&1 | ForEach-Object {
      $line = "$_"
      foreach ($s in $Script:Secrets) { if ($s -and $s.Length -ge 6) { $line = $line.Replace($s, '***') } }
      if ($line.Trim()) { Write-Host "    $($G.Pipe) $line" -ForegroundColor DarkGray; Write-ShlLog $line }
    }
    Ok $msg
  } catch {
    $Script:LastRun = $msg
    Err "$msg ($($_.Exception.Message))"
    throw
  }
}

# -- Helpers ------------------------------------------------------------------
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function New-Secret([int]$len = 16) {
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  $bytes = New-Object byte[] $len; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
function New-HexKey { $b = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) }
function Want([string]$app) {
  switch ($app) {
    'jellyfin'    { return ($Script:Choice.Server -in 'jellyfin', 'both') }
    'plex'        { return ($Script:Choice.Server -in 'plex', 'both') }
    'qbittorrent' { return ($Script:Choice.Downloader -in 'qbittorrent', 'both') }
    'sabnzbd'     { return ($Script:Choice.Downloader -in 'sabnzbd', 'both') }
    default       { return ($Script:Choice.Extras -contains $app) }
  }
}
function Get-HostIp {
  # The LAN address: the interface that holds the default route. VPNs like Tailscale
  # (100.64.0.0/10) often have a lower metric, so they're only a fallback.
  $all = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' })
  $gw = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object -Property RouteMetric | ForEach-Object { $_.InterfaceIndex })
  $lan = @($all | Where-Object { $_.IPAddress -notmatch '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' })
  foreach ($idx in $gw) { $hit = $lan | Where-Object { $_.InterfaceIndex -eq $idx } | Select-Object -First 1; if ($hit) { return $hit.IPAddress } }
  $pool = $all; if ($lan.Count) { $pool = $lan }
  $ip = $pool | Sort-Object -Property InterfaceMetric | Select-Object -First 1 -ExpandProperty IPAddress
  if ($ip) { $ip } else { 'localhost' }
}

function Save-File([string]$url, [string]$dest) {
  # A download can stall forever with the connection open: time out and retry instead of hanging.
  for ($try = 1; ; $try++) {
    try { Save-FileOnce $url $dest; return }
    catch {
      if ($try -ge 3) { throw }
      # Host + log, not output: callers like Get-WinSW return a value.
      $m = "Download problem ($($_.Exception.Message)), retrying ($($try + 1)/3)..."
      Write-Host "`n    $($G.Pipe) $m" -ForegroundColor Yellow; Write-ShlLog $m; Start-Sleep 5
    }
  }
}
function Save-FileOnce([string]$url, [string]$dest) {
  # Streams with a live percentage; Invoke-WebRequest's progress bar is very slow on PS 5.1.
  # Always HTTPS: some sites hand out http:// links (SourceForge), and filtering proxies can hold
  # plain-HTTP downloads indefinitely.
  $url = $url -replace '^http://', 'https://'
  $req = [Net.HttpWebRequest]::Create($url); $req.UserAgent = 'sudohomelab-installer'; $req.AllowAutoRedirect = $true
  $req.ReadWriteTimeout = 60000   # ms with no data arriving
  # .NET's own connect Timeout isn't reliable behind a proxy that holds the connection: enforce it here.
  $ar = $req.BeginGetResponse($null, $null)
  if (-not $ar.AsyncWaitHandle.WaitOne(60000)) { $req.Abort(); throw "no response from $(([uri]$url).Host) within 60s" }
  $res = $req.EndGetResponse($ar)
  try {
    $total = $res.ContentLength; $in = $res.GetResponseStream(); $out = [IO.File]::Create($dest)
    try {
      $buf = New-Object byte[] 1048576; $done = 0; $last = [DateTime]::MinValue
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n); $done += $n
        if (((Get-Date) - $last).TotalMilliseconds -gt 700) {
          $last = Get-Date
          if ($total -gt 0) { Write-Host ("`r    $($G.Pipe) {0,3}% of {1:N0} MB " -f [int](100 * $done / $total), ($total / 1MB)) -NoNewline -ForegroundColor DarkGray }
          else { Write-Host ("`r    $($G.Pipe) {0:N0} MB " -f ($done / 1MB)) -NoNewline -ForegroundColor DarkGray }
        }
      }
      Write-Host "`r    $($G.Pipe) done ($([Math]::Round($done / 1MB)) MB)      " -ForegroundColor DarkGray
    } finally { $out.Close(); $in.Close() }
  } finally { $res.Close() }
}
function Get-GitHubAsset([string]$repo, [string]$pattern) {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'sudohomelab' }
  $a = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
  if (-not $a) { throw "No asset matching '$pattern' in $repo $($rel.tag_name)" }
  [pscustomobject]@{ Url = $a.browser_download_url; Name = $a.name; Tag = $rel.tag_name; Tarball = $rel.tarball_url }
}
function Expand-To([string]$zip, [string]$dest) {
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
}
function Get-PortOwner([int]$port) {
  $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $c) { return $null }
  $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
  if ($p) { $p.ProcessName } else { "pid $($c.OwningProcess)" }
}
function Test-OurPort([int]$port) {
  # A port held by one of our own services (re-run) isn't a conflict.
  $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $c) { return $false }
  $svc = Get-CimInstance Win32_Service -Filter "ProcessId = $($c.OwningProcess)" -ErrorAction SilentlyContinue
  if ($svc -and ($svc.Name -like 'sudohomelab-*' -or $svc.Name -eq 'SABnzbd')) { return $true }
  $p = Get-CimInstance Win32_Process -Filter "ProcessId = $($c.OwningProcess)" -ErrorAction SilentlyContinue
  # Plex installs to its own folder and runs from our startup task, not a service.
  if ($p -and $p.Name -eq 'Plex Media Server.exe' -and (Get-ScheduledTask -TaskName 'sudohomelab-plex' -ErrorAction SilentlyContinue)) { return $true }
  return ($p -and $p.ExecutablePath -and $p.ExecutablePath.StartsWith($Script:AppsDir, 'OrdinalIgnoreCase'))
}
function Wait-Http([string]$name, [string]$url, [int]$timeout = 240, [hashtable]$headers = @{}) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeout) {
    try {
      $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
      Write-ShlLog "$name ready ($($r.StatusCode))"; return
    } catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -in 301, 302, 303, 307, 308, 401, 403) { Write-ShlLog "$name ready ($code)"; return }
      "$name is starting up... ($([int]$sw.Elapsed.TotalSeconds)s / ${timeout}s)"
      Start-Sleep -Seconds 2
    }
  }
  throw "$name didn't answer at $url within ${timeout}s"
}
function Api([string]$method, [string]$url, [string]$key, $body = $null) {
  $p = @{ Method = $method; Uri = $url; Headers = @{ 'X-Api-Key' = $key }; ContentType = 'application/json'; TimeoutSec = 60 }
  if ($null -ne $body) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 30 -Compress)) }
  # PS 5.1 returns a JSON array as ONE object (even []): unroll it so @() and pipelines see items.
  Invoke-RestMethod @p | ForEach-Object { $_ }
}
# Native programs: Windows PowerShell 5.1 turns any stderr line into a terminating
# error when ErrorActionPreference is Stop, so run them with Continue and judge by exit code.
function Exec([string]$file, [string[]]$arguments) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $file @arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $file -Leaf) $($arguments -join ' ') exited with $LASTEXITCODE" }
}
# Setup programs: a wrong silent flag makes them show a wizard nobody can see (over SSH,
# or as SYSTEM) and wait forever, so give up after a while instead of hanging the install.
function Invoke-Installer([string]$file, [string[]]$arguments, [int[]]$okCodes = @(0), [int]$minutes = 10) {
  $p = Start-Process $file -ArgumentList $arguments -PassThru
  if (-not $p.WaitForExit($minutes * 60000)) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $($p.Id)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw "$(Split-Path $file -Leaf) didn't finish within $minutes minutes (stopped it)"
  }
  if ($p.ExitCode -notin $okCodes) { throw "$(Split-Path $file -Leaf) failed (exit code $($p.ExitCode))" }
}
function Set-Prop($obj, [string]$name, $value) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

# -- Services (WinSW) ---------------------------------------------------------
function Get-WinSW {
  $exe = Join-Path $Script:SvcDir 'WinSW-x64.exe'
  if (-not (Test-Path $exe)) {
    New-Item -ItemType Directory -Force -Path $Script:SvcDir | Out-Null
    Save-File 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe' $exe
  }
  $exe
}
function Install-AppService([string]$id, [string]$name, [string]$exe, [string]$arguments, [string]$workdir, [hashtable]$envs = @{}) {
  $winsw = Get-WinSW
  $svcExe = Join-Path $Script:SvcDir "sudohomelab-$id.exe"; $xml = Join-Path $Script:SvcDir "sudohomelab-$id.xml"
  $existing = Get-Service -Name "sudohomelab-$id" -ErrorAction SilentlyContinue
  if ($existing) { if ($existing.Status -ne 'Stopped') { Stop-OurService "sudohomelab-$id" }; Exec $svcExe @('uninstall') | Out-Null }
  Copy-Item $winsw $svcExe -Force
  $envXml = ($envs.GetEnumerator() | ForEach-Object { "  <env name=`"$($_.Key)`" value=`"$([Security.SecurityElement]::Escape([string]$_.Value))`"/>" }) -join "`n"
  $account = ''
  if ($Script:Choice.Account -eq 'sudohomelab') {
    # WinSW 2.x syntax (<user>, optional <domain> = this PC); 3.x's <username> is silently ignored here.
    $account = "  <serviceaccount><user>$Script:SvcUser</user><password>$([Security.SecurityElement]::Escape($Script:SvcPass))</password><allowservicelogon>true</allowservicelogon></serviceaccount>"
  }
  @"
<service>
  <id>sudohomelab-$id</id>
  <name>sudo homelab - $name</name>
  <description>$name, installed by the sudo homelab media stack</description>
  <executable>$([Security.SecurityElement]::Escape($exe))</executable>
  <arguments>$([Security.SecurityElement]::Escape($arguments))</arguments>
  <workingdirectory>$([Security.SecurityElement]::Escape($workdir))</workingdirectory>
$envXml
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <onfailure action="restart" delay="10 sec"/>
  <stoptimeout>20 sec</stoptimeout>
  <logpath>$([Security.SecurityElement]::Escape((Join-Path $Script:LogDir "services")))</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>3</keepFiles></log>
$account
</service>
"@ | Set-Content -LiteralPath $xml -Encoding UTF8
  Exec $svcExe @('install')
  # The account password was only needed to register the service: scrub it from disk.
  if ($account) { (Get-Content -LiteralPath $xml -Raw) -replace '<password>.*?</password>', '<password>(set in Windows)</password>' | Set-Content -LiteralPath $xml -Encoding UTF8 }
}
# SABnzbd registers its own service (see Install-Sabnzbd), under its fixed name.
function Get-SvcName([string]$id) { if ($id -eq 'sabnzbd') { 'SABnzbd' } else { "sudohomelab-$id" } }
function Start-AppService([string]$id) { Start-Service -Name (Get-SvcName $id) }
function Stop-AppService([string]$id) { Stop-OurService (Get-SvcName $id) }
# Stop-Service waits forever if a service hangs in "stop pending" (WinSW 2.12 sometimes crashes listing
# Tdarr's child processes on stop). So ask, wait a while, then end whatever still runs from our folder.
function Stop-OurService([string]$name, [int]$seconds = 30) {
  $svc = Get-CimInstance Win32_Service -Filter "Name = '$name'" -ErrorAction SilentlyContinue
  if (-not $svc -or $svc.State -eq 'Stopped') { return }
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  # When WinSW crashes on stop, Windows counts it as a failure and restarts the app 10s later
  # (our restart-on-failure rule). So that rule is off while stopping, and put back afterwards.
  try { sc.exe failure $name reset= 0 actions= none/0 2>&1 | Out-Null; sc.exe stop $name 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Service $name).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt $seconds) { Start-Sleep -Milliseconds 500 }
    if ((Get-Service $name).Status -ne 'Stopped') {
      "$name didn't stop within ${seconds}s: ending its processes"
      if ($svc.ProcessId) { Stop-Process -Id $svc.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    # Its app processes can outlive a crashed wrapper. Matched by this app's own program folder in the
    # command line (Bazarr and Seerr run as python.exe / node.exe with their path as an argument), and
    # only that folder: killing another service's processes makes Windows restart that service.
    $folder = switch ($name.Replace('sudohomelab-', '')) { 'tdarr' { 'Tdarr_Server' } 'tdarr-node' { 'Tdarr_Node' } default { $_ } }
    $app = '\\' + [regex]::Escape($folder) + '\\'
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Script:AppsDir, 'OrdinalIgnoreCase') -and
        -not $_.ExecutablePath.StartsWith($Script:SvcDir, 'OrdinalIgnoreCase') -and $_.CommandLine -match $app } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } finally {
    # The wrapper can still crash after reporting "stopped": only re-arm the rule once it has exited.
    if ($svc.ProcessId) { $w = [Diagnostics.Stopwatch]::StartNew(); while ((Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue) -and $w.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 300 } }
    Start-Sleep 2
    $ErrorActionPreference = 'Continue'
    try { sc.exe failure $name reset= 86400 actions= restart/10000/restart/10000/restart/10000 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
  }
}
function Restart-AppService([string]$id) { Restart-Service -Name (Get-SvcName $id) -Force }
# Our services: the WinSW ones plus SABnzbd's own (only if it runs our copy).
function Get-OurServices {
  @(Get-Service 'sudohomelab-*' -ErrorAction SilentlyContinue)
  $sab = Get-CimInstance Win32_Service -Filter "Name = 'SABnzbd'" -ErrorAction SilentlyContinue
  if ($sab -and $sab.PathName -and $sab.PathName.Trim('"').StartsWith($Script:AppsDir, 'OrdinalIgnoreCase')) { Get-Service 'SABnzbd' }
}

function Grant-Access([string]$path) {
  # The service account needs Modify on settings and media; LocalSystem already has it.
  if ($Script:Choice.Account -ne 'sudohomelab') { return }
  $acl = Get-Acl -LiteralPath $path
  $rule = New-Object Security.AccessControl.FileSystemAccessRule("$env:COMPUTERNAME\$Script:SvcUser", 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule); Set-Acl -LiteralPath $path -AclObject $acl
}

# -- 1. Pre-flight ------------------------------------------------------------
function Invoke-Preflight {
  Step 'Pre-flight checks'
  $os = Get-CimInstance Win32_OperatingSystem
  if ([Environment]::Is64BitOperatingSystem -eq $false) { Die 'A 64-bit Windows is required.' }
  if ([int]$os.BuildNumber -lt 17763) { Die "$($os.Caption) is too old. Windows 10 1809 / Server 2019 or newer is required." }
  Ok "$($os.Caption) (build $($os.BuildNumber))"
  $Script:IsServer = ($os.ProductType -ne 1)
  $mem = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  Ok "$([Environment]::ProcessorCount) CPU - $mem GB RAM"
  if ($mem -lt 4) { Warn 'Less than 4 GB RAM: the stack (and building Seerr) may struggle.' }
  $Script:HostIp = Get-HostIp; Ok "This PC's IP: $Script:HostIp"
  $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Intel|NVIDIA|AMD|Radeon' } | Select-Object -First 1
  if ($gpu) { Ok "GPU: $($gpu.Name) (hardware transcoding available to Jellyfin/Plex)" } else { Info 'No dedicated/integrated GPU found: CPU transcoding' }
}

# -- 2. Choices ---------------------------------------------------------------
function Read-State {
  $f = Join-Path $Script:Settings 'state.json'
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
}
function Invoke-Choose {
  Step 'Choose your stack'
  $prev = Read-State
  $Script:Choice = [ordered]@{ Server = $Server; Downloader = ''; Extras = @(); Langs = $SubtitleLangs; DataDir = $DataDir; Account = $ServiceAccount }
  if ($prev) { Info "Currently installed: $($prev.Server) + $($prev.Downloader)$(if ($prev.Extras) { ' + ' + ($prev.Extras -join ', ') }) (shown as the defaults)" }

  $dl = @(($Downloader -join ',') -split '[, ]+' | Where-Object { $_ })
  if ($dl.Count -gt 1) { $Script:Choice.Downloader = 'both' } elseif ($dl.Count -eq 1) { $Script:Choice.Downloader = $dl[0] }

  if (-not $Script:Choice.Server) {
    $def = 1; if ($prev) { $def = [array]::IndexOf(@('jellyfin', 'plex', 'both'), $prev.Server) + 1; if ($def -lt 1) { $def = 1 } }
    $Script:Choice.Server = @('jellyfin', 'plex', 'both')[(Menu 'Which media server do you want?' $def @(
          'Jellyfin|free & open source, no account needed', 'Plex|polished apps everywhere, needs a plex.tv account', 'Both|run Jellyfin and Plex side by side')) - 1]
  }
  if (-not $Script:Choice.Downloader) {
    $def = 1; if ($prev) { $def = [array]::IndexOf(@('qbittorrent', 'sabnzbd', 'both'), $prev.Downloader) + 1; if ($def -lt 1) { $def = 1 } }
    $Script:Choice.Downloader = @('qbittorrent', 'sabnzbd', 'both')[(Menu 'Which download client do you want?' $def @(
          'qBittorrent|torrents', 'SABnzbd|usenet (needs a usenet provider)', 'Both|torrents + usenet')) - 1]
  }
  if ($Script:Choice.Downloader -notin 'qbittorrent', 'sabnzbd', 'both') { Die "Invalid -Downloader '$($Script:Choice.Downloader)'." }

  # Extras (multi-select). Seerr is offered here too: it's built from source, ~5 minutes.
  $all = @('lidarr', 'bazarr', 'tdarr', 'seerr')
  $ex = @(($Extras -join ',') -split '[, ]+' | Where-Object { $_ })
  if ($ex.Count -eq 0 -and -not $Yes) {
    $defs = @(); if ($prev -and $prev.Extras) { $defs = @($prev.Extras) } else { $defs = @('seerr') }
    $defNums = ($all | ForEach-Object -Begin { $i = 0 } -Process { $i++; if ($defs -contains $_) { $i } }) -join ' '
    Write-Host "`n  Extras " -ForegroundColor White -NoNewline; Write-Host '(optional, pick any)' -ForegroundColor DarkGray
    $desc = @('music collection manager, wired like Radarr/Sonarr', 'automatic subtitles for your movies and shows',
      'transcode / shrink your library (CPU heavy)', 'request portal for movies & shows (built from source: ~5 min, set up last)')
    for ($i = 0; $i -lt $all.Count; $i++) {
      Write-Host ("    {0}) " -f ($i + 1)) -ForegroundColor Green -NoNewline; Write-Host ("{0,-14} " -f (Get-Culture).TextInfo.ToTitleCase($all[$i])) -NoNewline
      Write-Host $desc[$i] -ForegroundColor DarkGray
    }
    while ($true) {
      Write-Host "  $($G.Arrow) " -ForegroundColor Cyan -NoNewline; Write-Host 'Numbers separated by spaces, a = all, n = none ' -NoNewline
      Write-Host "(default: $(if ($defNums) { $defNums } else { 'none' })): " -ForegroundColor DarkGray -NoNewline
      $ans = Read-Host; if ([string]::IsNullOrWhiteSpace($ans)) { $ans = if ($defNums) { $defNums } else { 'n' } }
      if ($ans -match '^(a|all)$') { $ex = $all; break }
      if ($ans -match '^(n|none)$') { $ex = @(); break }
      $picks = $ans -split '[ ,]+' | Where-Object { $_ }
      if (@($picks | Where-Object { $_ -notmatch '^[1-4]$' }).Count -eq 0) { $ex = @($picks | ForEach-Object { $all[[int]$_ - 1] } | Select-Object -Unique); break }
      Write-Host '    Use 1-4 (e.g. "1 4"), a or n.' -ForegroundColor Yellow
    }
  } elseif ($ex.Count -eq 0 -and $prev -and $prev.Extras) { $ex = @($prev.Extras) }
  $Script:Choice.Extras = @($ex | Where-Object { $_ -ne 'none' } | ForEach-Object {
      if ($all -contains $_) { $_ } else { Warn "Extra '$_' isn't supported on Windows yet; skipping it." } })

  if (Want 'bazarr') {
    if (-not $Script:Choice.Langs) { $Script:Choice.Langs = Ask 'Subtitle languages for Bazarr (2-letter codes, comma-separated)' $(if ($prev -and $prev.Langs) { $prev.Langs } else { 'en' }) }
    $Script:Choice.Langs = ($Script:Choice.Langs.ToLower() -replace '\s', '')
    if ($Script:Choice.Langs -notmatch '^[a-z]{2}(,[a-z]{2})*$') { Die "Subtitle languages must look like en or en,es (got '$($Script:Choice.Langs)')." }
  }

  # Media folder: default to the fixed drive with the most free space (other than C: when possible).
  if (-not $Script:Choice.DataDir) {
    $default = if ($prev -and $prev.DataDir) { $prev.DataDir } else {
      $d = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | Sort-Object -Property @{ Expression = { $_.DeviceID -eq 'C:' } }, @{ Expression = 'FreeSpace'; Descending = $true } | Select-Object -First 1
      "$($d.DeviceID)\Media" }
    $Script:Choice.DataDir = Ask 'Where should media + downloads live?' $default
  }
  $Script:Choice.DataDir = $Script:Choice.DataDir.TrimEnd('\')
  if ($Script:Choice.DataDir -notmatch '^[A-Za-z]:\\') { Die "Use a local folder like D:\Media (got '$($Script:Choice.DataDir)')." }

  # Login (shared by every app that has one).
  $secretsFile = Join-Path $Script:Settings '.secrets.json'
  if (Test-Path $secretsFile) {
    $sec = Get-Content $secretsFile -Raw | ConvertFrom-Json
    $Script:AppUser = $sec.AppUser; $Script:AppPass = $sec.AppPass; $Script:SvcPass = $sec.SvcPass
    Info "Existing install found: reusing login '$Script:AppUser'"
  } else {
    if (-not $Yes) { Write-Host "`n  Login for your apps " -ForegroundColor White -NoNewline; Write-Host '(one login for every app that has one)' -ForegroundColor DarkGray }
    $Script:AppUser = if ($Username) { $Username } else { Ask 'Username' 'admin' }
    while ($Script:AppUser -notmatch '^[A-Za-z0-9._-]{3,32}$') { Warn 'Username must be 3-32 characters: letters, numbers, . _ -'; $Script:AppUser = Ask 'Username' 'admin' }
    $Script:AppPass = $Password
    if (-not $Script:AppPass -and -not $Yes) {
      if ((Menu "Password for '$Script:AppUser'" 1 @('Auto-generate|a strong random password, shown now and saved for you', 'Type my own|at least 8 characters')) -eq 2) {
        while ($true) {
          $p1 = Ask-Secret 'Password:'; if ($p1.Length -lt 8) { Warn 'Use at least 8 characters.'; continue }
          if ((Ask-Secret 'Confirm password:') -eq $p1) { $Script:AppPass = $p1; break }; Warn "Passwords didn't match, try again."
        }
      }
    }
    if (-not $Script:AppPass) {
      $Script:AppPass = New-Secret 16; $Script:GeneratedPass = $true
      Write-Host "  $($G.Ok) " -ForegroundColor Green -NoNewline; Write-Host 'Generated password: ' -NoNewline; Write-Host $Script:AppPass -ForegroundColor White -NoNewline
      Write-Host "  (also saved to $Script:Settings\credentials.txt)" -ForegroundColor DarkGray
    }
    $Script:SvcPass = New-Secret 24
  }
  Add-Secret $Script:AppPass; Add-Secret $Script:SvcPass

  # Which Windows account runs the services.
  if (-not $Script:Choice.Account) {
    $def = 1; if ($prev -and $prev.Account -eq 'localsystem') { $def = 2 }
    $Script:Choice.Account = @('sudohomelab', 'localsystem')[(Menu 'Which Windows account should run the apps?' $def @(
          "sudohomelab|a dedicated local user (recommended; works with media on a NAS share)",
          'LocalSystem|the built-in system account (simplest; local drives only)')) - 1]
  }

  Write-Host "`n  Plan" -ForegroundColor White
  $servers = @('jellyfin', 'plex' | Where-Object { Want $_ }) -join ' '
  $dls = @('qbittorrent', 'sabnzbd' | Where-Object { Want $_ }) -join ' '
  $plan = [ordered]@{
    'Media server' = $servers; 'Downloads' = $dls; 'Automation' = 'Radarr - Sonarr - Prowlarr'
    'Extras' = $(if ($Script:Choice.Extras) { ($Script:Choice.Extras -join ' ') + $(if (Want 'bazarr') { " (subtitles: $($Script:Choice.Langs))" }) } else { 'none' })
    'Media folder' = $Script:Choice.DataDir; 'App settings' = $Script:Settings; 'Programs' = $Script:AppsDir
    'Services run as' = $(if ($Script:Choice.Account -eq 'sudohomelab') { ".\$Script:SvcUser" } else { 'LocalSystem' }); 'Login' = $Script:AppUser
  }
  foreach ($k in $plan.Keys) { Write-Host ("    {0,-16} {1}" -f $k, $plan[$k]) }
  if (Want 'seerr') { Info 'Seerr is built from source at the very end: that last step takes about 5 minutes.' }
  Write-ShlLog "Plan: $($plan | ConvertTo-Json -Compress)"
  if ($prev) {
    $removed = @('jellyfin', 'plex', 'qbittorrent', 'sabnzbd', 'lidarr', 'bazarr', 'tdarr', 'seerr') | Where-Object {
      ($prev.Apps -contains $_) -and -not (Want $_) }
    $Script:Removed = @($removed)
    if ($removed) { Warn "This will REMOVE: $($removed -join ', ') (their settings stay in $Script:ConfigDir)" }
  }
  Write-Host ''
  if ($DryRun) { Test-Ports -ReportOnly; Info 'Dry run: nothing was changed.'; throw 'sudohomelab-done' }
  if (-not (Confirm-Yes 'Install now?')) { Info 'Cancelled. Nothing was changed.'; throw 'sudohomelab-done' }
}

# -- 3. Ports, account, firewall ----------------------------------------------
function Get-NeededPorts {
  $p = @('radarr', 'sonarr', 'prowlarr')
  foreach ($a in 'jellyfin', 'plex', 'qbittorrent', 'sabnzbd', 'lidarr', 'bazarr', 'tdarr', 'seerr') { if (Want $a) { $p += $a } }
  if (Want 'qbittorrent') { $p += 'torrent' }
  if (Want 'tdarr') { $p += 'tdarrsrv' }
  $p
}
function Test-Ports([switch]$ReportOnly) {
  $prev = Read-State
  if ($prev -and $prev.Ports) { foreach ($k in @($prev.Ports.PSObject.Properties.Name)) { $Script:Ports[$k] = [int]$prev.Ports.$k } }
  $moved = $false
  foreach ($k in (Get-NeededPorts)) {
    $port = $Script:Ports[$k]; $owner = Get-PortOwner $port
    if (-not $owner -or (Test-OurPort $port)) { continue }
    if ($ReportOnly) { Warn "Port $port ($k) is used by '$owner'"; continue }
    Warn "Port $port ($k) is already used by '$owner'"
    if ($Script:FixedPorts -contains $k) { Die "$k needs port $port. Stop '$owner' (or skip $k) and re-run." }
    $alt = $port + 1; while ((Get-PortOwner $alt) -or ($Script:Ports.Values -contains $alt)) { $alt++ }
    switch (Menu 'What should I do?' 1 @("Use $alt|next free port", 'Choose a port|type the port you want', 'Cancel|nothing has been installed yet')) {
      1 { $Script:Ports[$k] = $alt }
      2 { while ($true) { $n = 0; if ([int]::TryParse((Ask "Port for $k (1024-65535)" "$alt"), [ref]$n) -and $n -ge 1024 -and $n -le 65535 -and -not (Get-PortOwner $n)) { $Script:Ports[$k] = $n; break }; Warn 'That port is invalid or taken.' } }
      default { Info 'Cancelled. Nothing was installed.'; throw 'sudohomelab-done' }
    }
    Ok "$k will use port $($Script:Ports[$k])"; $moved = $true
  }
  if (-not $moved -and -not $ReportOnly) { Ok 'Required ports are free' }
}

function Invoke-Prepare {
  Step 'Preparing Windows'
  Test-Ports
  $drive = Split-Path -Qualifier $Script:Choice.DataDir
  $free = [Math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$drive'").FreeSpace / 1GB, 1)
  $need = 4 + $(if (Want 'tdarr') { 2 } else { 0 }) + $(if (Want 'seerr') { 2 } else { 0 })
  if ($free -lt $need) { Die "Only $free GB free on $drive; the programs need about $need GB." }
  Ok "Disk: $free GB free on $drive"

  New-Item -ItemType Directory -Force -Path $Script:Settings, $Script:ConfigDir, $Script:AppsDir, $Script:SvcDir, (Join-Path $Script:LogDir 'services') | Out-Null
  # Settings hold API keys and the login: Administrators + SYSTEM (+ the service account) only.
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($who in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl -LiteralPath $Script:Settings -AclObject $acl
  # Saved now, not at the end: a re-run after a failure must reuse this login, since
  # qBittorrent's config (written once) already holds it.
  Save-Secrets

  if ($Script:Choice.Account -eq 'sudohomelab') {
    $u = Get-LocalUser -Name $Script:SvcUser -ErrorAction SilentlyContinue
    $sec = ConvertTo-SecureString $Script:SvcPass -AsPlainText -Force
    if ($u) { Set-LocalUser -Name $Script:SvcUser -Password $sec; Ok "Using local user $Script:SvcUser" }
    else {
      New-LocalUser -Name $Script:SvcUser -Password $sec -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
        -Description 'Runs the sudo homelab media stack services' | Out-Null
      Ok "Created local user $Script:SvcUser (runs the services, can't log in interactively)"
    }
    Grant-Access $Script:Settings
    Grant-Access (Join-Path $Script:LogDir 'services')   # WinSW runs as this user and writes the app logs here
  }

  $dirs = @('Movies', 'TV_Shows', 'Active_Downloads')
  if (Want 'lidarr') { $dirs += 'Music' }
  if (Want 'tdarr') { $dirs += 'Transcode_Cache' }
  if (Want 'qbittorrent') { $dirs += 'Active_Downloads\torrents\movies', 'Active_Downloads\torrents\tv', 'Active_Downloads\torrents\incomplete'; if (Want 'lidarr') { $dirs += 'Active_Downloads\torrents\music' } }
  if (Want 'sabnzbd') { $dirs += 'Active_Downloads\usenet\incomplete', 'Active_Downloads\usenet\complete' }
  foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $Script:Choice.DataDir $d) | Out-Null }
  Grant-Access $Script:Choice.DataDir
  Ok "Media library: $($Script:Choice.DataDir)\Movies - \TV_Shows$(if (Want 'lidarr') { ' - \Music' })"

  # Firewall: Private and Domain networks only, never Public.
  Get-NetFirewallRule -Group $Script:FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  foreach ($k in (Get-NeededPorts)) {
    if ($k -eq 'plex') { continue }   # Plex's installer adds its own rules
    $proto = @('TCP'); if ($k -eq 'torrent') { $proto = @('TCP', 'UDP') }
    foreach ($pr in $proto) {
      New-NetFirewallRule -DisplayName "sudo homelab - $k ($pr $($Script:Ports[$k]))" -Group $Script:FwGroup -Direction Inbound -Action Allow `
        -Protocol $pr -LocalPort $Script:Ports[$k] -Profile Private, Domain | Out-Null
    }
  }
  Ok 'Firewall: ports opened for Private/Domain networks only'

  # Those rules do nothing on a Public network, and Windows often files a new LAN as Public.
  $ifx = Get-NetIPAddress -IPAddress $Script:HostIp -ErrorAction SilentlyContinue | Select-Object -First 1
  $prof = if ($ifx) { Get-NetConnectionProfile -InterfaceIndex $ifx.InterfaceIndex -ErrorAction SilentlyContinue } else { $null }
  if ($prof -and $prof.NetworkCategory -eq 'Public') {
    Warn "Windows treats '$($prof.InterfaceAlias)' ($($prof.Name)) as a Public network, so other devices can't reach the apps."
    if (-not $Yes -and (Confirm-Yes 'Mark it as a Private (home) network?')) {
      Set-NetConnectionProfile -InterfaceIndex $ifx.InterfaceIndex -NetworkCategory Private; Ok "'$($prof.InterfaceAlias)' is now a Private network"
    } else { Info "To allow it later: Set-NetConnectionProfile -InterfaceIndex $($ifx.InterfaceIndex) -NetworkCategory Private" }
  }
}

# -- 4. Programs --------------------------------------------------------------
function Install-Arr([string]$app, [string]$repo, [string]$pattern) {
  $dir = Join-Path $Script:AppsDir $app; $cfg = Join-Path $Script:ConfigDir $app
  New-Item -ItemType Directory -Force -Path $cfg | Out-Null
  $a = Get-GitHubAsset $repo $pattern
  "$($a.Name) ($($a.Tag))"
  $zip = Join-Path $env:TEMP $a.Name; Save-File $a.Url $zip
  Expand-To $zip "$dir.new"; Remove-Item $zip -Force
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  $inner = Get-ChildItem "$dir.new" -Directory | Select-Object -First 1
  Move-Item $inner.FullName $dir; Remove-Item "$dir.new" -Recurse -Force
  # Pre-seed config.xml: our API key and port, before the first start.
  $xml = Join-Path $cfg 'config.xml'
  if (-not (Test-Path $xml)) {
    $title = (Get-Culture).TextInfo.ToTitleCase($app)
    "<Config>`n  <BindAddress>*</BindAddress>`n  <Port>$($Script:Ports[$app])</Port>`n  <EnableSsl>False</EnableSsl>`n  <LaunchBrowser>False</LaunchBrowser>`n  <ApiKey>$(New-HexKey)</ApiKey>`n  <LogLevel>info</LogLevel>`n  <UrlBase></UrlBase>`n  <InstanceName>$title</InstanceName>`n</Config>" |
      Set-Content -LiteralPath $xml -Encoding UTF8
  } else {
    (Get-Content $xml -Raw) -replace '<Port>\d+</Port>', "<Port>$($Script:Ports[$app])</Port>" | Set-Content -LiteralPath $xml -Encoding UTF8
  }
  $exe = Join-Path $dir "$((Get-Culture).TextInfo.ToTitleCase($app)).exe"
  Install-AppService $app (Get-Culture).TextInfo.ToTitleCase($app) $exe "-nobrowser -data=`"$cfg`"" $dir
}
function Get-ArrKey([string]$app) { ([xml](Get-Content (Join-Path (Join-Path $Script:ConfigDir $app) 'config.xml') -Raw)).Config.ApiKey }

function Install-Jellyfin {
  $dir = Join-Path $Script:AppsDir 'jellyfin'; $cfg = Join-Path $Script:ConfigDir 'jellyfin'
  $list = (Invoke-WebRequest -UseBasicParsing 'https://repo.jellyfin.org/files/server/windows/latest-stable/amd64/').Content
  $name = [regex]::Matches($list, 'jellyfin_[\d.]+-amd64\.zip') | Select-Object -First 1 -ExpandProperty Value
  if (-not $name) { throw 'No Jellyfin zip found on repo.jellyfin.org' }
  $name
  $zip = Join-Path $env:TEMP $name; Save-File "https://repo.jellyfin.org/files/server/windows/latest-stable/amd64/$name" $zip
  Expand-To $zip "$dir.new"; Remove-Item $zip -Force
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  $inner = Get-ChildItem "$dir.new" -Directory | Select-Object -First 1
  if ($inner -and (Test-Path (Join-Path $inner.FullName 'jellyfin.exe'))) { Move-Item $inner.FullName $dir; Remove-Item "$dir.new" -Recurse -Force } else { Move-Item "$dir.new" $dir }
  New-Item -ItemType Directory -Force -Path $cfg, (Join-Path $cfg 'cache') | Out-Null
  $ff = Get-ChildItem $dir -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  $ffArg = ''; if ($ff) { $ffArg = " --ffmpeg `"$($ff.FullName)`"" } else { 'No bundled ffmpeg found: Jellyfin will ask for one in its dashboard' }
  Install-AppService 'jellyfin' 'Jellyfin' (Join-Path $dir 'jellyfin.exe') "--datadir `"$cfg`" --cachedir `"$(Join-Path $cfg 'cache')`"$ffArg" $dir
}

function Get-Pbkdf2([string]$pass) {
  # qBittorrent's WebUI\Password_PBKDF2: PBKDF2-SHA512, 100000 rounds, 16-byte salt, 64-byte key.
  $salt = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA512)
  '@ByteArray({0}:{1})' -f [Convert]::ToBase64String($salt), [Convert]::ToBase64String($kdf.GetBytes(64))
}
function Install-QBittorrent {
  $rel = Invoke-RestMethod 'https://sourceforge.net/projects/qbittorrent/best_release.json'
  $url = $rel.platform_releases.windows.url; $file = Split-Path $rel.platform_releases.windows.filename -Leaf
  if ($file -notmatch 'x64_setup\.exe$') { throw "Unexpected qBittorrent download: $file" }
  $file
  $setup = Join-Path $env:TEMP $file; Save-File $url $setup
  $dir = Join-Path $Script:AppsDir 'qbittorrent'
  Invoke-Installer $setup @('/S', "/D=$dir")
  Remove-Item $setup -Force
  # With --profile, qBittorrent keeps its config in <profile>\qBittorrent\config\qBittorrent.ini
  $qbProfile = Join-Path $Script:ConfigDir 'qbittorrent'; $ini = Join-Path $qbProfile 'qBittorrent\config\qBittorrent.ini'
  if (-not (Test-Path $ini)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ini) | Out-Null
    $dl = Join-Path $Script:Choice.DataDir 'Active_Downloads\torrents'
    @"
[BitTorrent]
Session\DefaultSavePath=$($dl.Replace('\', '/'))
Session\TempPath=$((Join-Path $dl 'incomplete').Replace('\', '/'))
Session\TempPathEnabled=true
Session\Port=$($Script:Ports.torrent)

[LegalNotice]
Accepted=true

[Preferences]
General\StartMinimized=true
WebUI\Enabled=true
WebUI\Port=$($Script:Ports.qbittorrent)
WebUI\Username=$Script:AppUser
WebUI\Password_PBKDF2="$(Get-Pbkdf2 $Script:AppPass)"
WebUI\HostHeaderValidation=false
WebUI\LocalHostAuth=true
"@ | Set-Content -LiteralPath $ini -Encoding UTF8
  }
  Install-AppService 'qbittorrent' 'qBittorrent' (Join-Path $dir 'qbittorrent.exe') "--profile=`"$qbProfile`" --confirm-legal-notice" $dir
}

function Install-Sabnzbd {
  $a = Get-GitHubAsset 'sabnzbd/sabnzbd' 'win64-bin\.zip$'; "$($a.Name)"
  $dir = Join-Path $Script:AppsDir 'sabnzbd'; $cfg = Join-Path $Script:ConfigDir 'sabnzbd'
  $zip = Join-Path $env:TEMP $a.Name; Save-File $a.Url $zip
  Expand-To $zip "$dir.new"; Remove-Item $zip -Force
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  $inner = Get-ChildItem "$dir.new" -Directory | Select-Object -First 1
  if ($inner -and (Get-ChildItem $inner.FullName -Filter 'SABnzbd*.exe')) { Move-Item $inner.FullName $dir; Remove-Item "$dir.new" -Recurse -Force } else { Move-Item "$dir.new" $dir }
  New-Item -ItemType Directory -Force -Path $cfg | Out-Null
  $exe = Get-ChildItem $dir -Filter 'SABnzbd-console.exe' -Recurse | Select-Object -First 1
  if (-not $exe) { $exe = Get-ChildItem $dir -Filter 'SABnzbd.exe' -Recurse | Select-Object -First 1 }
  # SABnzbd's Windows build can't run under WinSW: started in session 0 it always tries to be its
  # own service and crashes. So it gets its own service, named "SABnzbd" as its code expects, which
  # reads its options from the CommandLine value under the service key. We register it ourselves:
  # "SABnzbd.exe install" crashes the same way when run from session 0 (SSH, remote tools).
  foreach ($n in 'SABnzbd', 'sudohomelab-sabnzbd') {
    if (Get-Service $n -ErrorAction SilentlyContinue) { Stop-OurService $n; Exec 'sc.exe' @('delete', $n) | Out-Null }
  }
  Remove-Item (Join-Path $Script:SvcDir 'sudohomelab-sabnzbd.*') -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 15 -and (Get-Service 'SABnzbd' -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }   # deletion is async
  $bin = Join-Path $exe.DirectoryName 'SABnzbd.exe'; if (-not (Test-Path $bin)) { $bin = $exe.FullName }
  New-Service -Name 'SABnzbd' -BinaryPathName "`"$bin`"" -DisplayName 'sudo homelab - SABnzbd' -StartupType Automatic `
    -Description 'SABnzbd, installed by the sudo homelab media stack' | Out-Null
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SABnzbd' -Name 'CommandLine' -PropertyType MultiString -Force `
    -Value @('-f', (Join-Path $cfg 'sabnzbd.ini'), '-s', "0.0.0.0:$($Script:Ports.sabnzbd)", '-b', '0') | Out-Null
  Exec 'sc.exe' @('config', 'SABnzbd', 'start=', 'delayed-auto') | Out-Null
  Exec 'sc.exe' @('failure', 'SABnzbd', 'reset=', '86400', 'actions=', 'restart/10000/restart/10000/restart/10000') | Out-Null
  if ($Script:Choice.Account -eq 'sudohomelab') {
    # Through WMI, so the password never appears on a command line.
    $r = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Service -Filter "Name = 'SABnzbd'") -MethodName Change -Arguments @{ StartName = ".\$Script:SvcUser"; StartPassword = $Script:SvcPass }
    if ($r.ReturnValue -ne 0) { throw "Couldn't set the SABnzbd service account (error $($r.ReturnValue))" }
  }
  "SABnzbd service runs as $(if ($Script:Choice.Account -eq 'sudohomelab') { ".\$Script:SvcUser" } else { 'LocalSystem' })"
}

function Install-Plex {
  $d = Invoke-RestMethod 'https://plex.tv/api/downloads/5.json'
  $rel = $d.computer.Windows.releases | Where-Object { $_.build -eq 'windows-x86_64' } | Select-Object -First 1
  "Plex Media Server $($d.computer.Windows.version)"
  $setup = Join-Path $env:TEMP (Split-Path $rel.url -Leaf); Save-File $rel.url $setup
  # Plex's installer is Inno Setup (it ignores /quiet and opens its wizard).
  Invoke-Installer $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') @(0, 3010)
  Remove-Item $setup -Force
  # The installer starts Plex for the admin who ran it and adds an autostart for them.
  Get-Process 'Plex Media Server' -ErrorAction SilentlyContinue | Stop-Process -Force
  Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Plex Media Server' -ErrorAction SilentlyContinue
  $exe = Join-Path ${env:ProgramFiles} 'Plex\Plex Media Server\Plex Media Server.exe'
  if (-not (Test-Path $exe)) { $exe = Join-Path ${env:ProgramFiles(x86)} 'Plex\Plex Media Server\Plex Media Server.exe' }
  # Plex isn't a service: a startup task runs it at boot, as SYSTEM, with its data in our settings folder.
  $data = Join-Path $Script:ConfigDir 'plex'; New-Item -ItemType Directory -Force -Path $data | Out-Null
  $key = 'Registry::HKEY_USERS\S-1-5-18\Software\Plex, Inc.\Plex Media Server'
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name 'LocalAppDataPath' -Value $data
  $action = New-ScheduledTaskAction -Execute $exe
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName 'sudohomelab-plex' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName 'sudohomelab-plex'
  if ($Script:Choice.Account -eq 'sudohomelab') { 'Note: Plex runs as SYSTEM (it isn''t a Windows service), so it reads local drives, not NAS shares.' }
}

function Install-Python([string]$appDir) {
  # Python's "embeddable" build: a private copy in our folder, not registered with Windows, so it
  # can't touch (or be mistaken for) a Python the user installed, and deleting the folder removes it.
  $dir = Join-Path $Script:AppsDir 'python312'; $py = Join-Path $dir 'python.exe'
  $embedded = (Test-Path (Join-Path $dir 'Scripts\pip.exe')) -and (Get-ChildItem $dir -Filter 'python*._pth' -ErrorAction SilentlyContinue)
  if (-not $embedded) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    $zip = Join-Path $env:TEMP 'python-3.12.10-embed-amd64.zip'
    Save-File 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' $zip
    Expand-To $zip $dir; Remove-Item $zip -Force
    $getPip = Join-Path $dir 'get-pip.py'; Save-File 'https://bootstrap.pypa.io/get-pip.py' $getPip
  }
  # Its ._pth file is the whole import path: enable site-packages (for pip) and add the app's folder,
  # which the embeddable build doesn't put on the path by itself.
  $pth = Get-ChildItem $dir -Filter 'python*._pth' | Select-Object -First 1
  $lines = @(Get-Content $pth.FullName | Where-Object { $_ -and $_ -notmatch '^#?\s*import site' -and $_ -ne $appDir -and $_ -ne (Join-Path $appDir 'bazarr') })
  ($lines + @($appDir, (Join-Path $appDir 'bazarr'), 'import site')) | Set-Content $pth.FullName -Encoding ASCII
  if (-not (Test-Path (Join-Path $dir 'Scripts\pip.exe'))) {
    Exec $py @((Join-Path $dir 'get-pip.py'), '--no-warn-script-location', '--disable-pip-version-check', '-q')
  }
  $py
}
function Install-Bazarr {
  $dir = Join-Path $Script:AppsDir 'bazarr'; $cfg = Join-Path $Script:ConfigDir 'bazarr'
  $py = Install-Python $dir; 'Python 3.12 ready (private copy for Bazarr)'
  $a = Get-GitHubAsset 'morpheus65535/bazarr' '^bazarr\.zip$'; "Bazarr $($a.Tag)"
  $zip = Join-Path $env:TEMP $a.Name; Save-File $a.Url $zip
  Expand-To $zip $dir; Remove-Item $zip -Force
  New-Item -ItemType Directory -Force -Path $cfg | Out-Null
  Grant-Access $dir   # it downloads ffprobe into bin\ next to itself
  'Installing Bazarr''s Python packages (about a minute)...'
  Exec $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '-q', '-r', (Join-Path $dir 'requirements.txt'))
  Install-AppService 'bazarr' 'Bazarr' $py "`"$(Join-Path $dir 'bazarr.py')`" --config `"$cfg`" --port $($Script:Ports.bazarr) --no-update" $dir
}

function Install-Tdarr {
  $v = Invoke-RestMethod 'https://storage.tdarr.io/versions.json'
  $latest = @($v.PSObject.Properties.Name | Sort-Object { [version]($_ -replace '^(\d+)\.(\d+)\.(\d+).*', '$1.$2.$3') })[-1]
  "Tdarr $latest"
  # Tdarr's own layout: <root>\Tdarr_Server and <root>\Tdarr_Node, and it keeps configs\, logs\ and
  # server\ (its database) in <root>, the folder above its exe. Those three are junctions into our
  # settings folder, so they survive an uninstall like every other app's settings.
  $root = Join-Path $Script:AppsDir 'tdarr'; $cfg = Join-Path $Script:ConfigDir 'tdarr'
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  foreach ($part in 'Tdarr_Server', 'Tdarr_Node') {
    $zip = Join-Path $env:TEMP "$part.zip"; Save-File $v.$latest.win32_x64.$part $zip
    Expand-To $zip (Join-Path $root $part); Remove-Item $zip -Force
  }
  foreach ($d in 'configs', 'logs', 'server') {
    $link = Join-Path $root $d; $target = Join-Path $cfg $d
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    if (-not (Test-Path $link)) { New-Item -ItemType Junction -Path $link -Value $target | Out-Null }
  }
  Grant-Access $root   # it also writes caches next to its exe
  # Login stays on (as on Linux; the admin account is created when wiring). The node is a separate
  # program here, so it signs in to the server with a key the server is told to accept.
  $sf = Join-Path $cfg 'configs\Tdarr_Server_Config.json'; $nf = Join-Path $cfg 'configs\Tdarr_Node_Config.json'
  $key = ''
  if (Test-Path $sf) { $old = Get-Content $sf -Raw | ConvertFrom-Json; if ($old.PSObject.Properties['seededApiKey'] -and $old.seededApiKey) { $key = $old.seededApiKey } }
  if (-not $key) { $key = "tapi_$(New-Secret 24)" }
  $Script:TdarrKey = $key
  # Once Tdarr has stored any API key, it refuses to register the first admin (403) for good. So the
  # key is only seeded after Set-Tdarr has created the admin and left the .admin-ready marker.
  $srvCfg = [ordered]@{ serverPort = "$($Script:Ports.tdarrsrv)"; webUIPort = "$($Script:Ports.tdarr)"; serverIP = '0.0.0.0'; serverBindIP = $false; serverDualStack = $false
    handbrakePath = ''; ffmpegPath = ''; logLevel = 'INFO'; mkvpropeditPath = ''; ccextractorPath = ''; openBrowser = $false; cronPluginUpdate = ''
    auth = $true; maxLogSizeMB = 10 }
  if (Test-Path (Join-Path $cfg '.admin-ready')) { $srvCfg.seededApiKey = $key }
  $srvCfg | Merge-TdarrConfig $sf -Drop $(if ($srvCfg.Contains('seededApiKey')) { @() } else { @('seededApiKey') })
  [ordered]@{ nodeName = 'WindowsNode'; serverURL = "http://127.0.0.1:$($Script:Ports.tdarrsrv)"; serverIP = '127.0.0.1'; serverPort = "$($Script:Ports.tdarrsrv)"
    handbrakePath = ''; ffmpegPath = ''; mkvpropeditPath = ''; nodeType = 'mapped'; unmappedNodeCache = (Join-Path $cfg 'node-cache'); logLevel = 'INFO'
    priority = -1; cronPluginUpdate = ''; maxLogSizeMB = 10; pollInterval = 2000; startPaused = $false; apiKey = $key } | Merge-TdarrConfig $nf
  Add-Secret $key
  Install-AppService 'tdarr' 'Tdarr Server' (Join-Path $root 'Tdarr_Server\Tdarr_Server.exe') '' (Join-Path $root 'Tdarr_Server')
  Install-AppService 'tdarr-node' 'Tdarr Node' (Join-Path $root 'Tdarr_Node\Tdarr_Node.exe') '' (Join-Path $root 'Tdarr_Node')
}
# Our values win, but keys Tdarr added itself (like authSecretKey) are kept on re-runs.
function Merge-TdarrConfig([string]$file, [Parameter(ValueFromPipeline)]$ours, [string[]]$Drop = @()) {
  $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { New-Object psobject }
  foreach ($k in $ours.Keys) { Set-Prop $obj $k $ours[$k] }
  foreach ($k in $Drop) { [void]$obj.PSObject.Properties.Remove($k) }
  [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $obj -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Programs {
  Step 'Installing programs'
  # Re-run: running apps lock their program files, which are about to be replaced. Switch them to
  # manual first, or Windows' delayed auto-start (~2 min after boot) can start one mid-update;
  # each service is set back to automatic when it's reinstalled below.
  foreach ($s in @(Get-OurServices)) { Set-Service -Name $s.Name -StartupType Manual }
  $running = @(Get-OurServices | Where-Object { $_.Status -ne 'Stopped' })
  if ($running) { Run "Stopping $($running.Count) running app(s) for the update" { foreach ($s in $running) { Stop-OurService $s.Name; "stopped $($s.Name)" } } }
  # Apps left behind by a crashed service wrapper still hold their ports and files. Never the wrappers
  # themselves: killing one counts as a service crash, and Windows restarts the app right away.
  $orphans = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Script:AppsDir, 'OrdinalIgnoreCase') -and
      -not $_.ExecutablePath.StartsWith($Script:SvcDir, 'OrdinalIgnoreCase') })
  if ($orphans) { Run "Ending $($orphans.Count) leftover app process(es)" { foreach ($p in $orphans) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; "ended $($p.Name) (pid $($p.ProcessId))" } } }
  Remove-Deselected
  Run 'Service wrapper (WinSW)' { Get-WinSW | Out-Null; 'WinSW 2.12.0' }
  if (Want 'qbittorrent') { Run 'qBittorrent' { Install-QBittorrent } }
  Run 'Prowlarr' { Install-Arr 'prowlarr' 'Prowlarr/Prowlarr' 'windows-core-x64\.zip$' }
  Run 'Radarr' { Install-Arr 'radarr' 'Radarr/Radarr' 'windows-core-x64\.zip$' }
  Run 'Sonarr' { Install-Arr 'sonarr' 'Sonarr/Sonarr' 'win-x64\.zip$' }
  if (Want 'lidarr') { Run 'Lidarr' { Install-Arr 'lidarr' 'Lidarr/Lidarr' 'windows-core-x64\.zip$' } }
  # After a WinSW service: WinSW gives the account "log on as a service", which SABnzbd's own service needs too.
  if (Want 'sabnzbd') { Run 'SABnzbd' { Install-Sabnzbd } }
  if (Want 'jellyfin') { Run 'Jellyfin' { Install-Jellyfin } }
  if (Want 'plex') { Run 'Plex Media Server' { Install-Plex } }
  if (Want 'bazarr') { Run 'Bazarr (with Python)' { Install-Bazarr } }
  if (Want 'tdarr') { Run 'Tdarr (server + node)' { Install-Tdarr } }
}

# -- 5. Start -----------------------------------------------------------------
function Invoke-Start {
  Step 'Starting the apps'
  $order = @('qbittorrent', 'sabnzbd', 'prowlarr', 'radarr', 'sonarr', 'lidarr', 'jellyfin', 'bazarr', 'tdarr', 'tdarr-node')
  foreach ($id in $order) { if (Get-Service (Get-SvcName $id) -ErrorAction SilentlyContinue) { Start-AppService $id } }
  Ok 'Services started'
  $p = $Script:Ports
  Run 'Waiting for Radarr' { Wait-Http 'Radarr' "http://localhost:$($p.radarr)/api/v3/system/status" 240 @{ 'X-Api-Key' = (Get-ArrKey 'radarr') } }
  Run 'Waiting for Sonarr' { Wait-Http 'Sonarr' "http://localhost:$($p.sonarr)/api/v3/system/status" 240 @{ 'X-Api-Key' = (Get-ArrKey 'sonarr') } }
  Run 'Waiting for Prowlarr' { Wait-Http 'Prowlarr' "http://localhost:$($p.prowlarr)/api/v1/system/status" 240 @{ 'X-Api-Key' = (Get-ArrKey 'prowlarr') } }
  if (Want 'lidarr') { Run 'Waiting for Lidarr' { Wait-Http 'Lidarr' "http://localhost:$($p.lidarr)/api/v1/system/status" 240 @{ 'X-Api-Key' = (Get-ArrKey 'lidarr') } } }
  if (Want 'qbittorrent') { Run 'Waiting for qBittorrent' { Wait-Http 'qBittorrent' "http://localhost:$($p.qbittorrent)/" 180 } }
  if (Want 'sabnzbd') { Run 'Waiting for SABnzbd' { Wait-Http 'SABnzbd' "http://localhost:$($p.sabnzbd)/" 180 } }
  if (Want 'jellyfin') { Run 'Waiting for Jellyfin' { Wait-Http 'Jellyfin' "http://localhost:$($p.jellyfin)/health" 240 } }
  if (Want 'plex') { Run 'Waiting for Plex' { Wait-Http 'Plex' "http://localhost:$($p.plex)/identity" 240 } }
  if (Want 'bazarr') { Run 'Waiting for Bazarr' { Wait-Http 'Bazarr' "http://localhost:$($p.bazarr)/" 240 } }
  if (Want 'tdarr') { Run 'Waiting for Tdarr' { Wait-Http 'Tdarr' "http://localhost:$($p.tdarr)/api/v2/status" 300 } }
}

# -- 6. Wiring (same steps as the Linux core, over HTTP from this process) ----
function Set-ArrAuth([string]$url, [string]$v, [string]$key) {
  $cfg = Api GET "$url/api/$v/config/host" $key
  Set-Prop $cfg authenticationMethod 'forms'; Set-Prop $cfg authenticationRequired 'enabled'
  Set-Prop $cfg username $Script:AppUser; Set-Prop $cfg password $Script:AppPass; Set-Prop $cfg passwordConfirmation $Script:AppPass
  Api PUT "$url/api/$v/config/host/$($cfg.id)" $key $cfg | Out-Null
}
function Add-RootFolder([string]$url, [string]$key, [string]$path, $extra = $null) {
  $v = 'v3'; if ($extra) { $v = 'v1' }
  $have = @(Api GET "$url/api/$v/rootfolder" $key)
  if ($have | Where-Object { $_.path.TrimEnd('\') -eq $path.TrimEnd('\') }) { return }
  $body = [ordered]@{ path = $path }; if ($extra) { foreach ($k in $extra.Keys) { $body[$k] = $extra[$k] } }
  Api POST "$url/api/$v/rootfolder" $key $body | Out-Null
}
# Create or update (by name) a download client / Prowlarr app from the app's own schema.
function Set-FromSchema([string]$url, [string]$v, [string]$key, [string]$res, [string]$impl, [string]$name, [hashtable]$fields, [hashtable]$props = @{}) {
  $existing = @(Api GET "$url/api/$v/$res" $key) | Where-Object { $_.name -eq $name } | Select-Object -First 1
  $obj = $existing
  if (-not $obj) { $obj = @(Api GET "$url/api/$v/$res/schema" $key) | Where-Object { $_.implementation -eq $impl } | Select-Object -First 1 }
  if (-not $obj) { throw "No $impl schema in $url" }
  Set-Prop $obj name $name; Set-Prop $obj enable $true
  foreach ($k in $props.Keys) { Set-Prop $obj $k $props[$k] }
  foreach ($f in $obj.fields) { if ($fields.ContainsKey($f.name)) { Set-Prop $f value $fields[$f.name] } }
  if ($existing) { Api PUT "$url/api/$v/$res/$($obj.id)" $key $obj | Out-Null } else { Api POST "$url/api/$v/$res" $key $obj | Out-Null }
}

function Set-QbitCategories {
  $q = "http://localhost:$($Script:Ports.qbittorrent)"
  $body = "username=$([uri]::EscapeDataString($Script:AppUser))&password=$([uri]::EscapeDataString($Script:AppPass))"
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$q/api/v2/auth/login" -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers @{ Referer = $q } -SessionVariable s | Out-Null
  if (-not ($s.Cookies.GetCookies($q) | Where-Object { $_.Name -like 'QBT_SID*' -or $_.Name -eq 'SID' })) { throw 'qBittorrent login failed' }
  $cats = @('movies', 'tv'); if (Want 'lidarr') { $cats += 'music' }
  foreach ($c in $cats) {
    $path = Join-Path $Script:Choice.DataDir "Active_Downloads\torrents\$c"
    foreach ($ep in 'createCategory', 'editCategory') {
      try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$q/api/v2/torrents/$ep" -Body "category=$c&savePath=$([uri]::EscapeDataString($path))" -ContentType 'application/x-www-form-urlencoded' -Headers @{ Referer = $q } -WebSession $s | Out-Null } catch { }
    }
  }
}

function Set-Sabnzbd {
  $ini = Join-Path $Script:ConfigDir 'sabnzbd\sabnzbd.ini'
  for ($i = 0; $i -lt 60 -and -not ((Test-Path $ini) -and (Select-String -Path $ini -Pattern '^api_key = .+' -Quiet)); $i++) { Start-Sleep 2 }
  $Script:SabKey = (Select-String -Path $ini -Pattern '^api_key = (.+)$').Matches[0].Groups[1].Value.Trim(); Add-Secret $Script:SabKey
  $s = "http://localhost:$($Script:Ports.sabnzbd)/api"
  $set = { param($section, $kv) Invoke-RestMethod -Uri ("${s}?mode=set_config&section=$section&output=json&apikey=$Script:SabKey&" + (($kv.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&')) | Out-Null }
  $misc = [ordered]@{ host_whitelist = "$env:COMPUTERNAME,$Script:HostIp,localhost"; download_dir = (Join-Path $Script:Choice.DataDir 'Active_Downloads\usenet\incomplete'); complete_dir = (Join-Path $Script:Choice.DataDir 'Active_Downloads\usenet\complete'); username = $Script:AppUser; password = $Script:AppPass }
  foreach ($k in $misc.Keys) { & $set 'misc' @{ keyword = $k; value = $misc[$k] } }
  Restart-AppService 'sabnzbd'; Wait-Http 'SABnzbd' "http://localhost:$($Script:Ports.sabnzbd)/" 120
  $cats = @('movies', 'tv'); if (Want 'lidarr') { $cats += 'music' }
  for ($try = 1; $try -le 6; $try++) {
    foreach ($c in $cats) { & $set 'categories' @{ keyword = $c; dir = $c } }
    Start-Sleep 3
    $got = (Invoke-RestMethod "${s}?mode=get_config&section=categories&output=json&apikey=$Script:SabKey").config.categories
    if (@($cats | Where-Object { $c = $_; -not ($got | Where-Object { $_.name -eq $c -and $_.dir -eq $c }) }).Count -eq 0) { "SABnzbd categories set (attempt $try)"; return }
    "SABnzbd categories not applied yet (attempt $try), retrying"
  }
  throw 'SABnzbd categories could not be set'
}

function Set-Arr([string]$app, [string]$v, [string]$folder, [string]$catField, [string]$cat) {
  $url = "http://localhost:$($Script:Ports[$app])"; $key = Get-ArrKey $app
  if ($app -eq 'lidarr') {
    $qp = @(Api GET "$url/api/v1/qualityprofile" $key); $mp = @(Api GET "$url/api/v1/metadataprofile" $key)
    $q = ($qp | Where-Object name -eq 'Standard' | Select-Object -First 1); if (-not $q) { $q = $qp[0] }
    $m = ($mp | Where-Object name -eq 'Standard' | Select-Object -First 1); if (-not $m) { $m = $mp[0] }
    Add-RootFolder $url $key $folder @{ name = 'Music'; defaultQualityProfileId = $q.id; defaultMetadataProfileId = $m.id; defaultMonitorOption = 'all'; defaultNewItemMonitorOption = 'all'; defaultTags = @() }
  } else { Add-RootFolder $url $key $folder }
  if (Want 'qbittorrent') { Set-FromSchema $url $v $key 'downloadclient' 'QBittorrent' 'qBittorrent' @{ host = 'localhost'; port = $Script:Ports.qbittorrent; username = $Script:AppUser; password = $Script:AppPass; $catField = $cat } }
  if (Want 'sabnzbd') { Set-FromSchema $url $v $key 'downloadclient' 'Sabnzbd' 'SABnzbd' @{ host = 'localhost'; port = $Script:Ports.sabnzbd; apiKey = $Script:SabKey; $catField = $cat } }
  # A downloader that was removed on this run: drop its entry, or the app keeps reporting it as down.
  foreach ($dl in @(@('qbittorrent', 'qBittorrent'), @('sabnzbd', 'SABnzbd'))) {
    if (Want $dl[0]) { continue }
    @(Api GET "$url/api/$v/downloadclient" $key) | Where-Object { $_.name -eq $dl[1] } | ForEach-Object { Api DELETE "$url/api/$v/downloadclient/$($_.id)" $key | Out-Null; "Removed the $($dl[1]) download client" }
  }
}
function Set-ProwlarrApps {
  $url = "http://localhost:$($Script:Ports.prowlarr)"; $key = Get-ArrKey 'prowlarr'
  $apps = @('radarr', 'sonarr'); if (Want 'lidarr') { $apps += 'lidarr' }
  foreach ($a in $apps) {
    $t = (Get-Culture).TextInfo.ToTitleCase($a)
    Set-FromSchema $url 'v1' $key 'applications' $t $t @{ prowlarrUrl = $url; baseUrl = "http://localhost:$($Script:Ports[$a])"; apiKey = (Get-ArrKey $a) } @{ syncLevel = 'fullSync' }
  }
  if (-not (Want 'lidarr')) {
    @(Api GET "$url/api/v1/applications" $key) | Where-Object { $_.name -eq 'Lidarr' } | ForEach-Object { Api DELETE "$url/api/v1/applications/$($_.id)" $key | Out-Null; 'Removed the Lidarr app (Lidarr was removed)' }
  }
}

function Get-BazarrKey {
  $y = Join-Path $Script:ConfigDir 'bazarr\config\config.yaml'
  if (-not (Test-Path $y)) { return '' }
  $m = [regex]::Match((Get-Content $y -Raw), '(?ms)^auth:\s*\n(?:[ \t]+.*\n)*?[ \t]+apikey:\s*[''"]?([0-9a-f]+)')
  if ($m.Success) { $m.Groups[1].Value } else { '' }
}
function Set-Bazarr {
  for ($i = 0; $i -lt 60 -and -not (Get-BazarrKey); $i++) { Start-Sleep 2 }
  $key = Get-BazarrKey; if (-not $key) { throw 'Bazarr API key not found' }; Add-Secret $key
  $b = "http://localhost:$($Script:Ports.bazarr)"
  $form = [Collections.Generic.List[string]]::new()
  $add = { param($k, $v) $form.Add("$([uri]::EscapeDataString($k))=$([uri]::EscapeDataString([string]$v))") }
  & $add 'settings-general-use_radarr' 'true'; & $add 'settings-general-use_sonarr' 'true'
  & $add 'settings-radarr-ip' '127.0.0.1'; & $add 'settings-radarr-port' $Script:Ports.radarr; & $add 'settings-radarr-apikey' (Get-ArrKey 'radarr'); & $add 'settings-radarr-base_url' '/'
  & $add 'settings-sonarr-ip' '127.0.0.1'; & $add 'settings-sonarr-port' $Script:Ports.sonarr; & $add 'settings-sonarr-apikey' (Get-ArrKey 'sonarr'); & $add 'settings-sonarr-base_url' '/'
  & $add 'settings-auth-type' 'form'; & $add 'settings-auth-username' $Script:AppUser; & $add 'settings-auth-password' $Script:AppPass
  $profiles = @(Invoke-RestMethod "$b/api/system/languages/profiles" -Headers @{ 'X-API-KEY' = $key } | ForEach-Object { $_ })
  if ($profiles.Count -eq 0) {
    $langs = $Script:Choice.Langs -split ','
    foreach ($l in $langs) { & $add 'languages-enabled' $l }
    $items = for ($i = 0; $i -lt $langs.Count; $i++) { [ordered]@{ id = $i + 1; language = $langs[$i]; audio_exclude = 'False'; audio_only_include = 'False'; hi = 'False'; forced = 'False' } }
    & $add 'languages-profiles' (ConvertTo-Json -InputObject @([ordered]@{ profileId = 1; name = "Default ($($Script:Choice.Langs))"; cutoff = $null; items = @($items); mustContain = @(); mustNotContain = @(); originalFormat = $false }) -Depth 10 -Compress)
    & $add 'settings-general-serie_default_enabled' 'true'; & $add 'settings-general-serie_default_profile' '1'
    & $add 'settings-general-movie_default_enabled' 'true'; & $add 'settings-general-movie_default_profile' '1'
    "Creating subtitle profile for: $($Script:Choice.Langs)"
  }
  Invoke-RestMethod -Method Post -Uri "$b/api/system/settings" -Headers @{ 'X-API-KEY' = $key } -ContentType 'application/x-www-form-urlencoded' -Body ($form -join '&') | Out-Null
  $Script:BazarrKey = $key
  'Bazarr connected to Radarr + Sonarr'
}

function Set-Tdarr {
  $t = "http://localhost:$($Script:Ports.tdarr)"
  $creds = @{ username = $Script:AppUser; password = $Script:AppPass } | ConvertTo-Json -Compress
  try { $r = Invoke-RestMethod -Method Post -Uri "$t/api/v2/public/auth/register" -ContentType 'application/json' -Body $creds; "Tdarr admin account created for $Script:AppUser" }
  catch {
    try { $r = Invoke-RestMethod -Method Post -Uri "$t/api/v2/public/auth/login" -ContentType 'application/json' -Body $creds }
    catch {
      # Tdarr already has a different admin (made in its web page): leave it alone, don't fail the install.
      $Script:TdarrManual = $true
      "Tdarr won't accept '$Script:AppUser' (it already has another admin account): libraries not added"; return
    }
  }
  New-Item -ItemType File -Force -Path (Join-Path $Script:ConfigDir 'tdarr\.admin-ready') | Out-Null
  $h = @{ Authorization = "Bearer $($r.token)" }
  $crud = { param($body) Invoke-RestMethod -Method Post -Uri "$t/api/v2/cruddb" -Headers $h -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 30 -Compress) | ForEach-Object { $_ } }
  $libs = @(& $crud @{ data = @{ collection = 'LibrarySettingsJSONDB'; mode = 'getAll'; docID = ''; obj = @{} } })
  # Tdarr stores folders as C:/Media/Movies: compare without slash direction, case or trailing slash.
  $norm = { param($p) ([string]$p).Replace('\', '/').TrimEnd('/').ToLowerInvariant() }
  # Earlier versions of this script added the libraries again on every run: drop our own duplicates.
  $libs | Where-Object { $_._id -like 'shl*' } | Group-Object { & $norm $_.folder } | Where-Object Count -gt 1 | ForEach-Object {
    foreach ($dup in @($_.Group | Select-Object -Skip 1)) { & $crud @{ data = @{ collection = 'LibrarySettingsJSONDB'; mode = 'removeOne'; docID = $dup._id; obj = @{} } } | Out-Null; "Removed duplicate Tdarr library $($dup.name)" }
  }
  $libs = @(& $crud @{ data = @{ collection = 'LibrarySettingsJSONDB'; mode = 'getAll'; docID = ''; obj = @{} } })
  $prio = $libs.Count
  foreach ($lib in @(@('Movies', 'Movies'), @('TV_Shows', 'TV_Shows'))) {
    $folder = Join-Path $Script:Choice.DataDir $lib[1]
    if ($libs | Where-Object { (& $norm $_.folder) -eq (& $norm $folder) }) { "Tdarr library for $folder already exists, leaving it alone"; continue }
    $id = "shl$($lib[0])$(Get-Random -Maximum 99999)"
    $obj = $Script:TdarrTemplate | ConvertFrom-Json
    foreach ($kv in @{ _id = $id; name = $lib[0]; folder = $folder; cache = (Join-Path $Script:Choice.DataDir 'Transcode_Cache'); priority = $prio; createdAt = [long]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds; folderWatching = $true; processTranscodes = $false; processHealthChecks = $true; pluginIDs = @() }.GetEnumerator()) { Set-Prop $obj $kv.Key $kv.Value }
    $obj.decisionMaker.settingsPlugin = $false; $obj.decisionMaker.settingsFlows = $true
    & $crud @{ data = @{ collection = 'LibrarySettingsJSONDB'; mode = 'insert'; docID = $id; obj = $obj } } | Out-Null
    "Tdarr library $($lib[0]) -> $folder (transcoding off)"; $prio++
  }
  # Now that the admin exists, let the node in: seed its key on the server and restart both.
  $sf = Join-Path $Script:ConfigDir 'tdarr\configs\Tdarr_Server_Config.json'
  $cur = Get-Content $sf -Raw | ConvertFrom-Json
  if (-not ($cur.PSObject.Properties['seededApiKey'] -and $cur.seededApiKey -eq $Script:TdarrKey)) {
    Stop-AppService 'tdarr-node'; Stop-AppService 'tdarr'
    [ordered]@{ seededApiKey = $Script:TdarrKey } | Merge-TdarrConfig $sf
    Start-AppService 'tdarr'; Wait-Http 'Tdarr' "$t/api/v2/status" 180; Start-AppService 'tdarr-node'
    'Tdarr node can now sign in (API key seeded on the server)'
  }
}

function Invoke-Wire {
  Step 'Connecting the apps'
  $p = $Script:Ports
  Run 'Securing Radarr login' { Set-ArrAuth "http://localhost:$($p.radarr)" 'v3' (Get-ArrKey 'radarr') }
  Run 'Securing Sonarr login' { Set-ArrAuth "http://localhost:$($p.sonarr)" 'v3' (Get-ArrKey 'sonarr') }
  Run 'Securing Prowlarr login' { Set-ArrAuth "http://localhost:$($p.prowlarr)" 'v1' (Get-ArrKey 'prowlarr') }
  if (Want 'lidarr') { Run 'Securing Lidarr login' { Set-ArrAuth "http://localhost:$($p.lidarr)" 'v1' (Get-ArrKey 'lidarr') } }
  if (Want 'qbittorrent') { Run 'qBittorrent: categories' { Set-QbitCategories } }
  if (Want 'sabnzbd') { Run 'SABnzbd: folders, categories, login' { Set-Sabnzbd } }
  $d = $Script:Choice.DataDir
  Run "Radarr -> $d\Movies + download clients" { Set-Arr 'radarr' 'v3' (Join-Path $d 'Movies') 'movieCategory' 'movies' }
  Run "Sonarr -> $d\TV_Shows + download clients" { Set-Arr 'sonarr' 'v3' (Join-Path $d 'TV_Shows') 'tvCategory' 'tv' }
  if (Want 'lidarr') { Run "Lidarr -> $d\Music + download clients" { Set-Arr 'lidarr' 'v1' (Join-Path $d 'Music') 'musicCategory' 'music' } }
  Run 'Prowlarr -> Radarr + Sonarr (indexer sync)' { Set-ProwlarrApps }
  if (Want 'bazarr') { Run "Bazarr -> Radarr + Sonarr, subtitles: $($Script:Choice.Langs)" { Set-Bazarr } }
  if (Want 'tdarr') {
    Run 'Tdarr -> admin login + Movies & TV libraries' { Set-Tdarr }
    if ($Script:TdarrManual) { Warn 'Tdarr: sign in with your own Tdarr account and add the Movies / TV_Shows libraries yourself (transcoding off).' }
  }
}

# -- 7. Seerr (last: built from source, ~5 minutes) ---------------------------
function Install-Seerr {
  # Seerr needs Node 22 and pnpm (via corepack).
  $nodeDir = Join-Path $Script:AppsDir 'node22'; $node = Join-Path $nodeDir 'node.exe'
  if (-not (Test-Path $node)) {
    $idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json' | ForEach-Object { $_ }
    $rel = $idx | Where-Object { $_.version -like 'v22.*' -and $_.lts } | Select-Object -First 1
    "Node.js $($rel.version)"
    $zip = Join-Path $env:TEMP "node-$($rel.version)-win-x64.zip"; Save-File "https://nodejs.org/dist/$($rel.version)/node-$($rel.version)-win-x64.zip" $zip
    Expand-To $zip "$nodeDir.new"; Remove-Item $zip -Force
    if (Test-Path $nodeDir) { Remove-Item $nodeDir -Recurse -Force }
    Move-Item (Get-ChildItem "$nodeDir.new" -Directory | Select-Object -First 1).FullName $nodeDir; Remove-Item "$nodeDir.new" -Recurse -Force
  }
  $env:Path = "$nodeDir;$env:Path"
  $tag = (Invoke-RestMethod 'https://api.github.com/repos/seerr-team/seerr/releases/latest' -Headers @{ 'User-Agent' = 'sudohomelab' }).tag_name
  "Seerr $tag (source)"
  $dir = Join-Path $Script:AppsDir 'seerr'
  $zip = Join-Path $env:TEMP "seerr-$tag.zip"; Save-File "https://github.com/seerr-team/seerr/archive/refs/tags/$tag.zip" $zip
  Expand-To $zip "$dir.new"; Remove-Item $zip -Force
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  Move-Item (Get-ChildItem "$dir.new" -Directory | Select-Object -First 1).FullName $dir; Remove-Item "$dir.new" -Recurse -Force
  Push-Location $dir
  # pnpm normally hard-links packages from a store in the admin's profile, and a hard link keeps that
  # profile's private permissions: the service account then can't read them (MODULE_NOT_FOUND). So
  # copy real files (they inherit Seerr's folder permissions) from a throwaway store.
  $store = Join-Path $env:TEMP 'sudohomelab-pnpm-store'
  $pn = @("--store-dir=$store", '--package-import-method=copy')
  try {
    $env:CI = 'true'; $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'; $env:NEXT_TELEMETRY_DISABLED = '1'
    $env:npm_config_store_dir = $store; $env:npm_config_package_import_method = 'copy'
    Exec (Join-Path $nodeDir 'corepack.cmd') @('enable', '--install-directory', $nodeDir)
    'Installing Seerr dependencies (pnpm install)...'
    Exec (Join-Path $nodeDir 'pnpm.cmd') (@('install', '--frozen-lockfile') + $pn)
    'Building Seerr (pnpm build) - this is the slow part...'
    Exec (Join-Path $nodeDir 'pnpm.cmd') @('build')
    'Removing build-only packages (pnpm prune --prod)...'
    # prune rejects --store-dir/--package-import-method; it takes them from the npm_config_* above.
    Exec (Join-Path $nodeDir 'pnpm.cmd') @('prune', '--prod', '--ignore-scripts')
  } finally {
    Pop-Location
    if (Test-Path $store) { Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $cfg = Join-Path $Script:ConfigDir 'seerr'; New-Item -ItemType Directory -Force -Path $cfg | Out-Null
  Grant-Access $dir   # Next.js writes its image cache under .next\ at runtime
  Install-AppService 'seerr' 'Seerr' $node "`"$(Join-Path $dir 'dist\index.js')`"" $dir @{ NODE_ENV = 'production'; CONFIG_DIRECTORY = $cfg; PORT = "$($Script:Ports.seerr)" }
}
function Set-Seerr {
  $settings = Join-Path $Script:ConfigDir 'seerr\settings.json'
  if ((Test-Path $settings) -and (@((Get-Content $settings -Raw | ConvertFrom-Json).radarr).Count -gt 0)) {
    Start-AppService 'seerr'; 'Seerr already has Radarr configured'
    Wait-Http 'Seerr' "http://localhost:$($Script:Ports.seerr)/api/v1/status" 120; return
  }
  # First start writes complete defaults (its migrations crash on partial files); then add Radarr/Sonarr.
  Start-AppService 'seerr'
  for ($i = 0; $i -lt 90; $i++) { try { if ((Get-Content $settings -Raw -ErrorAction Stop | ConvertFrom-Json).main.apiKey) { break } } catch { }; Start-Sleep 2 }
  Start-Sleep 3; Stop-AppService 'seerr'
  $s = Get-Content $settings -Raw | ConvertFrom-Json
  Copy-Item $settings "$settings.bak" -Force
  $rp = @(Api GET "http://localhost:$($Script:Ports.radarr)/api/v3/qualityprofile" (Get-ArrKey 'radarr')); $r1 = ($rp | Where-Object name -eq 'HD-1080p' | Select-Object -First 1); if (-not $r1) { $r1 = $rp[0] }
  $sp = @(Api GET "http://localhost:$($Script:Ports.sonarr)/api/v3/qualityprofile" (Get-ArrKey 'sonarr')); $s1 = ($sp | Where-Object name -eq 'HD-1080p' | Select-Object -First 1); if (-not $s1) { $s1 = $sp[0] }
  $common = [ordered]@{ useSsl = $false; baseUrl = ''; tags = @(); is4k = $false; isDefault = $true; syncEnabled = $true; preventSearch = $false; tagRequests = $false; overrideRule = @() }
  $radarr = [ordered]@{ id = 0; name = 'Radarr'; hostname = 'localhost'; port = $Script:Ports.radarr; apiKey = (Get-ArrKey 'radarr'); activeProfileId = $r1.id; activeProfileName = $r1.name; activeDirectory = (Join-Path $Script:Choice.DataDir 'Movies'); externalUrl = "http://$($Script:HostIp):$($Script:Ports.radarr)"; minimumAvailability = 'released' }
  $sonarr = [ordered]@{ id = 0; name = 'Sonarr'; hostname = 'localhost'; port = $Script:Ports.sonarr; apiKey = (Get-ArrKey 'sonarr'); activeProfileId = $s1.id; activeProfileName = $s1.name; activeDirectory = (Join-Path $Script:Choice.DataDir 'TV_Shows'); activeAnimeProfileId = $s1.id; activeAnimeProfileName = $s1.name; activeAnimeDirectory = (Join-Path $Script:Choice.DataDir 'TV_Shows'); externalUrl = "http://$($Script:HostIp):$($Script:Ports.sonarr)"; seriesType = 'standard'; animeSeriesType = 'anime'; enableSeasonFolders = $true; monitorNewItems = 'all'; animeTags = @() }
  foreach ($k in $common.Keys) { $radarr[$k] = $common[$k]; $sonarr[$k] = $common[$k] }
  Set-Prop $s radarr @($radarr); Set-Prop $s sonarr @($sonarr)
  if (Want 'jellyfin') { Set-Prop $s.jellyfin ip 'localhost'; Set-Prop $s.jellyfin port $Script:Ports.jellyfin }
  if (Want 'plex') { Set-Prop $s.plex ip 'localhost'; Set-Prop $s.plex port 32400 }
  [IO.File]::WriteAllText($settings, (ConvertTo-Json -InputObject $s -Depth 50), (New-Object Text.UTF8Encoding($false)))
  Start-AppService 'seerr'
  try { Wait-Http 'Seerr' "http://localhost:$($Script:Ports.seerr)/api/v1/status" 120 }
  catch { 'Seerr failed to start with the pre-configured settings; restoring defaults'; Stop-AppService 'seerr'; Copy-Item "$settings.bak" $settings -Force; Start-AppService 'seerr'; $Script:SeerrManual = $true }
}
function Invoke-Seerr {
  Step 'Seerr (built from source, about 5 minutes)'
  if (-not (Want 'seerr')) { Info 'Seerr not selected'; return }
  Info 'Seerr has no Windows build, so it is compiled now. This takes about 5 minutes; the other apps are already running.'
  Run 'Building Seerr' { Install-Seerr }
  Run 'Seerr -> Radarr + Sonarr' { Set-Seerr }
  if ($Script:SeerrManual) { Warn 'Seerr needs Radarr/Sonarr added by hand (Settings -> Services). Keys are in credentials.txt.' }
}

# -- 8-10. Verify, save, summary ----------------------------------------------
function Invoke-Verify {
  Step 'Verifying connections'
  foreach ($a in @('radarr', 'sonarr') + $(if (Want 'lidarr') { @('lidarr') } else { @() })) {
    $v = 'v3'; if ($a -eq 'lidarr') { $v = 'v1' }
    $url = "http://localhost:$($Script:Ports[$a])"; $key = Get-ArrKey $a; $t = (Get-Culture).TextInfo.ToTitleCase($a)
    $dc = (@(Api GET "$url/api/$v/downloadclient" $key) | ForEach-Object { $_.name }) -join ', '
    if ($dc) { Ok "$t download clients: $dc" } else { Warn "$t has no download client" }
    $rf = (@(Api GET "$url/api/$v/rootfolder" $key) | ForEach-Object { $_.path }) -join ', '
    if ($rf) { Ok "$t root folder: $rf" } else { Warn "$t has no root folder" }
  }
  $apps = (@(Api GET "http://localhost:$($Script:Ports.prowlarr)/api/v1/applications" (Get-ArrKey 'prowlarr')) | ForEach-Object { $_.name }) -join ', '
  if ($apps) { Ok "Prowlarr syncs to: $apps" } else { Warn 'Prowlarr has no apps connected' }
  if (Want 'seerr') { try { Invoke-RestMethod "http://localhost:$($Script:Ports.seerr)/api/v1/status" | Out-Null; Ok 'Seerr is up' } catch { Warn 'Seerr is not responding yet' } }
}

function Save-State {
  $apps = @('radarr', 'sonarr', 'prowlarr') + @('jellyfin', 'plex', 'qbittorrent', 'sabnzbd', 'lidarr', 'bazarr', 'tdarr', 'seerr' | Where-Object { Want $_ })
  [ordered]@{ Server = $Script:Choice.Server; Downloader = $Script:Choice.Downloader; Extras = @($Script:Choice.Extras); Langs = $Script:Choice.Langs
    DataDir = $Script:Choice.DataDir; Account = $Script:Choice.Account; Ports = $Script:Ports; Apps = $apps } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Script:Settings 'state.json') -Encoding UTF8
  Save-Secrets
}
function Save-Secrets {
  @{ AppUser = $Script:AppUser; AppPass = $Script:AppPass; SvcPass = $Script:SvcPass } | ConvertTo-Json | Set-Content (Join-Path $Script:Settings '.secrets.json') -Encoding UTF8
}

function Show-Summary {
  Step 'Done'
  $ip = $Script:HostIp; $p = $Script:Ports
  $rows = [ordered]@{}
  if (Want 'jellyfin') { $rows['Jellyfin'] = "http://${ip}:$($p.jellyfin)" }
  if (Want 'plex') { $rows['Plex'] = "http://${ip}:$($p.plex)/web" }
  if (Want 'seerr') { $rows['Seerr'] = "http://${ip}:$($p.seerr)" }
  $rows['Radarr'] = "http://${ip}:$($p.radarr)"; $rows['Sonarr'] = "http://${ip}:$($p.sonarr)"; $rows['Prowlarr'] = "http://${ip}:$($p.prowlarr)"
  if (Want 'qbittorrent') { $rows['qBittorrent'] = "http://${ip}:$($p.qbittorrent)" }
  if (Want 'sabnzbd') { $rows['SABnzbd'] = "http://${ip}:$($p.sabnzbd)" }
  if (Want 'lidarr') { $rows['Lidarr'] = "http://${ip}:$($p.lidarr)" }
  if (Want 'bazarr') { $rows['Bazarr'] = "http://${ip}:$($p.bazarr)" }
  if (Want 'tdarr') { $rows['Tdarr'] = "http://${ip}:$($p.tdarr)" }
  $cred = Join-Path $Script:Settings 'credentials.txt'
  $lines = @("sudo homelab - media stack ($(Get-Date))", '', 'Login for every app that has one', "  username: $Script:AppUser", "  password: $Script:AppPass", '')
  foreach ($k in $rows.Keys) { $lines += ('{0,-12} {1}' -f $k, $rows[$k]) }
  $lines += '', 'API keys'
  foreach ($a in 'radarr', 'sonarr', 'prowlarr', 'lidarr') { if ($a -ne 'lidarr' -or (Want 'lidarr')) { $lines += ('  {0,-9} {1}' -f $a, (Get-ArrKey $a)) } }
  if ($Script:SabKey) { $lines += "  sabnzbd   $Script:SabKey" }
  if ($Script:BazarrKey) { $lines += "  bazarr    $Script:BazarrKey" }
  if ($Script:Choice.Account -eq 'sudohomelab') { $lines += '', "Service account: .\$Script:SvcUser  password: $Script:SvcPass" }
  $lines | Set-Content $cred -Encoding UTF8

  Write-Host "`n  $($G.Star) Your media stack is running!`n" -ForegroundColor Green
  foreach ($k in $rows.Keys) { Write-Host ('    {0,-12} ' -f $k) -NoNewline; Write-Host $rows[$k] -ForegroundColor Cyan }
  Write-Host "`n    Login  " -ForegroundColor DarkGray -NoNewline; Write-Host "$Script:AppUser / $Script:AppPass" -NoNewline
  if ($Script:GeneratedPass) { Write-Host '  (generated, saved below)' -ForegroundColor DarkGray } else { Write-Host '' }
  Write-Host '    Saved  ' -ForegroundColor DarkGray -NoNewline; Write-Host "$cred (Administrators only)"
  Write-Host "`n  Next steps for you" -ForegroundColor White
  $n = 1
  $steps = @("Prowlarr -> Indexers -> Add Indexer. They sync to Radarr, Sonarr$(if (Want 'lidarr') { ' & Lidarr' }) automatically.")
  if (Want 'jellyfin') { $steps += "Jellyfin -> create your account, add libraries $($Script:Choice.DataDir)\Movies and \TV_Shows" }
  if (Want 'plex') { $steps += "Plex -> sign in at http://localhost:32400/web on this PC, add libraries $($Script:Choice.DataDir)\Movies and \TV_Shows" }
  if (Want 'seerr') { $steps += "Seerr -> sign in with $(if ((Want 'jellyfin')) { "Jellyfin (server URL: http://localhost:$($p.jellyfin))" } else { 'your Plex account' }). Radarr & Sonarr are already connected." }
  if (Want 'sabnzbd') { $steps += 'SABnzbd -> add your usenet provider in the setup wizard.' }
  if (Want 'bazarr') { $steps += 'Bazarr -> Settings -> Providers: pick subtitle sites.' }
  if (Want 'tdarr') { $steps += 'Tdarr -> Movies & TV_Shows libraries are ready with transcoding OFF. Pick a Flow, then turn on Transcodes.' }
  foreach ($s in $steps) { Write-Host ("    {0}. " -f $n++) -ForegroundColor Green -NoNewline; Write-Host $s }
  Write-Host "`n    Manage: services.msc (sudo homelab - ...), settings in $Script:Settings" -ForegroundColor DarkGray
  Write-Host "    Log:    $Script:LogFile" -ForegroundColor DarkGray
  $t = (Get-Date) - $Script:Started
  Write-Host ("    Time:   {0}m {1:00}s`n" -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds) -ForegroundColor DarkGray
}

# -- Removing apps (uninstall, and apps deselected on a re-run) ---------------
function Remove-OurService([string]$name) {
  $svc = Get-Service $name -ErrorAction SilentlyContinue; if (-not $svc) { return }
  if ($svc.Status -ne 'Stopped') { Stop-OurService $name }
  $exe = Join-Path $Script:SvcDir "$name.exe"
  if (Test-Path $exe) { Exec $exe @('uninstall') | Out-Null } else { Exec 'sc.exe' @('delete', $name) | Out-Null }
  Remove-Item (Join-Path $Script:SvcDir "$name.*") -Force -ErrorAction SilentlyContinue
}
function Remove-Plex {
  Stop-ScheduledTask -TaskName 'sudohomelab-plex' -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName 'sudohomelab-plex' -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process 'Plex Media Server' -ErrorAction SilentlyContinue | Stop-Process -Force
  $u = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'Plex Media Server*' } | Select-Object -First 1
  if ($u -and $u.PSObject.Properties['QuietUninstallString'] -and $u.QuietUninstallString) { cmd.exe /c $u.QuietUninstallString | Out-Null }
  elseif ($u -and $u.UninstallString) { cmd.exe /c "$($u.UninstallString) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" | Out-Null }
}
function Remove-QBittorrent {
  $un = Join-Path $Script:AppsDir 'qbittorrent\uninst.exe'
  if (Test-Path $un) { Start-Process $un -ArgumentList '/S' -Wait }
}
function Remove-AppDir([string]$path) {
  if (-not (Test-Path $path)) { return }
  # Unlink junctions first (Tdarr's point into the settings): a recursive delete in PowerShell 5.1 can follow them.
  # Collected before deleting (5.1's -Recurse also walks into junctions); deepest first.
  $links = @(Get-ChildItem $path -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
      Where-Object { $_.FullName.StartsWith($path, 'OrdinalIgnoreCase') } | Sort-Object { $_.FullName.Length } -Descending)
  foreach ($l in $links) { if (Test-Path -LiteralPath $l.FullName) { [IO.Directory]::Delete($l.FullName) } }
  Remove-Item $path -Recurse -Force
}
# What each app owns: its services and program folders. Settings in ConfigDir always stay.
$Script:AppParts = @{
  jellyfin = @{ Svc = @('sudohomelab-jellyfin'); Dirs = @('jellyfin') }
  plex = @{ Svc = @(); Dirs = @() }
  qbittorrent = @{ Svc = @('sudohomelab-qbittorrent'); Dirs = @('qbittorrent') }
  sabnzbd = @{ Svc = @('SABnzbd'); Dirs = @('sabnzbd') }
  lidarr = @{ Svc = @('sudohomelab-lidarr'); Dirs = @('lidarr') }
  bazarr = @{ Svc = @('sudohomelab-bazarr'); Dirs = @('bazarr', 'python312') }
  tdarr = @{ Svc = @('sudohomelab-tdarr-node', 'sudohomelab-tdarr'); Dirs = @('tdarr') }
  seerr = @{ Svc = @('sudohomelab-seerr'); Dirs = @('seerr', 'node22') }
}
function Remove-Deselected {
  foreach ($app in @($Script:Removed)) {
    Run "Removing $app (deselected; its settings stay in $Script:ConfigDir)" {
      $parts = $Script:AppParts[$app]
      foreach ($n in $parts.Svc) { Remove-OurService $n }
      if ($app -eq 'plex') { Remove-Plex }
      if ($app -eq 'qbittorrent') { Remove-QBittorrent }
      foreach ($d in $parts.Dirs) { Remove-AppDir (Join-Path $Script:AppsDir $d) }
    }
  }
}

# -- Uninstall ----------------------------------------------------------------
function Invoke-Uninstall {
  Show-Banner
  $state = Read-State
  if (-not $state -and -not (Get-OurServices)) { Die 'No sudo homelab media stack found on this PC.' }
  Warn 'This stops and removes the media stack apps, their services and firewall rules.'
  if ($Purge) { Warn "-Purge: app settings in $Script:Settings (logins, API keys, libraries) will be deleted too." }
  else { Info "App settings stay in $Script:Settings, so a reinstall brings back your logins and wiring." }
  Info 'Your media folder is never touched.'
  if (-not (Confirm-Yes 'Continue?')) { Info 'Cancelled. Nothing was changed.'; return }
  foreach ($svc in @(Get-OurServices)) { Run "Removing service $($svc.Name)" { Remove-OurService $svc.Name } }
  if (Get-ScheduledTask -TaskName 'sudohomelab-plex' -ErrorAction SilentlyContinue) { Run 'Removing Plex' { Remove-Plex } }
  if (Test-Path (Join-Path $Script:AppsDir 'qbittorrent\uninst.exe')) { Run 'Removing qBittorrent' { Remove-QBittorrent } }
  Run 'Removing firewall rules' { Get-NetFirewallRule -Group $Script:FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
  Run "Deleting $Script:AppsDir" { Remove-AppDir $Script:AppsDir }
  if ($Purge) {
    Run "Deleting $Script:Settings" { if (Test-Path $Script:Settings) { Remove-Item $Script:Settings -Recurse -Force } }
    if (Get-LocalUser -Name $Script:SvcUser -ErrorAction SilentlyContinue) { Run "Removing local user $Script:SvcUser" { Remove-LocalUser -Name $Script:SvcUser } }
    $sys = 'Registry::HKEY_USERS\S-1-5-18\Software\Plex, Inc.'
    if (Test-Path $sys) { Remove-Item $sys -Recurse -Force }
  }
  Ok 'Uninstalled.'
}

# -- Tdarr library template (from Tdarr 3.01's own "new library" defaults) ----
$Script:TdarrTemplate = @'
{"name":"","folder":"","foldersToIgnore":"","foldersToIgnoreCaseInsensitive":false,"folderWatchScanInterval":30,"scannerThreadCount":2,"cache":"","output":"","folderToFolderConversion":false,"folderToFolderConversionDeleteSource":false,"folderToFolderRecordHistory":true,"copyIfConditionsMet":false,"container":".mkv","containerFilter":"mkv,mp4,mov,m4v,mpg,mpeg,avi,flv,webm,wmv,vob,evo,iso,m2ts,ts","folderWatching":false,"useFsEvents":false,"scheduledScanFindNew":false,"processLibrary":true,"processTranscodes":true,"processHealthChecks":true,"scanOnStart":false,"exifToolScan":true,"mediaInfoScan":true,"ffprobeShowData":false,"isDirectoryLibrary":false,"closedCaptionScan":false,"scanButtons":true,"scanFound":"","navItemSelected":"navSourceFolder","pluginIDs":[],"pluginCommunity":true,"handbrake":true,"ffmpeg":false,"handbrakescan":true,"ffmpegscan":false,"preset":"-Z \"Very Fast 1080p30\"","decisionMaker":{"settingsPlugin":true,"settingsFlows":false,"settingsVideo":false,"videoExcludeSwitch":true,"video_codec_names_exclude":[{"codec":"hevc","checked":false},{"codec":"h264","checked":true}],"video_size_range_include":{"min":0,"max":100000},"video_height_range_include":{"min":0,"max":3000},"video_width_range_include":{"min":0,"max":4000},"settingsAudio":false,"audioExcludeSwitch":true,"audio_codec_names_exclude":[{"codec":"mp3","checked":true},{"codec":"aac","checked":false}],"audio_size_range_include":{"min":0,"max":10}},"schedule":[{"_id":"Sun:00-01","checked":true},{"_id":"Sun:01-02","checked":true},{"_id":"Sun:02-03","checked":true},{"_id":"Sun:03-04","checked":true},{"_id":"Sun:04-05","checked":true},{"_id":"Sun:05-06","checked":true},{"_id":"Sun:06-07","checked":true},{"_id":"Sun:07-08","checked":true},{"_id":"Sun:08-09","checked":true},{"_id":"Sun:09-10","checked":true},{"_id":"Sun:10-11","checked":true},{"_id":"Sun:11-12","checked":true},{"_id":"Sun:12-13","checked":true},{"_id":"Sun:13-14","checked":true},{"_id":"Sun:14-15","checked":true},{"_id":"Sun:15-16","checked":true},{"_id":"Sun:16-17","checked":true},{"_id":"Sun:17-18","checked":true},{"_id":"Sun:18-19","checked":true},{"_id":"Sun:19-20","checked":true},{"_id":"Sun:20-21","checked":true},{"_id":"Sun:21-22","checked":true},{"_id":"Sun:22-23","checked":true},{"_id":"Sun:23-00","checked":true},{"_id":"Mon:00-01","checked":true},{"_id":"Mon:01-02","checked":true},{"_id":"Mon:02-03","checked":true},{"_id":"Mon:03-04","checked":true},{"_id":"Mon:04-05","checked":true},{"_id":"Mon:05-06","checked":true},{"_id":"Mon:06-07","checked":true},{"_id":"Mon:07-08","checked":true},{"_id":"Mon:08-09","checked":true},{"_id":"Mon:09-10","checked":true},{"_id":"Mon:10-11","checked":true},{"_id":"Mon:11-12","checked":true},{"_id":"Mon:12-13","checked":true},{"_id":"Mon:13-14","checked":true},{"_id":"Mon:14-15","checked":true},{"_id":"Mon:15-16","checked":true},{"_id":"Mon:16-17","checked":true},{"_id":"Mon:17-18","checked":true},{"_id":"Mon:18-19","checked":true},{"_id":"Mon:19-20","checked":true},{"_id":"Mon:20-21","checked":true},{"_id":"Mon:21-22","checked":true},{"_id":"Mon:22-23","checked":true},{"_id":"Mon:23-00","checked":true},{"_id":"Tue:00-01","checked":true},{"_id":"Tue:01-02","checked":true},{"_id":"Tue:02-03","checked":true},{"_id":"Tue:03-04","checked":true},{"_id":"Tue:04-05","checked":true},{"_id":"Tue:05-06","checked":true},{"_id":"Tue:06-07","checked":true},{"_id":"Tue:07-08","checked":true},{"_id":"Tue:08-09","checked":true},{"_id":"Tue:09-10","checked":true},{"_id":"Tue:10-11","checked":true},{"_id":"Tue:11-12","checked":true},{"_id":"Tue:12-13","checked":true},{"_id":"Tue:13-14","checked":true},{"_id":"Tue:14-15","checked":true},{"_id":"Tue:15-16","checked":true},{"_id":"Tue:16-17","checked":true},{"_id":"Tue:17-18","checked":true},{"_id":"Tue:18-19","checked":true},{"_id":"Tue:19-20","checked":true},{"_id":"Tue:20-21","checked":true},{"_id":"Tue:21-22","checked":true},{"_id":"Tue:22-23","checked":true},{"_id":"Tue:23-00","checked":true},{"_id":"Wed:00-01","checked":true},{"_id":"Wed:01-02","checked":true},{"_id":"Wed:02-03","checked":true},{"_id":"Wed:03-04","checked":true},{"_id":"Wed:04-05","checked":true},{"_id":"Wed:05-06","checked":true},{"_id":"Wed:06-07","checked":true},{"_id":"Wed:07-08","checked":true},{"_id":"Wed:08-09","checked":true},{"_id":"Wed:09-10","checked":true},{"_id":"Wed:10-11","checked":true},{"_id":"Wed:11-12","checked":true},{"_id":"Wed:12-13","checked":true},{"_id":"Wed:13-14","checked":true},{"_id":"Wed:14-15","checked":true},{"_id":"Wed:15-16","checked":true},{"_id":"Wed:16-17","checked":true},{"_id":"Wed:17-18","checked":true},{"_id":"Wed:18-19","checked":true},{"_id":"Wed:19-20","checked":true},{"_id":"Wed:20-21","checked":true},{"_id":"Wed:21-22","checked":true},{"_id":"Wed:22-23","checked":true},{"_id":"Wed:23-00","checked":true},{"_id":"Thur:00-01","checked":true},{"_id":"Thur:01-02","checked":true},{"_id":"Thur:02-03","checked":true},{"_id":"Thur:03-04","checked":true},{"_id":"Thur:04-05","checked":true},{"_id":"Thur:05-06","checked":true},{"_id":"Thur:06-07","checked":true},{"_id":"Thur:07-08","checked":true},{"_id":"Thur:08-09","checked":true},{"_id":"Thur:09-10","checked":true},{"_id":"Thur:10-11","checked":true},{"_id":"Thur:11-12","checked":true},{"_id":"Thur:12-13","checked":true},{"_id":"Thur:13-14","checked":true},{"_id":"Thur:14-15","checked":true},{"_id":"Thur:15-16","checked":true},{"_id":"Thur:16-17","checked":true},{"_id":"Thur:17-18","checked":true},{"_id":"Thur:18-19","checked":true},{"_id":"Thur:19-20","checked":true},{"_id":"Thur:20-21","checked":true},{"_id":"Thur:21-22","checked":true},{"_id":"Thur:22-23","checked":true},{"_id":"Thur:23-00","checked":true},{"_id":"Fri:00-01","checked":true},{"_id":"Fri:01-02","checked":true},{"_id":"Fri:02-03","checked":true},{"_id":"Fri:03-04","checked":true},{"_id":"Fri:04-05","checked":true},{"_id":"Fri:05-06","checked":true},{"_id":"Fri:06-07","checked":true},{"_id":"Fri:07-08","checked":true},{"_id":"Fri:08-09","checked":true},{"_id":"Fri:09-10","checked":true},{"_id":"Fri:10-11","checked":true},{"_id":"Fri:11-12","checked":true},{"_id":"Fri:12-13","checked":true},{"_id":"Fri:13-14","checked":true},{"_id":"Fri:14-15","checked":true},{"_id":"Fri:15-16","checked":true},{"_id":"Fri:16-17","checked":true},{"_id":"Fri:17-18","checked":true},{"_id":"Fri:18-19","checked":true},{"_id":"Fri:19-20","checked":true},{"_id":"Fri:20-21","checked":true},{"_id":"Fri:21-22","checked":true},{"_id":"Fri:22-23","checked":true},{"_id":"Fri:23-00","checked":true},{"_id":"Sat:00-01","checked":true},{"_id":"Sat:01-02","checked":true},{"_id":"Sat:02-03","checked":true},{"_id":"Sat:03-04","checked":true},{"_id":"Sat:04-05","checked":true},{"_id":"Sat:05-06","checked":true},{"_id":"Sat:06-07","checked":true},{"_id":"Sat:07-08","checked":true},{"_id":"Sat:08-09","checked":true},{"_id":"Sat:09-10","checked":true},{"_id":"Sat:10-11","checked":true},{"_id":"Sat:11-12","checked":true},{"_id":"Sat:12-13","checked":true},{"_id":"Sat:13-14","checked":true},{"_id":"Sat:14-15","checked":true},{"_id":"Sat:15-16","checked":true},{"_id":"Sat:16-17","checked":true},{"_id":"Sat:17-18","checked":true},{"_id":"Sat:18-19","checked":true},{"_id":"Sat:19-20","checked":true},{"_id":"Sat:20-21","checked":true},{"_id":"Sat:21-22","checked":true},{"_id":"Sat:22-23","checked":true},{"_id":"Sat:23-00","checked":true}],"totalHealthCheckCount":0,"totalTranscodeCount":0,"sizeDiff":0,"holdNewFiles":false,"holdFor":3600,"holdForDisplayUnit":"hours","pluginStackOverview":true,"filterResolutionsSkip":"","filterCodecsSkip":"","filterContainersSkip":"","filterHardlinked":false,"processPluginsSequentially":true}
'@

# -- Main ---------------------------------------------------------------------
function Invoke-Main {
  if ($Help) {
    Get-Help -Detailed $PSCommandPath -ErrorAction SilentlyContinue
    @'
Options: -Server jellyfin|plex|both  -Downloader qbittorrent,sabnzbd  -Extras lidarr,bazarr,tdarr,seerr|none
         -SubtitleLangs en,es  -DataDir D:\Media  -Username NAME  -Password PASS
         -ServiceAccount sudohomelab|localsystem  -Yes  -DryRun  -Uninstall [-Purge]
'@ | Write-Host
    return
  }
  if (-not (Test-Admin)) {
    # Re-launch elevated. When piped from irm | iex there's no file, so fetch the script to one.
    $self = $PSCommandPath
    if (-not $self) { $self = Join-Path $env:TEMP 'sudohomelab-media-stack.ps1'; (New-Object Net.WebClient).DownloadFile($Script:ScriptUrl, $self) }
    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    foreach ($kv in $Script:BoundParams.GetEnumerator()) {
      if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
      elseif ($kv.Value -is [array]) { $argList += "-$($kv.Key)", ('"' + ($kv.Value -join ',') + '"') }
      else { $argList += "-$($kv.Key)", "`"$($kv.Value)`"" }
    }
    Write-Host 'Asking for administrator rights (a UAC prompt will appear)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
  }
  New-Item -ItemType Directory -Force -Path $Script:LogDir | Out-Null
  Write-ShlLog "sudo homelab media-stack $Script:Version - $([Environment]::OSVersion.VersionString) - PS $($PSVersionTable.PSVersion)"
  if ($Uninstall) { Invoke-Uninstall; return }
  Show-Banner
  Invoke-Preflight
  Invoke-Choose
  Invoke-Prepare
  Invoke-Programs
  Invoke-Start
  Invoke-Wire
  Save-State
  Invoke-Seerr
  Invoke-Verify
  Show-Summary
}

try {
  Invoke-Main
} catch {
  if ("$_" -in 'sudohomelab-done') { return }
  if ("$_" -ne 'sudohomelab-abort') {
    Write-ShlLog "FAILED: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Write-Host ("`n$($G.Top)$($G.Bar) Installation failed " + ($G.Bar * 46)) -ForegroundColor Red
    Write-Host "$($G.VBar) Step:    $($Script:CurrentStep)" -ForegroundColor Red
    Write-Host "$($G.VBar) Failed:  $(if ($Script:LastRun) { $Script:LastRun } else { $_.Exception.Message })" -ForegroundColor Red
    Write-Host "$($G.VBar) Error:   $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$($G.VBar) Log:     $Script:LogFile" -ForegroundColor Red
    Write-Host ($G.Bottom + ($G.Bar * 68)) -ForegroundColor Red
    Write-Host 'Last lines of the log:' -ForegroundColor DarkGray
    Get-Content $Script:LogFile -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host "`nThe script is safe to re-run: finished steps are redone or skipped.`nReport issues: https://github.com/Eportela99/sudohomelab/issues (attach the log)`n"
  }
  # From a file (the elevated window): exit with an error code. Piped into iex: don't close the user's shell.
  if ($PSCommandPath) { exit 1 }
}
