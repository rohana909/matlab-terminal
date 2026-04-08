# AI Agent Integration (MCP)

Terminal supports the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP), enabling AI coding agents to interact with the running MATLAB desktop session. When enabled, agents like Claude Code can evaluate MATLAB code, read open editor files, inspect highlighted selections, and query workspace variables — all within the same MATLAB session the user is working in.

## Quick Start

```matlab
t = Terminal(MCP=true);
```

When the terminal opens, it pre-populates a registration command on the command line. Press **Enter** to register the MCP server and launch Claude Code in a single step.

On subsequent launches, the MCP server is already registered. Type `claude` (or your launcher command) to start the agent with full MATLAB tool access.

## How It Works

### Architecture

```
MATLAB Desktop (already running)
     │
     ├── Terminal.m ──HTTP──▶ matlab-terminal-server ──PTY──▶ shell
     │       │                                                  │
     │       │ (bootstrap EC, set env vars)                     │
     │       ▼                                                  ▼
     │   Embedded Connector                              Claude Code
     │       ▲                                                  │
     │       │                                                  │
     │       └────── HTTPS ────── matlab-terminal-server ◀──────┘
     │                            (MCP mode, stdio)
```

When `MCP=true` is set:

1. **Terminal.m bootstraps the Embedded Connector (EC)** — MATLAB's built-in HTTPS server for programmatic access. It sets `MATLAB_EC_PORT` and `MWAPIKEY` in the shell environment.

2. **The user registers and launches the AI agent** — The pre-populated command runs `claude mcp add-json` to register the MCP server, then launches Claude Code.

3. **Claude Code launches a second instance of the server** — This instance runs in MCP mode (`--mcp`), reading JSON-RPC requests from stdin and writing responses to stdout. It proxies tool calls to MATLAB through the EC. No HTTP listener or PTY — just a lightweight bridge (~6 MB).

4. **Tools execute in the live MATLAB session** — Code evaluation, editor queries, and workspace inspection all happen in the same desktop MATLAB the user is looking at. Unsaved edits, highlighted text, and workspace variables are all accessible.

### Key Design Decisions

- **Opt-in** — `MCP=true` must be explicitly set. Without it, `Terminal()` behaves exactly as before with no additional startup cost.
- **Same binary** — The MCP server is a mode of the existing `matlab-terminal-server` binary (`--mcp` flag), not a separate binary. No additional downloads or installations.
- **Same MATLAB session** — Unlike standalone MCP servers that start a new MATLAB process, this connects to the user's running desktop via the Embedded Connector. Editor state, workspace, and figures are shared.
- **No SDK dependency** — The MCP protocol (JSON-RPC over stdio) is implemented directly in ~200 lines of Go. No external MCP SDK, keeping the binary small and dependency-free.
- **Swappable backend** — Tool handlers communicate through a `MATLABClient` interface. The current implementation talks to the EC directly, but can be swapped to delegate to the [official MathWorks MCP server](https://github.com/matlab/matlab-mcp-core-server) if it adds support for connecting to existing desktop sessions.

## Tools

### Code Execution

| Tool | Description |
|------|-------------|
| `evaluate_matlab_code` | Execute MATLAB code in the running desktop session. Has full access to the workspace, editor, figures, path, and all desktop state. |
| `run_matlab_file` | Run a `.m` script or function file by path. |
| `check_matlab_code` | Run static code analysis (`checkcode`) on a `.m` file and return warnings and suggestions. |

### Editor Integration

| Tool | Description |
|------|-------------|
| `matlab_editor_list` | List all files currently open in the MATLAB editor with modification status. |
| `matlab_editor_active` | Get the active (focused) file, cursor position, and selected text. |
| `matlab_editor_selection` | Get the text currently highlighted in the active editor. |
| `matlab_editor_read` | Read the contents of an open editor file. Reflects unsaved edits. Supports partial name matching. |

The editor tools are the key differentiator from standalone MCP servers. They enable workflows like:

- **"Explain this code"** — The agent reads the highlighted selection directly from the editor.
- **"Fix my file"** — The agent reads the active file including unsaved edits, not the stale version on disk.
- **"What am I working on?"** — The agent lists all open files to understand context.

## Registration

The pre-populated command uses `claude mcp add-json` to register the MCP server with Claude Code:

```bash
claude mcp add-json terminal-mcp '{"command":"/path/to/matlab-terminal-server","args":["--mcp","--ec-port","31516","--mwapikey","..."]}'
```

The registration persists in Claude Code's local config (`.claude/settings.local.json`). The EC port and API key are specific to the current MATLAB session — if MATLAB restarts, re-register by opening a new `Terminal(MCP=true)` and pressing Enter on the pre-populated command.

### Custom Launchers

The pre-populated command uses `devai launch claude` by default. If your environment uses a different launcher, modify the command before pressing Enter. The pattern is:

```
<launcher> claude mcp add-json terminal-mcp '<json>' 2>/dev/null; <launcher> claude
```

## Server Modes

The `matlab-terminal-server` binary operates in two modes:

| Mode | Trigger | Purpose |
|------|---------|---------|
| **Terminal mode** (default) | `--token` flag | HTTP server managing PTY sessions for the terminal UI |
| **MCP mode** | `--mcp` flag | Stdio JSON-RPC server proxying tool calls to MATLAB via the EC |

MCP mode flags:

```
matlab-terminal-server --mcp --ec-port <port> --mwapikey <key>
```

Both `--ec-port` and `--mwapikey` fall back to the `MATLAB_EC_PORT` and `MWAPIKEY` environment variables if not provided as flags.

## Embedded Connector

The [Embedded Connector](https://www.mathworks.com/help/matlab/ref/connector.html) (EC) is an HTTPS server built into the MATLAB desktop. Terminal.m starts it automatically when `MCP=true` is set, using `connector.internal.Worker.start` (idempotent — safe if already running).

The MCP server communicates with the EC via:
- **Eval**: `POST https://127.0.0.1:<port>/messageservice/json/secure` — execute MATLAB code, returns console output.
- **Ping**: `POST https://127.0.0.1:<port>/messageservice/json/state` — check if MATLAB is alive.

TLS verification is skipped for localhost (same user, same machine, self-signed certificate).

## Security

The MCP integration has the same trust model as the terminal itself:

- **Localhost only** — All communication is between processes on the same machine.
- **Same user** — The MCP server runs as the same OS user as MATLAB and the AI agent.
- **Arbitrary code execution** — Tool calls can execute any MATLAB code, equivalent to typing in the Command Window. This is by design — the AI agent needs full access to be useful.
- **API key in process arguments** — `MWAPIKEY` is visible in the process list (`ps`). This is the same exposure model as the existing `--token` flag for terminal authentication.
