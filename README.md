# Claude Port Cleanup

Double-click **`claude-ports.bat`**. It scans every listening TCP port, works out
which ones belong to servers Claude Code started, writes **`port.html`** next to
the script, and opens that file in your browser.

`port.html` is a plain local file (`file:///.../port.html`) — nothing is hosted.

## Why there is still a console window

A `file://` page is sandboxed and cannot kill a process, so the `.bat` also runs a
tiny helper bound to `127.0.0.1` (first free port from 47821). The page calls it
for two things only:

| route | does |
| --- | --- |
| `/scan` | re-runs the scan and returns JSON |
| `/kill?pid=N` | `taskkill /PID N /T /F` |

**Close the console window to stop the helper.** The page then keeps working as a
read-only snapshot: the Kill buttons grey out, and the *copy taskkill* buttons
still give you the exact command to paste.

## How a port is classified

| badge | rule |
| --- | --- |
| **Claude** | a live `claude.exe` / Claude Code process is an ancestor of the listening process, **or** the project folder it is serving contains `.claude` or `CLAUDE.md` (this catches vite/next servers left running after the Claude session that started them has already exited — usually what you are here to clean up) |
| **dev server** | a known dev runtime (node, bun, deno, python, dotnet…) or a known dev port (3000, 5173, 8000…) |
| **other** | everything else, hidden by default |

The app name comes from the page's own `<title>` (Claude Port Cleanup makes a
1.2s HTTP request to each candidate port), falling back to the project folder
name and then the process name.

## Safety

- Claude Code itself, this helper, and the shell chain that launched it are marked
  **Protected** and cannot be killed from the page.
- PIDs 0–4 are refused.
- Kill is a single click with no confirmation, so aim before you click.

## Options

```
claude-ports.bat                    scan, write port.html, open it, serve kills
claude-ports.bat -NoBrowser         don't open the browser
claude-ports.bat -HelperPort 47900  pin the helper port
```

## If the Kill buttons stay greyed out

Chrome may ask for permission the first time a local page talks to `127.0.0.1`
(Local Network Access) — allow it, then hit **Rescan**. Otherwise the helper
never started; the console window says so.
