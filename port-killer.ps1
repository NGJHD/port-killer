<#
    port-killer.ps1  --  scan listening TCP ports, work out which ones are dev
    servers (vite/next/python/etc), render a local port.html, and run a tiny
    127.0.0.1 helper so the Kill buttons on that page actually work.

    Launched by port-killer.bat. Close the console window to stop the helper.
#>
[CmdletBinding()]
param(
    [int]$HelperPort = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$htmlPath  = Join-Path $scriptDir 'port.html'

# ---------------------------------------------------------------- heuristics --

$devPorts = @(
    1420,3000,3001,3002,3003,3004,3005,3006,3007,3008,3010,3333,
    4000,4173,4174,4200,4321,
    5000,5001,5002,5100,5173,5174,5175,5176,5177,5178,5179,5180,5273,5500,
    6006,6060,7777,
    8000,8001,8002,8008,8080,8081,8082,8083,8085,8088,8090,8501,8787,
    9000,9090,9229
)

$devNames = @(
    'node.exe','bun.exe','deno.exe','python.exe','pythonw.exe','py.exe',
    'ruby.exe','php.exe','dotnet.exe','go.exe','java.exe','cargo.exe',
    'caddy.exe','esbuild.exe','next-server.exe','uvicorn.exe','flask.exe',
    'http-server.exe','vite.exe','wrangler.exe','ngrok.exe','tauri.exe'
)

# ------------------------------------------------------------------- helpers --

function Get-ProcessTable {
    $t = @{}
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $t[[int]$p.ProcessId] = [pscustomobject]@{
            Id          = [int]$p.ProcessId
            Name        = [string]$p.Name
            CommandLine = [string]$p.CommandLine
            ParentId    = [int]$p.ParentProcessId
            Path        = [string]$p.ExecutablePath
            Started     = $p.CreationDate
        }
    }
    return $t
}

function Get-Ancestry {
    param($Table, [int]$ProcId, [int]$MaxDepth = 14)
    $chain = New-Object System.Collections.ArrayList
    $seen  = @{}
    $cur   = $ProcId
    for ($i = 0; $i -lt $MaxDepth; $i++) {
        if (-not $Table.ContainsKey($cur)) { break }
        if ($seen.ContainsKey($cur))       { break }
        $seen[$cur] = $true
        $node = $Table[$cur]
        [void]$chain.Add($node)
        if ($node.ParentId -le 0 -or $node.ParentId -eq $cur) { break }
        $cur = $node.ParentId
    }
    return $chain
}

# a coding-agent CLI: whatever it spawned is a dev server, however odd the port
function Test-AgentProcess {
    param($Proc)
    if (-not $Proc) { return $false }
    if ($Proc.Name -match '^(claude|codex|cursor-agent)(\.exe)?$') { return $true }
    $cl = $Proc.CommandLine
    if ($cl) {
        if ($cl -match '@anthropic-ai[\\/]claude-code')                  { return $true }
        if ($cl -match '[\\/](claude|codex)(-code)?\.(exe|cmd|bat|js)')  { return $true }
        if ($cl -match '[\\/]\.(claude|codex|cursor)[\\/]')              { return $true }
        if ($cl -match 'claude-code[\\/]cli\.js')                        { return $true }
    }
    return $false
}

# directories that are never the thing the user is looking at
$boringDirs = '\\(Windows|Program Files|Program Files \(x86\)|nvm4w|nodejs|ProgramData)\\|\\AppData\\(Roaming\\npm|Local\\Programs|Local\\Microsoft)\\'

function Split-CommandLine {
    param([string]$CommandLine)
    $parts = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($CommandLine, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { [void]$parts.Add($m.Groups[1].Value) }
        else                      { [void]$parts.Add($m.Groups[2].Value) }
    }
    return $parts
}

function Resolve-Dir {
    param([string]$Value)
    if (-not $Value) { return $null }
    $v = $Value.Trim().TrimEnd('\', '/', ' ')
    if ($v -notmatch '[\\/]') { return $null }
    if ($v -match $boringDirs) { return $null }
    try {
        if (Test-Path -LiteralPath $v -PathType Container) { return $v }
        $parent = Split-Path -Parent $v
        if ($parent -and ($parent -notmatch $boringDirs) -and (Test-Path -LiteralPath $parent -PathType Container)) {
            return $parent
        }
    } catch {}
    return $null
}

function Get-ProjectGuess {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    # the folder that owns a node_modules reference is almost always the project root,
    # and this survives unquoted paths with spaces ("C:\src\My Project\node_modules\...")
    if ($CommandLine -match '([A-Za-z]:\\(?:[^"''<>|*?\r\n]+?))\\node_modules') {
        $hit = Resolve-Dir $matches[1]
        if ($hit) { return $hit }
    }
    # otherwise walk the arguments (skipping argv[0], the interpreter itself)
    $parts = Split-CommandLine $CommandLine
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $hit = Resolve-Dir $parts[$i]
        if ($hit) { return $hit }
    }
    return $null
}

# agent config sitting in a folder means something was being developed there, and
# that is the only tell left once the session that started the server has exited
$agentMarkers = @('.claude', 'CLAUDE.md', '.codex', 'AGENTS.md', '.cursor')

function Test-AgentProject {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    foreach ($marker in $agentMarkers) {
        try {
            if (Test-Path -LiteralPath (Join-Path $Dir $marker)) { return $true }
        } catch {}
    }
    return $false
}

function Get-HttpProbe {
    param([int]$Port)
    $info = [ordered]@{ http = $false; title = $null; server = $null; status = $null }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/")
        $req.Method            = 'GET'
        $req.Timeout           = 1200
        $req.ReadWriteTimeout  = 1200
        $req.AllowAutoRedirect = $true
        $req.UserAgent         = 'port-killer'
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { return $info }
    } catch {
        return $info
    }
    try {
        $info.http   = $true
        $info.server = [string]$resp.Headers['Server']
        try { $info.status = [int]$resp.StatusCode } catch {}
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $buf    = New-Object char[] 8192
        $n      = $reader.Read($buf, 0, 8192)
        if ($n -gt 0) {
            $body = -join $buf[0..($n - 1)]
            if ($body -match '(?is)<title[^>]*>(.*?)</title>') {
                $t = ($matches[1] -replace '\s+', ' ').Trim()
                if ($t) { $info.title = $t }
            }
        }
        $reader.Dispose()
    } catch {
    } finally {
        if ($resp) { try { $resp.Close() } catch {} }
    }
    return $info
}

function Get-Listeners {
    $rows  = New-Object System.Collections.ArrayList
    $conns = $null
    try { $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop } catch { $conns = $null }
    if ($conns) {
        foreach ($c in $conns) {
            [void]$rows.Add([pscustomobject]@{
                Port    = [int]$c.LocalPort
                Address = [string]$c.LocalAddress
                ProcId  = [int]$c.OwningProcess
            })
        }
    } else {
        foreach ($line in (& netstat.exe -ano -p TCP)) {
            if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                [void]$rows.Add([pscustomobject]@{
                    Port    = [int]$matches[2]
                    Address = [string]$matches[1]
                    ProcId  = [int]$matches[3]
                })
            }
        }
    }
    return $rows
}

# processes we must never offer to kill: this helper and everything above it
# (that chain is the console window and whatever session launched it)
$script:ProtectedIds = @()
try {
    $bootTable = Get-ProcessTable
    $script:ProtectedIds = @(Get-Ancestry -Table $bootTable -ProcId $PID | ForEach-Object { $_.Id })
} catch {}

function Get-Scan {
    param([int]$SelfHelperPort = 0)

    $table     = Get-ProcessTable
    $listeners = Get-Listeners

    $byKey = @{}
    foreach ($l in $listeners) {
        if ($l.ProcId -le 4) { continue }
        $key = "$($l.Port)|$($l.ProcId)"
        if (-not $byKey.ContainsKey($key)) {
            $byKey[$key] = [pscustomobject]@{
                Port      = $l.Port
                ProcId    = $l.ProcId
                Addresses = New-Object System.Collections.ArrayList
            }
        }
        if (-not $byKey[$key].Addresses.Contains($l.Address)) {
            [void]$byKey[$key].Addresses.Add($l.Address)
        }
    }

    $rows   = New-Object System.Collections.ArrayList
    $probes = 0

    foreach ($key in $byKey.Keys) {
        $entry = $byKey[$key]
        if ($SelfHelperPort -gt 0 -and $entry.Port -eq $SelfHelperPort) { continue }

        $proc     = $null
        $procName = 'unknown'
        if ($table.ContainsKey($entry.ProcId)) {
            $proc     = $table[$entry.ProcId]
            $procName = $proc.Name
        }

        $chain = @()
        if ($proc) { $chain = Get-Ancestry -Table $table -ProcId $entry.ProcId }
        $agentAnchor = $null
        foreach ($node in $chain) {
            if (Test-AgentProcess -Proc $node) { $agentAnchor = $node; break }
        }

        $cmdline = ''
        if ($proc -and $proc.CommandLine) { $cmdline = $proc.CommandLine }

        $project = Get-ProjectGuess -CommandLine $cmdline

        $origin = 'other'
        $via    = $null
        if ($agentAnchor) {
            $origin = 'dev'
            $via    = "started from an agent session (PID $($agentAnchor.Id))"
        } elseif (($devNames -contains $procName) -or ($devPorts -contains $entry.Port)) {
            $origin = 'dev'
            # a dev server whose session has already exited is orphaned onto
            # explorer/init, so the folder it serves is the only tell left
            if (Test-AgentProject -Dir $project) {
                $via = 'left over from a session that has already exited'
            }
        }

        $probe = [ordered]@{ http = $false; title = $null; server = $null; status = $null }
        if (($origin -ne 'other') -and ($probes -lt 40)) {
            $probes++
            $probe = Get-HttpProbe -Port $entry.Port
        }

        $app = $probe.title
        if (-not $app -and $project) { $app = Split-Path -Leaf $project }
        if (-not $app) { $app = $procName }

        $ancestryText = ($chain | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ' < '

        $started = $null
        if ($proc -and $proc.Started) {
            try { $started = ([datetime]$proc.Started).ToString('yyyy-MM-dd HH:mm') } catch {}
        }

        [void]$rows.Add([ordered]@{
            port       = $entry.Port
            pid        = $entry.ProcId
            app        = $app
            title      = $probe.title
            process    = $procName
            origin     = $origin
            protected  = ($script:ProtectedIds -contains $entry.ProcId)
            via        = $via
            project    = $project
            cmdline    = $cmdline
            ancestry   = $ancestryText
            addresses  = ($entry.Addresses -join ', ')
            http       = [bool]$probe.http
            httpStatus = $probe.status
            server     = $probe.server
            started    = $started
            url        = "http://localhost:$($entry.Port)/"
            killCmd    = "taskkill /PID $($entry.ProcId) /T /F"
        })
    }

    $rank   = @{ 'dev' = 0; 'other' = 1 }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { $rank[$_.origin] } }, @{ Expression = { $_.port } })

    return [ordered]@{
        scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        machine   = $env:COMPUTERNAME
        counts    = [ordered]@{
            dev   = @($sorted | Where-Object { $_.origin -eq 'dev' }).Count
            other = @($sorted | Where-Object { $_.origin -eq 'other' }).Count
        }
        rows      = $sorted
    }
}

function Invoke-Kill {
    param([int]$TargetPid)
    $local:ErrorActionPreference = 'Continue'
    if ($TargetPid -le 4) {
        return [ordered]@{ ok = $false; message = 'Refused: system process.' }
    }
    if ($script:ProtectedIds -contains $TargetPid) {
        return [ordered]@{ ok = $false; message = 'Refused: that is this tool (or the shell that launched it).' }
    }
    $proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        return [ordered]@{ ok = $true; message = "PID $TargetPid is already gone." }
    }
    $name = $proc.ProcessName
    $out  = & taskkill.exe /PID $TargetPid /T /F 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String).Trim()
    if ($code -eq 0) {
        return [ordered]@{ ok = $true; message = "Killed $name (PID $TargetPid) and its children." }
    }
    return [ordered]@{ ok = $false; message = "taskkill exit ${code}: $text" }
}

# ------------------------------------------------------------------ the page --

$htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Port Killer</title>
<style>
  /* palette, type and background lifted from the personal-site design system */
  :root{
    --bg:#0a0d12; --surface:#12161d; --raised:#1a2028;
    --border:#262e38; --border-bright:#3a4552;
    --ink:#edf1f5; --dim:#8c99a8; --faint:#7a8592;
    --accent:#4fd8da; --accent-soft:rgba(79,216,218,.12); --accent-line:rgba(79,216,218,.35);
    --live:#5fd97a; --live-soft:rgba(95,217,122,.12); --live-line:rgba(95,217,122,.35);
    --danger:#f2545b; --danger-soft:rgba(242,84,91,.12); --danger-line:rgba(242,84,91,.4);
    --display:"Space Grotesk","Segoe UI Variable Display","Segoe UI",sans-serif;
    --body:"Inter","Segoe UI",system-ui,sans-serif;
    --mono:"IBM Plex Mono","Cascadia Mono",Consolas,monospace;
    color-scheme:dark;
  }
  *{box-sizing:border-box}
  /* one big cyan orb, pinned to the viewport so it lights the page rather than
     scrolling away with the list. It paints on the canvas, under the grid. */
  body{margin:0;background-color:var(--bg);color:var(--ink);
       background-image:radial-gradient(circle 50vmax at 50% 50%,
         rgba(79,216,218,.26) 0%,rgba(79,216,218,.14) 30%,
         rgba(79,216,218,.05) 54%,transparent 74%);
       background-repeat:no-repeat;background-attachment:fixed;
       font:14px/1.6 var(--body);-webkit-font-smoothing:antialiased}

  /* the grid sits on the canvas behind everything and never scrolls, so its
     56px tiling stays continuous however long the list gets */
  body::before{content:"";position:fixed;inset:0;z-index:-1;
    background-image:linear-gradient(to right,rgba(79,216,218,.09) 1px,transparent 1px),
      linear-gradient(to bottom,rgba(79,216,218,.09) 1px,transparent 1px);
    background-size:56px 56px}
  body::after{content:"";position:fixed;left:0;right:0;top:0;height:140px;z-index:-1;
    pointer-events:none;
    background:linear-gradient(to bottom,transparent,rgba(79,216,218,.04),transparent);
    animation:scan 9s linear infinite}
  @keyframes scan{0%{transform:translateY(-140px)}100%{transform:translateY(100vh)}}

  a{color:var(--accent)}
  ::selection{background:var(--accent-line);color:var(--ink)}
  :focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:2px}

  .wrap{max-width:1180px;margin:0 auto;padding:30px 22px 64px}
  header{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
  h1{margin:0;font:600 21px/1.2 var(--display);letter-spacing:-.01em}
  .sub{color:var(--faint);font:12px var(--mono)}

  /* the one HUD panel on the page: notched corners, hatched fill, corner brackets */
  .bar{position:relative;display:flex;gap:10px;align-items:center;flex-wrap:wrap;
       margin:20px 0 16px;padding:14px 16px;border:1px solid rgba(79,216,218,.4);
       border-radius:2px;
       background:
         linear-gradient(90deg,transparent,rgba(79,216,218,.7) 18%,rgba(79,216,218,.7) 82%,transparent)
           top / 100% 2px no-repeat,
         repeating-linear-gradient(135deg,rgba(79,216,218,.05) 0px,rgba(79,216,218,.05) 1px,
           transparent 1px,transparent 9px),
         linear-gradient(165deg,rgba(20,25,33,.82),rgba(15,19,25,.68));
       box-shadow:0 0 0 1px rgba(79,216,218,.06) inset,0 16px 36px rgba(0,0,0,.4);
       clip-path:polygon(12px 0%,100% 0%,100% calc(100% - 12px),calc(100% - 12px) 100%,0% 100%,0% 12px)}
  .bar::before,.bar::after{content:"";position:absolute;width:8px;height:8px;
       pointer-events:none;opacity:.95;
       filter:drop-shadow(0 0 4px rgba(79,216,218,.7))}
  .bar::before{top:5px;right:5px;border-top:2px solid var(--accent);border-right:2px solid var(--accent)}
  .bar::after{bottom:5px;left:5px;border-bottom:2px solid var(--accent);border-left:2px solid var(--accent)}

  .chip{padding:6px 12px;border-radius:3px;border:1px solid var(--border);
        background:var(--surface);color:var(--dim);cursor:pointer;
        font:500 12.5px var(--body);
        transition:color .15s,border-color .15s,background .15s}
  .chip:hover{color:var(--ink);border-color:var(--border-bright)}
  .chip.on{background:var(--accent-soft);border-color:var(--accent-line);color:var(--ink)}
  .chip .n{font:11.5px var(--mono);color:var(--faint);margin-left:8px}
  .chip.on .n{color:var(--accent)}

  input[type=search]{flex:1;min-width:190px;background:rgba(10,13,18,.6);
        border:1px solid var(--border);border-radius:3px;color:var(--ink);
        padding:8px 11px;font:13px var(--mono)}
  input[type=search]::placeholder{color:var(--faint)}
  input[type=search]:focus{outline:none;border-color:var(--accent-line);
        box-shadow:0 0 0 3px rgba(79,216,218,.1)}
  .spacer{flex:1}
  .btn{background:var(--surface);border:1px solid var(--border);color:var(--dim);
       border-radius:3px;padding:7px 13px;cursor:pointer;font:500 12.5px var(--body);
       transition:color .15s,border-color .15s,background .15s}
  .btn:hover{color:var(--ink);border-color:var(--accent-line);background:var(--accent-soft)}
  .status{display:flex;align-items:center;gap:7px;font:12px var(--mono);color:var(--dim)}
  .status input[type=checkbox]{accent-color:var(--accent);width:14px;height:14px;cursor:pointer}
  .dot{width:7px;height:7px;border-radius:50%;background:var(--faint);flex:none}
  .dot.live{background:var(--live);box-shadow:0 0 8px rgba(95,217,122,.6)}
  .dot.dead{background:var(--danger);box-shadow:0 0 8px rgba(242,84,91,.5)}

  .banner{display:none;margin:0 0 16px;padding:12px 15px;border-radius:2px;
          border:1px solid var(--danger-line);border-left:2px solid var(--danger);
          background:var(--danger-soft);color:#ffd2d4;font-size:13px}
  .banner.show{display:block}

  table{width:100%;border-collapse:separate;border-spacing:0 8px}
  thead th{text-align:left;padding:0 14px 4px;font:500 11px/1 var(--mono);
           letter-spacing:.16em;text-transform:uppercase;color:var(--accent);
           text-shadow:0 0 18px rgba(79,216,218,.35)}
  tbody td{background:rgba(18,22,29,.7);padding:12px 14px;vertical-align:middle;
           border-top:1px solid var(--border);border-bottom:1px solid var(--border);
           transition:background .15s,border-color .15s}
  tbody td:first-child{border-left:1px solid var(--border);border-radius:2px 0 0 2px;width:132px}
  tbody td:last-child{border-right:1px solid var(--border);border-radius:0 2px 2px 0}
  tbody tr:hover td{background:rgba(26,32,40,.9);border-color:var(--border-bright)}
  /* the row's own badge says which edge light it gets */
  tbody tr:has(.b-dev):hover td:first-child{box-shadow:inset 2px 0 0 var(--live)}
  tbody tr:has(.b-other):hover td:first-child{box-shadow:inset 2px 0 0 var(--border-bright)}

  .port{font:600 17px/1 var(--mono);font-variant-numeric:tabular-nums}
  .port a{text-decoration:none;color:var(--ink)}
  .port a:hover{color:var(--accent);text-shadow:0 0 12px rgba(79,216,218,.45)}
  .badge{display:inline-block;margin-top:8px;padding:4px 7px;border-radius:3px;
         font:500 10.5px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;
         border:1px solid var(--border);background:var(--raised);color:var(--dim)}
  .b-dev{color:var(--live);border-color:var(--live-line);background:var(--live-soft)}
  .b-other{color:var(--faint)}
  .app{font:600 14.5px var(--display)}
  .meta{color:var(--dim);font-size:12px;margin-top:4px}
  .cmd{color:var(--faint);font:11.5px/1.5 var(--mono);
       margin-top:6px;max-width:600px;overflow:hidden;text-overflow:ellipsis;
       white-space:nowrap;cursor:pointer}
  .cmd:hover{color:var(--dim)}
  .cmd.open{white-space:normal;word-break:break-all}

  .act{text-align:right;white-space:nowrap}
  .kill{background:var(--danger-soft);border:1px solid var(--danger-line);color:var(--danger);
        border-radius:3px;padding:7px 13px;cursor:pointer;
        font:500 12.5px var(--mono);letter-spacing:.06em;text-transform:uppercase;
        transition:background .15s,box-shadow .15s,color .15s}
  .kill:hover{background:rgba(242,84,91,.2);color:#ff8f93;
              box-shadow:0 0 16px rgba(242,84,91,.18)}
  .kill:disabled{opacity:.4;cursor:not-allowed;background:var(--surface);
                 border-color:var(--border);color:var(--faint);box-shadow:none}
  .copy{background:none;border:1px solid var(--border);color:var(--dim);border-radius:3px;
        padding:7px 11px;cursor:pointer;font:500 12px var(--body);margin-right:7px;
        transition:color .15s,border-color .15s,background .15s}
  .copy:hover{color:var(--ink);border-color:var(--accent-line);background:var(--accent-soft)}

  .empty{padding:40px;text-align:center;color:var(--dim);background:var(--surface);
         border:1px solid var(--border);border-radius:2px}
  .toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);
         background:var(--raised);border:1px solid var(--border);
         border-left:2px solid var(--accent);color:var(--ink);
         padding:11px 16px;border-radius:2px;font-size:13px;opacity:0;
         transition:opacity .18s;pointer-events:none;box-shadow:0 16px 36px rgba(0,0,0,.5)}
  .toast.show{opacity:1}
  footer{margin-top:28px;color:var(--faint);font-size:12px;line-height:1.7}
  code{font:12px var(--mono);color:var(--dim)}

  @media (prefers-reduced-motion:reduce){
    body::after{display:none}
    *{animation-duration:.01ms !important;transition-duration:.01ms !important}
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Port Killer</h1>
    <span class="sub" id="stamp"></span>
  </header>

  <div id="banner" class="banner"></div>

  <div class="bar">
    <button class="chip on" data-f="dev">Dev servers<span class="n" id="c-dev">0</span></button>
    <button class="chip" data-f="other">Everything else<span class="n" id="c-other">0</span></button>
    <input type="search" id="q" placeholder="filter by port, app, process, path...">
    <span class="spacer"></span>
    <label class="status" title="re-scan every 6 seconds"><input type="checkbox" id="auto" checked> auto</label>
    <button class="btn" id="rescan">Rescan</button>
    <span class="status"><span class="dot" id="dot"></span><span id="helperTxt">helper</span></span>
  </div>

  <div id="out"></div>

  <footer>
    Kill buttons talk to the local helper at <code>__HELPER__</code>, started by
    <code>port-killer.bat</code>. Close that console window to stop it &mdash; this page keeps
    working as a read-only snapshot.
  </footer>
</div>
<div class="toast" id="toast"></div>

<script>
const HELPER = "__HELPER__";
let data = __DATA__;
let filters = new Set(["dev"]);
let timer = null;

const $ = (id) => document.getElementById(id);

function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(t._h);
  t._h = setTimeout(() => t.classList.remove("show"), 2800);
}

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function rowsOf(d) {
  if (!d || !d.rows) return [];
  return Array.isArray(d.rows) ? d.rows : [d.rows];
}

function render() {
  const rows = rowsOf(data);
  const counts = (data && data.counts) || { dev: 0, other: 0 };
  $("c-dev").textContent = counts.dev;
  $("c-other").textContent = counts.other;
  $("stamp").textContent = "scanned " + (data ? data.scannedAt : "?") +
    (data && data.machine ? " on " + data.machine : "");

  const q = $("q").value.trim().toLowerCase();
  const shown = rows.filter((r) => {
    if (!filters.has(r.origin)) return false;
    if (!q) return true;
    return [r.port, r.app, r.process, r.pid, r.project, r.cmdline, r.title]
      .join(" ").toLowerCase().indexOf(q) !== -1;
  });

  if (!shown.length) {
    $("out").innerHTML = '<div class="empty">Nothing listening that matches those filters.</div>';
    return;
  }

  const body = shown.map((r) => {
    const badge = r.origin === "dev" ? '<span class="badge b-dev">dev server</span>'
                                     : '<span class="badge b-other">other</span>';
    const meta = [esc(r.process) + " &middot; PID " + r.pid];
    if (r.started) meta.push("up since " + esc(r.started));
    if (r.via) meta.push(esc(r.via));
    if (r.httpStatus) meta.push("HTTP " + r.httpStatus);
    const proj = r.project ? '<div class="meta">' + esc(r.project) + "</div>" : "";
    const cmd = r.cmdline ? '<div class="cmd" title="click to expand">' + esc(r.cmdline) + "</div>" : "";
    const killBtn = r.protected
      ? '<button class="kill" disabled title="protected: this tool and the shell that launched it">Protected</button>'
      : '<button class="kill" data-pid="' + r.pid + '">Kill</button>';
    const portCell = r.http
      ? '<a href="' + esc(r.url) + '" target="_blank" rel="noreferrer">' + r.port + "</a>"
      : r.port;
    return "<tr>" +
      '<td><div class="port">' + portCell + "</div>" + badge + "</td>" +
      '<td><div class="app">' + esc(r.app) + "</div>" +
        '<div class="meta">' + meta.join(" &middot; ") + "</div>" + proj + cmd + "</td>" +
      '<td class="act">' +
        '<button class="copy" data-copy="' + esc(r.killCmd) + '">copy taskkill</button>' +
        killBtn +
      "</td></tr>";
  }).join("");

  $("out").innerHTML =
    "<table><thead><tr><th>Port</th><th>App</th><th style='text-align:right'>Action</th></tr></thead>" +
    "<tbody>" + body + "</tbody></table>";
}

function setLive(v, note) {
  $("dot").className = "dot " + (v ? "live" : "dead");
  $("helperTxt").textContent = v ? "helper live" : "helper offline";
  const b = $("banner");
  if (v) {
    b.classList.remove("show");
  } else {
    b.innerHTML = note || ("Helper is not running, so this is a frozen snapshot. " +
      "Re-run <code>port-killer.bat</code> to refresh and re-enable the Kill buttons " +
      "(the <em>copy taskkill</em> buttons still work).");
    b.classList.add("show");
  }
  const btns = document.querySelectorAll(".kill[data-pid]");
  for (let i = 0; i < btns.length; i++) { btns[i].disabled = !v; }
}

async function call(path) {
  const r = await fetch(HELPER + path, { cache: "no-store" });
  if (!r.ok) throw new Error("helper " + r.status);
  return r.json();
}

async function rescan(quiet) {
  try {
    data = await call("/scan");
    render();
    setLive(true);
  } catch (e) {
    setLive(false);
    if (!quiet) toast("Helper is not reachable.");
  }
}

function schedule() {
  clearInterval(timer);
  if ($("auto").checked) timer = setInterval(() => rescan(true), 6000);
}

document.addEventListener("click", async (e) => {
  const chip = e.target.closest(".chip");
  if (chip) {
    const f = chip.dataset.f;
    if (filters.has(f)) { filters.delete(f); chip.classList.remove("on"); }
    else { filters.add(f); chip.classList.add("on"); }
    render();
    return;
  }

  const cmd = e.target.closest(".cmd");
  if (cmd) { cmd.classList.toggle("open"); return; }

  const copy = e.target.closest("[data-copy]");
  if (copy) {
    const txt = copy.dataset.copy;
    try {
      await navigator.clipboard.writeText(txt);
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = txt;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    toast("Copied: " + txt);
    return;
  }

  const kill = e.target.closest(".kill");
  if (kill && kill.dataset.pid && !kill.disabled) {
    kill.disabled = true;
    kill.textContent = "killing...";
    try {
      const res = await call("/kill?pid=" + encodeURIComponent(kill.dataset.pid));
      toast(res.message || (res.ok ? "Killed." : "Failed."));
    } catch (_) {
      setLive(false);
      toast("Helper is not reachable.");
    }
    setTimeout(() => rescan(true), 400);
  }
});

$("rescan").addEventListener("click", () => rescan(false));
$("q").addEventListener("input", render);
$("auto").addEventListener("change", schedule);

render();
setLive(false, "Contacting helper...");
rescan(true);
schedule();
</script>
</body>
</html>
'@

function Write-Page {
    param($Payload, [string]$HelperUrl)
    $json = ConvertTo-Json -InputObject $Payload -Depth 6 -Compress
    $html = $htmlTemplate.Replace('__DATA__', $json).Replace('__HELPER__', $HelperUrl)
    [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-CorsHeaders {
    # the page is opened as file:// so its origin is "null"; it also lives in a
    # different address space than 127.0.0.1, which trips Chrome's private
    # network access preflight - both need answering here
    param($Response)
    $Response.Headers.Add('Access-Control-Allow-Origin', '*')
    $Response.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')
    $Response.Headers.Add('Access-Control-Allow-Headers', '*')
    $Response.Headers.Add('Access-Control-Allow-Private-Network', 'true')
    $Response.Headers.Add('Access-Control-Max-Age', '600')
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    $json  = ConvertTo-Json -InputObject $Object -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res   = $Context.Response
    $res.StatusCode  = $Status
    $res.ContentType = 'application/json; charset=utf-8'
    Add-CorsHeaders -Response $res
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

# --------------------------------------------------------------------- start --

Write-Host ''
Write-Host '  Port Killer' -ForegroundColor Cyan
Write-Host '  -----------' -ForegroundColor DarkGray

$listener   = $null
$chosen     = 0
$candidates = @()
if ($HelperPort -gt 0) { $candidates += $HelperPort }
$candidates += 47821..47840

foreach ($p in $candidates) {
    $l = $null
    try {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        $l.Start()
        $listener = $l
        $chosen   = $p
        break
    } catch {
        if ($l) { try { $l.Close() } catch {} }
    }
}

$helperUrl = 'http://127.0.0.1:0'
if ($listener) { $helperUrl = "http://127.0.0.1:$chosen" }

Write-Host '  Scanning listening ports...' -ForegroundColor DarkGray
$payload = Get-Scan -SelfHelperPort $chosen
Write-Page -Payload $payload -HelperUrl $helperUrl

Write-Host ('  Dev servers: {0}   other: {1}' -f $payload.counts.dev, $payload.counts.other)
Write-Host ('  Page:   {0}' -f $htmlPath) -ForegroundColor DarkGray

if (-not $NoBrowser) { try { Start-Process $htmlPath | Out-Null } catch {} }

if (-not $listener) {
    Write-Host ''
    Write-Host '  Could not open a local helper port - the page is a static snapshot.' -ForegroundColor Yellow
    Write-Host '  Kill buttons are disabled; use the "copy taskkill" buttons instead.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '  Press Enter to close'
    exit 0
}

Write-Host ('  Helper: {0}   (close this window to stop it)' -f $helperUrl) -ForegroundColor DarkGray
Write-Host ''

try {
    while ($listener.IsListening) {
        $ctx  = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath.ToLower()
        try {
            if ($ctx.Request.HttpMethod -eq 'OPTIONS') {
                $res = $ctx.Response
                $res.StatusCode = 204
                Add-CorsHeaders -Response $res
                $res.ContentLength64 = 0
                $res.OutputStream.Close()
                continue
            }
            switch ($path) {
                '/ping' {
                    Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; pid = $PID })
                }
                '/scan' {
                    $p = Get-Scan -SelfHelperPort $chosen
                    Write-Page -Payload $p -HelperUrl $helperUrl
                    Send-Json -Context $ctx -Object $p
                }
                '/kill' {
                    $raw = $ctx.Request.QueryString['pid']
                    $tid = 0
                    if (-not [int]::TryParse($raw, [ref]$tid)) {
                        Send-Json -Context $ctx -Object ([ordered]@{ ok = $false; message = 'Bad pid.' }) -Status 400
                    } else {
                        $r = Invoke-Kill -TargetPid $tid
                        Write-Host ('  kill {0} -> {1}' -f $tid, $r.message) -ForegroundColor DarkGray
                        Send-Json -Context $ctx -Object $r
                    }
                }
                '/quit' {
                    Send-Json -Context $ctx -Object ([ordered]@{ ok = $true; message = 'bye' })
                    $listener.Stop()
                }
                default {
                    Send-Json -Context $ctx -Object ([ordered]@{ ok = $false; message = 'not found' }) -Status 404
                }
            }
        } catch {
            try { Send-Json -Context $ctx -Object ([ordered]@{ ok = $false; message = $_.Exception.Message }) -Status 500 } catch {}
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch {}
}
