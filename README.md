# Port Killer

Double-click **`port-killer.bat`**. It scans every listening TCP port, works out
which ones are dev servers, writes **`port.html`** next to the script, and opens
that file in your browser.

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
| **dev server** | a known dev runtime (node, bun, deno, python, dotnet…), a known dev port (3000, 5173, 8000…), **or** a coding-agent CLI is an ancestor of the listening process — that last rule catches servers on ports nothing else would recognise |
| **other** | everything else, hidden by default |

A dev server whose session has already exited gets reparented onto explorer, so
the folder it is serving is the only tell left: if that folder holds agent config
(`.claude`, `CLAUDE.md`, `.codex`, `AGENTS.md`, `.cursor`) the row is annotated
*left over from a session that has already exited* — usually what you are here to
clean up.

The app name comes from the page's own `<title>` (Port Killer makes a 1.2s HTTP
request to each candidate port), falling back to the project folder name and then
the process name.

## Safety

- This helper and the shell chain that launched it are marked **Protected** and
  cannot be killed from the page.
- PIDs 0–4 are refused.
- Kill is a single click with no confirmation, so aim before you click.

## Options

```
port-killer.bat                    scan, write port.html, open it, serve kills
port-killer.bat -NoBrowser         don't open the browser
port-killer.bat -HelperPort 47900  pin the helper port
```

## If the Kill buttons stay greyed out

Chrome may ask for permission the first time a local page talks to `127.0.0.1`
(Local Network Access) — allow it, then hit **Rescan**. Otherwise the helper
never started; the console window says so.
