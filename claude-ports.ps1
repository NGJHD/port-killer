<#
    claude-ports.ps1  --  scan listening TCP ports, work out which ones belong to
    things Claude Code started (vite/next/python/etc), render a local port.html,
    and run a tiny 127.0.0.1 helper so the Kill buttons on that page actually work.

    Launched by claude-ports.bat. Close the console window to stop the helper.
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

function Test-ClaudeProcess {
    param($Proc)
    if (-not $Proc) { return $false }
    if ($Proc.Name -match '^claude(\.exe)?$') { return $true }
    $cl = $Proc.CommandLine
    if ($cl) {
        if ($cl -match '@anthropic-ai[\\/]claude-code')         { return $true }
        if ($cl -match '[\\/]claude(-code)?\.(exe|cmd|bat|js)')  { return $true }
        if ($cl -match '[\\/]\.claude[\\/]')                     { return $true }
        if ($cl -match 'claude-code[\\/]cli\.js')                { return $true }
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

function Test-ClaudeProject {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    try {
        if (Test-Path -LiteralPath (Join-Path $Dir '.claude'))   { return $true }
        if (Test-Path -LiteralPath (Join-Path $Dir 'CLAUDE.md')) { return $true }
    } catch {}
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
        $req.UserAgent         = 'claude-port-cleanup'
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
# (that chain contains claude.exe / the Claude Code node process itself)
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
        $claudeAnchor = $null
        foreach ($node in $chain) {
            if (Test-ClaudeProcess -Proc $node) { $claudeAnchor = $node; break }
        }

        $cmdline = ''
        if ($proc -and $proc.CommandLine) { $cmdline = $proc.CommandLine }

        $project = Get-ProjectGuess -CommandLine $cmdline

        $origin = 'other'
        $via    = $null
        if ($claudeAnchor) {
            $origin = 'claude'
            $via    = "started by $($claudeAnchor.Name) ($($claudeAnchor.Id))"
        } elseif (($devNames -contains $procName) -or ($devPorts -contains $entry.Port)) {
            $origin = 'dev'
            # a dev server whose Claude session has already exited is orphaned onto
            # explorer/init, so fall back to "is this a Claude project folder?"
            if (Test-ClaudeProject -Dir $project) {
                $origin = 'claude'
                $via    = 'serving a Claude project (session no longer running)'
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
            claudeVia  = $via
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

    $rank   = @{ 'claude' = 0; 'dev' = 1; 'other' = 2 }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { $rank[$_.origin] } }, @{ Expression = { $_.port } })

    return [ordered]@{
        scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        machine   = $env:COMPUTERNAME
        counts    = [ordered]@{
            claude = @($sorted | Where-Object { $_.origin -eq 'claude' }).Count
            dev    = @($sorted | Where-Object { $_.origin -eq 'dev' }).Count
            other  = @($sorted | Where-Object { $_.origin -eq 'other' }).Count
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
        return [ordered]@{ ok = $false; message = 'Refused: that is Claude Code itself (or this helper).' }
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
<title>Claude Ports</title>
<style>
  :root{
    --bg:#0e1116; --panel:#161b23; --panel2:#1c222c; --line:#262d38;
    --ink:#e6edf3; --dim:#8b96a5; --faint:#5d6774;
    --claude:#d97757; --dev:#5aa9e6; --other:#6f7787;
    --danger:#e05260; --ok:#3fb950;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
       font:14px/1.5 "Segoe UI Variable Text","Segoe UI",system-ui,sans-serif}
  a{color:var(--dev)}
  .wrap{max-width:1180px;margin:0 auto;padding:28px 22px 60px}
  header{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
  h1{font-size:20px;margin:0;letter-spacing:-.01em}
  .sub{color:var(--dim);font-size:12.5px}
  .bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;
       margin:18px 0 14px;padding:10px 12px;background:var(--panel);
       border:1px solid var(--line);border-radius:10px}
  .chip{padding:5px 11px;border-radius:999px;border:1px solid var(--line);
        background:var(--panel2);color:var(--dim);cursor:pointer;font:inherit;font-size:12.5px}
  .chip.on{background:#243040;border-color:#39506b;color:var(--ink)}
  .chip .n{color:var(--faint);margin-left:6px}
  input[type=search]{flex:1;min-width:180px;background:#0f141b;border:1px solid var(--line);
        border-radius:8px;color:var(--ink);padding:7px 10px;font:inherit;font-size:13px}
  input[type=search]:focus{outline:none;border-color:#3d5a7d}
  .spacer{flex:1}
  .btn{background:var(--panel2);border:1px solid var(--line);color:var(--ink);
       border-radius:8px;padding:6px 12px;cursor:pointer;font:inherit;font-size:13px}
  .btn:hover{border-color:#3d4a5c}
  .status{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--dim)}
  .dot{width:8px;height:8px;border-radius:50%;background:var(--faint)}
  .dot.live{background:var(--ok);box-shadow:0 0 0 3px rgba(63,185,80,.15)}
  .dot.dead{background:var(--danger);box-shadow:0 0 0 3px rgba(224,82,96,.15)}
  .banner{display:none;margin:0 0 14px;padding:11px 14px;border-radius:10px;
          background:#2a1d1f;border:1px solid #5a2f35;color:#f0c8cc;font-size:13px}
  .banner.show{display:block}
  table{width:100%;border-collapse:separate;border-spacing:0 8px}
  thead th{text-align:left;font-size:11px;letter-spacing:.08em;text-transform:uppercase;
           color:var(--faint);font-weight:600;padding:0 12px 2px}
  tbody td{background:var(--panel);padding:11px 12px;
           border-top:1px solid var(--line);border-bottom:1px solid var(--line);vertical-align:middle}
  tbody td:first-child{border-left:1px solid var(--line);border-radius:10px 0 0 10px;width:120px}
  tbody td:last-child{border-right:1px solid var(--line);border-radius:0 10px 10px 0}
  .port{font:600 16px/1 ui-monospace,"Cascadia Mono",Consolas,monospace}
  .port a{text-decoration:none;color:var(--ink)}
  .port a:hover{color:var(--dev);text-decoration:underline}
  .badge{display:inline-block;margin-top:6px;font-size:10.5px;letter-spacing:.05em;
         text-transform:uppercase;padding:2px 7px;border-radius:5px;font-weight:600}
  .b-claude{background:rgba(217,119,87,.16);color:var(--claude)}
  .b-dev{background:rgba(90,169,230,.14);color:var(--dev)}
  .b-other{background:rgba(111,119,135,.16);color:var(--other)}
  .app{font-weight:600}
  .meta{color:var(--dim);font-size:12px;margin-top:3px}
  .cmd{color:var(--faint);font:11.5px/1.45 ui-monospace,Consolas,monospace;
       margin-top:5px;max-width:600px;overflow:hidden;text-overflow:ellipsis;
       white-space:nowrap;cursor:pointer}
  .cmd.open{white-space:normal;word-break:break-all}
  .act{text-align:right;white-space:nowrap}
  .kill{background:rgba(224,82,96,.12);border:1px solid rgba(224,82,96,.35);
        color:#ff8b95;border-radius:8px;padding:6px 13px;cursor:pointer;font:inherit;font-size:13px}
  .kill:hover{background:rgba(224,82,96,.22)}
  .kill:disabled{opacity:.4;cursor:not-allowed}
  .copy{background:none;border:1px solid var(--line);color:var(--dim);border-radius:8px;
        padding:6px 10px;cursor:pointer;font:inherit;font-size:12px;margin-right:6px}
  .copy:hover{color:var(--ink);border-color:#3d4a5c}
  .empty{padding:38px;text-align:center;color:var(--dim);background:var(--panel);
         border:1px solid var(--line);border-radius:10px}
  .toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);
         background:#20262f;border:1px solid var(--line);color:var(--ink);
         padding:10px 16px;border-radius:10px;font-size:13px;opacity:0;
         transition:opacity .18s;pointer-events:none;box-shadow:0 8px 30px rgba(0,0,0,.45)}
  .toast.show{opacity:1}
  footer{margin-top:26px;color:var(--faint);font-size:12px}
  code{font:12px ui-monospace,Consolas,monospace;color:var(--dim)}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Claude Ports</h1>
    <span class="sub" id="stamp"></span>
  </header>

  <div id="banner" class="banner"></div>

  <div class="bar">
    <button class="chip on" data-f="claude">Claude<span class="n" id="c-claude">0</span></button>
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
    <code>claude-ports.bat</code>. Close that console window to stop it &mdash; this page keeps
    working as a read-only snapshot.
  </footer>
</div>
<div class="toast" id="toast"></div>

<script>
const HELPER = "__HELPER__";
let data = __DATA__;
let filters = new Set(["claude", "dev"]);
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
  const counts = (data && data.counts) || { claude: 0, dev: 0, other: 0 };
  $("c-claude").textContent = counts.claude;
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
    const badge = r.origin === "claude" ? '<span class="badge b-claude">Claude</span>'
                : r.origin === "dev"    ? '<span class="badge b-dev">dev server</span>'
                                        : '<span class="badge b-other">other</span>';
    const meta = [esc(r.process) + " &middot; PID " + r.pid];
    if (r.started) meta.push("up since " + esc(r.started));
    if (r.claudeVia) meta.push(esc(r.claudeVia));
    if (r.httpStatus) meta.push("HTTP " + r.httpStatus);
    const proj = r.project ? '<div class="meta">' + esc(r.project) + "</div>" : "";
    const cmd = r.cmdline ? '<div class="cmd" title="click to expand">' + esc(r.cmdline) + "</div>" : "";
    const killBtn = r.protected
      ? '<button class="kill" disabled title="protected: this is Claude Code itself">Protected</button>'
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
      "Re-run <code>claude-ports.bat</code> to refresh and re-enable the Kill buttons " +
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
Write-Host '  Claude Port Cleanup' -ForegroundColor Cyan
Write-Host '  -------------------' -ForegroundColor DarkGray

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

Write-Host ('  Claude: {0}   dev servers: {1}   other: {2}' -f $payload.counts.claude, $payload.counts.dev, $payload.counts.other)
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
