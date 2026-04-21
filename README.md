# vivado-mcp-server

An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that controls a running **Vivado** instance via a local TCP socket. The architecture follows the same pattern as Blender MCP: a TCL plugin loaded inside Vivado opens a TCP server on `127.0.0.1:7654`, and a Python MCP server talks to that plugin and exposes itself over `stdio` to Claude Desktop / Codex / any MCP agent.

```
Claude Desktop / Codex / other MCP agent
        │  stdio (MCP protocol)
        ▼
Python MCP Server  (Python process)
        │  TCP 127.0.0.1:7654  (custom NDJSON)
        ▼
TCL Plugin  (inside the Vivado process)
        │  Vivado internal context
        ▼
Vivado (GUI or batch, already open by the user)
```

## Features

- **Live control** of an open Vivado session — no new process is spawned per command.
- **Non-blocking long commands**: `run_synthesis`, `run_implementation` and `generate_bitstream` launch `launch_runs` and poll with `after 5000` on the run's STATUS/PROGRESS, emitting `progress` events to the client.
- **Localhost only**: the socket binds explicitly to `127.0.0.1`. Remote connections are rejected.
- **Multi-client FIFO queue**: multiple clients can connect; commands are serialized.
- **Notifications**: events such as `run_complete` are broadcast to all connected clients.
- **Escape hatch `run_tcl`**: for any operation that doesn't have a dedicated tool yet.

## Structure

```
vivado-mcp-server/
├── tcl/                          # TCL plugin running inside Vivado
│   ├── vivado_server.tcl         # Entry point (sourced from Vivado_init.tcl)
│   ├── server/                   # TCP, NDJSON protocol, FIFO queue
│   ├── handlers/                 # Handlers by domain (project, synthesis…)
│   └── lib/                      # json.tcl + logger.tcl
├── python/                       # Python MCP server
│   ├── server.py                 # Entry point (FastMCP stdio)
│   ├── config.py                 # Host, port, per-command timeouts
│   ├── vivado/                   # Asyncio TCP client
│   └── tools/                    # @mcp.tool() by domain
├── install/
│   ├── install_windows.ps1       # Injects source line into Vivado_init.tcl
│   └── mcp_config_example.json   # Config snippet for claude_desktop_config.json
├── pyproject.toml
└── README.md
```

## Installation

### 1. TCL Plugin (Windows)

```powershell
# From a PowerShell console, at the repo root:
.\install\install_windows.ps1
```

The script copies `tcl/` to `%USERPROFILE%\.vivado-mcp\tcl\` and appends a `source` line to `%APPDATA%\Xilinx\Vivado\<version>\Vivado_init.tcl`. If the file doesn't exist, it creates it; if it already has content, it preserves it.

On Linux the equivalent path is `~/.Xilinx/Vivado/<version>/Vivado_init.tcl`; you can inject it manually:

```tcl
# vivado-mcp-server: TCP server plugin
source /home/<user>/.vivado-mcp/tcl/vivado_server.tcl
```

### 2. Python MCP Server

From the repo root:

```bash
pip install -e .
```

Or run directly from the repo without installing (requires [uv](https://docs.astral.sh/uv/)):

```bash
uv run python -m server
```

### 3. Claude Desktop

Add to your `claude_desktop_config.json`. Two options:

**Option A — installed** (`pip install .` first):
```json
{
  "mcpServers": {
    "vivado": {
      "command": "vivado-mcp-server",
      "env": { "VMCP_HOST": "127.0.0.1", "VMCP_PORT": "7654" }
    }
  }
}
```

**Option B — run from repo with uv** (no install needed):
```json
{
  "mcpServers": {
    "vivado": {
      "command": "uv",
      "args": ["run", "--project", "C:/path/to/vivado-mcp-server", "python", "-m", "server"],
      "env": { "VMCP_HOST": "127.0.0.1", "VMCP_PORT": "7654" }
    }
  }
}
```

## Usage

1. Open Vivado (GUI or `vivado -mode tcl`). The TCL console should show:

   ```
   vivado-mcp-server: plugin loaded. Commands: ::vmcp::server::start / ::vmcp::server::stop / ::vmcp::server::reload
   [vmcp] server listening on 127.0.0.1:7654
   ```

2. Start Claude Desktop. The `check_connection` tool will tell you if the plugin responds.

3. Example interactions:

   - *"Open the project `C:/work/blink.xpr` and launch synthesis with 8 jobs"* → calls `open_project` + `run_synthesis(jobs=8)`.
   - *"How much slack is there on the critical path?"* → `get_timing_summary` + `get_timing_paths`.
   - *"Generate the bitstream"* → `generate_bitstream`.

### Batch / headless mode

To use the plugin from `vivado -mode batch` or `vivado -mode tcl`, append at the end of your startup script:

```tcl
source vivado_server.tcl
vwait forever
```

`vwait forever` keeps the event loop alive, which is required for `fileevent` to fire the read callbacks.

## TCP Protocol (NDJSON)

Each message is a JSON object on a single line (`\n`). The channel is configured with `fconfigure -buffering line`.

| Type           | Direction     | Required fields                        |
|----------------|---------------|----------------------------------------|
| `request`      | Python → TCL  | `id`, `type`, `command`, `params`      |
| `ack`          | TCL → Python  | `id`, `type=ack`, `status`, `message`  |
| `progress`     | TCL → Python  | `id`, `type=progress`, `percent`, `message` |
| `result`       | TCL → Python  | `id`, `type=result`, `status`, `data`/`error` |
| `notification` | TCL → Python  | `type=notification`, `event`, `data`   |

## Exposed Tools

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `check_connection`    | Ping the TCL plugin                                          |
| `open_project`        | Open an `.xpr` file                                          |
| `close_project`       | Close the current project                                    |
| `get_project_info`    | Name, part, top, runs, paths                                 |
| `run_synthesis`       | Launch `launch_runs synth_1`, with progress events           |
| `run_implementation`  | Launch `launch_runs impl_1`, with progress events            |
| `generate_bitstream`  | Launch `launch_runs impl_1 -to_step write_bitstream`         |
| `get_run_status`      | Snapshot of STATUS/PROGRESS of a run                         |
| `reset_run`           | `reset_run <run>`                                            |
| `get_timing_summary`  | `report_timing_summary` + WNS/TNS/WHS/THS extraction        |
| `get_timing_paths`    | `get_timing_paths` (top N paths)                             |
| `get_utilization`     | `report_utilization` + table parsing                         |
| `get_messages`        | Filter by severity                                           |
| `get_drc`             | `report_drc`                                                 |
| `get_cells`           | `get_cells <pattern>` with `-hierarchical` support           |
| `get_nets`            | `get_nets <pattern>`                                         |
| `get_ports`           | `get_ports <pattern>`                                        |
| `get_clocks`          | `get_clocks`                                                 |
| `get_design_hierarchy`| Module tree up to `max_depth`                                |
| `run_tcl`             | **Escape hatch**: execute arbitrary TCL                      |

## Timeouts

Defined in `python/config.py`:

| Category                        | Timeout (s) |
|---------------------------------|-------------|
| Fast (`get_*`, `close_project`) | 30          |
| `open_project`                  | 120         |
| `run_synthesis`, `run_implementation`, `generate_bitstream` | 7200 |
| `run_tcl`                       | 600         |

Can be overridden in code by modifying `COMMAND_TIMEOUTS` before starting the server.

## Development

```bash
pip install -e ".[dev]"
ruff check python/
mypy python/
pytest
```

## License

MIT.
