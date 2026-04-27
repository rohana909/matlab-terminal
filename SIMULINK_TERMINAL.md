# SimulinkTerminal: Integration Guide

This document describes how the Terminal is integrated into Simulink as a docked panel, covering the architecture, file locations, data flow, and code changes involved.

## Overview

`SimulinkTerminal` docks a fully-featured terminal panel into the Simulink Editor (Studio). It reuses the same Go server (`matlab-terminal-server`) and xterm.js frontend that powers the MATLAB Desktop terminal, but renders inside Simulink's CEF-based DDG webbrowser widget instead of a standalone figure window.

```
SimulinkTerminal.show()
        |
        v
+-------------------+       +---------------------+       +------------------+
|  SimulinkTerminal  | ----> |  Go Server (PTY)     | <---> |  simulink.html   |
|  (MATLAB class)    |       |  127.0.0.1:<port>    |       |  (xterm.js UI)   |
+-------------------+       +---------------------+       +------------------+
        |                           ^                           |
        v                           |                           |
+-------------------+               +---------------------------+
|  DAS.Studio /      |              fetch() over HTTP (no MATLAB
|  GLUE2.DDGComponent|              middleman for terminal I/O)
|  (Simulink dock)   |
+-------------------+
```

The CEF browser inside Simulink talks directly to the Go server via `fetch()` API calls. MATLAB is not in the I/O path once the terminal is running -- it only handles lifecycle (start/stop).

## File Locations

All paths are relative to the repository root.

### MATLAB Source

| File | Purpose |
|------|---------|
| `toolbox/SimulinkTerminal.m` | Main class -- lifecycle, server launch, DDG docking |
| `toolbox/SimulinkTerminal.p` | P-coded version of the above (shipped in `.mltbx`) |
| `toolbox/+internal/Themes.m` | Theme presets and resolution (dark, light, dracula, etc.) |
| `toolbox/Terminal.m` | Main MATLAB Desktop terminal class (not Simulink-specific) |
| `toolbox/tests/TestSimulinkTerminal.m` | 86 unit tests for SimulinkTerminal |

### Frontend (HTML/JS)

| File | Purpose |
|------|---------|
| `toolbox/html/simulink.html` | Simulink-specific xterm.js frontend, loaded in DDG webbrowser widget |
| `toolbox/html/index.html` | MATLAB Desktop terminal frontend (standalone window) |
| `toolbox/html/terminal.css` | Shared CSS for both frontends |
| `toolbox/html/lib/xterm/` | xterm.js library and fit addon |

### Go Server

| File | Purpose |
|------|---------|
| `server/main.go` | Entry point -- flags, HTTP mux, idle timeout, parent PID monitor |
| `server/api.go` | API handlers: `/api/create`, `/api/input`, `/api/resize`, `/api/poll`, `/api/close`, `/api/sessions`, `/api/scrollback` |
| `server/auth.go` | Token-based authentication middleware |
| `server/api_test.go` | API unit tests |
| `server/auth_test.go` | Auth unit tests |
| `server/integration_test.go` | End-to-end server tests |

The Go server has **no Simulink-specific code**. It is a generic PTY terminal server. The `/static/` route serves whichever HTML directory is passed via `--static-dir`, and `simulink.html` is just another static file served from it.

## How It Works

### 1. Server Launch (`startServer`)

When `SimulinkTerminal.show()` is called:

1. **Locate binary** -- `findBinary()` searches four locations in order:
   - `dist/<arch>/` (development builds)
   - `prefdir/matlab-terminal/bin/<arch>/` (extracted from `.mltbx`)
   - `userpath/bin/` (manual install via `Terminal.install`)
   - System `PATH`

2. **Locate HTML** -- `resolveHTMLDir()` searches:
   - `toolbox/html/` (source/addpath usage)
   - `prefdir/matlab-terminal/html/` (`.mltbx` installation)

3. **Generate auth token** -- 32-char hex token, passed to server via the `MATLAB_TERMINAL_TOKEN` environment variable (not CLI args, for security). Cleared immediately after server launch.

4. **Launch server** -- Runs the binary with flags:
   ```
   matlab-terminal-server --static-dir <html-dir> --ready-file <temp>.txt --env MATLAB_PID=<pid> --env MATLAB_ROOT=<root>
   ```
   On Windows, wrapped in a `.bat` file launched via `start /b`.

5. **Wait for ready file** -- The server writes `PID:<n>\nPORT:<n>` to the ready file once listening. MATLAB polls for up to 5 seconds.

### 2. Docking into Simulink (`dock`)

Once the server is running:

1. **Get active Studio** -- `DAS.Studio.getAllStudiosSortedByMostRecentlyActive` returns Simulink editor instances. The most recently active one is used.

2. **Create DDG component** -- `GLUE2.DDGComponent(studio, 'SimulinkTerminal', this)` creates a DDG dialog container backed by `SimulinkTerminal`'s `getDialogSchema` method.

3. **Build dialog schema** -- `getDialogSchema()` returns a DDG struct with a single `webbrowser` widget pointing to:
   ```
   http://127.0.0.1:<port>/static/simulink.html?t=<token>&theme=<encoded-json>
   ```

4. **Dock the component** -- `studio.moveComponentToDock(component, 'Terminal', 'Right', 'Tabbed')` places it in the right dock area.

5. **Cleanup listener** -- An `ObjectBeingDestroyed` listener on the component triggers `cleanup()` when the user closes the panel via the Simulink UI.

### 3. Terminal I/O (no MATLAB involvement)

Once docked, the CEF browser inside Simulink runs `simulink.html`, which:

- Reads the auth token and theme from URL parameters
- Creates terminal sessions via `POST /api/create`
- Sends keystrokes via `POST /api/input` (buffered, flushed every 50ms)
- Polls for output via `GET /api/poll` (every 100ms)
- Handles resize via `POST /api/resize`
- Reconnects existing sessions on page reload via `GET /api/sessions` + `GET /api/scrollback`

MATLAB is completely out of the loop for terminal I/O. This avoids the MATLAB thread bottleneck and provides native-feeling terminal responsiveness.

### 4. Cleanup

When the panel is closed (via UI, `SimulinkTerminal.close()`, or object deletion):

1. Kill the Go server process by PID (`taskkill /F` on Windows, `kill` on Unix)
2. Clear internal state (ServerProcess, AuthToken, Component)
3. Remove from the persistent registry

Cleanup is idempotent and guarded against reentrancy.

## Key Design Decisions

### Why DDG/GLUE2 instead of uifigure?

`uihtml` (inside `uifigure`) blocks all `localhost` network connections due to CSP restrictions. The terminal needs `fetch()` and potentially WebSocket access to the Go server on `127.0.0.1`. The DDG `webbrowser` widget uses Simulink's CEF instance which has no such restriction.

### Why not WebBrowser.createBrowser()?

`WebBrowser.createBrowser()` supports JavaScript but auto-registers in a "Web Browser" component group that always floats/undocks. There is no API to control its dock location.

### Why a separate Go server per panel?

Each `SimulinkTerminal.show()` launches its own server process. This provides:
- Process isolation (a crash doesn't affect MATLAB)
- Independent auth tokens
- Clean lifecycle tied to the panel

### Why pass auth via environment variable?

CLI arguments are visible in process listings (`tasklist`, `ps`). The token is set in `MATLAB_TERMINAL_TOKEN`, read by the server on startup, then immediately cleared from both sides.

## Simulink-Specific Changes (Branch: `simulink-integration`)

The following commits introduced the Simulink integration:

| Commit | Description |
|--------|-------------|
| `d5424a4` | Initial `SimulinkTerminal.m` + `simulink.html` + DDG docking |
| `5fe8df5` | Replace `.m` with p-coded `.p` for distribution |
| `c2a98b2` | Add `.m` source back (with test access grants) + 86 unit tests |

### Changes to existing files

**None.** The Simulink integration is entirely additive. `Terminal.m`, the Go server, and the existing HTML frontend are unchanged.

### New files added

- `toolbox/SimulinkTerminal.m` / `.p` -- the integration class
- `toolbox/html/simulink.html` -- Simulink-specific xterm.js frontend
- `toolbox/tests/TestSimulinkTerminal.m` -- unit tests

## Testing

### Running tests

```matlab
results = runtests('TestSimulinkTerminal');
```

### Test coverage

86 tests covering: constructor, constants, delete/destructor, `show()` error paths, `close()`, `getDialogSchema`, `findBinary`, `resolveHTMLDir`, `generateToken`, `killProcess`, registry, `findExistingComponent`, `cleanup`, metaclass structure, and `startServer` error paths.

### What is NOT covered by unit tests

- `show()` success path and `dock()` -- requires a Simulink model to be open (`DAS.Studio` is a built-in class that cannot be mocked)
- `startServer()` full launch -- requires the Go binary installed
- Linux/macOS platform branches -- when running on Windows

### Testability modifications to SimulinkTerminal.m

Four changes were made to the source to enable testing of a `Sealed` class:

1. Properties: `Access = private` changed to `Access = {?SimulinkTerminal, ?TestSimulinkTerminal}`
2. Instance methods: same access change
3. Static methods: same access change
4. Registry: added `'reset'` action to clear the persistent variable between tests

These changes have zero runtime impact -- the class remains sealed and all members remain inaccessible to any code except `SimulinkTerminal` and `TestSimulinkTerminal`.

## Usage

```matlab
% Open any Simulink model first
open_system('vdp');

% Dock terminal in the active Simulink editor
SimulinkTerminal.show()

% With a specific theme
SimulinkTerminal.show(Theme="dracula")

% Close all terminal panels
SimulinkTerminal.close()
```

## Requirements

- MATLAB R2025a or later
- Simulink (for `DAS.Studio` and `GLUE2.DDGComponent`)
- `matlab-terminal-server` binary (installed via the Terminal toolbox)
