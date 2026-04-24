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
- **Hot-reload**: `reload_plugin` re-sources handler files without restarting Vivado or losing the TCP connection.
- **Large reports to disk**: every big `report_*` tool accepts an optional `path=` to dump the full report to a file (avoids the socket 64 KB line limit).
- **JTAG debug**: full Hardware Manager support — program FPGA, capture ILAs, drive VIOs, JTAG-to-AXI peek/poke.
- **Timing closure helpers**: set constraints (create_clock, set_false_path, multicycle, clock_groups), switch run strategies, track WNS/TNS across iterations.
- **Escape hatch `run_tcl`**: for any operation that doesn't have a dedicated tool yet.

## Structure

```
vivado-mcp-server/
├── tcl/                          # TCL plugin running inside Vivado
│   ├── vivado_server.tcl         # Entry point (sourced from Vivado_init.tcl)
│   ├── server/                   # TCP, NDJSON protocol, FIFO queue
│   ├── handlers/                 # Handlers by domain (project, synthesis…)
│   └── lib/                      # json.tcl + logger.tcl
├── python/
│   └── vivado_mcp_server/        # Python MCP server (package)
│       ├── __init__.py
│       ├── __main__.py           # `python -m vivado_mcp_server`
│       ├── server.py             # FastMCP stdio entry point
│       ├── config.py             # Host, port, per-command timeouts
│       ├── vivado/               # Asyncio TCP client
│       └── tools/                # @mcp.tool() by domain
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
uv run python -m vivado_mcp_server
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
      "args": ["run", "--project", "C:/path/to/vivado-mcp-server", "python", "-m", "vivado_mcp_server"],
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

Meta / connection:

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `check_connection`    | Ping the TCL plugin                                          |
| `reload_plugin`       | Re-source handler files without restarting Vivado            |
| `run_tcl`             | **Escape hatch**: execute arbitrary TCL                      |

Project & sources:

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `open_project`        | Open an `.xpr` file                                          |
| `close_project`       | Close the current project                                    |
| `get_project_info`    | Name, part, top, runs, paths                                 |
| `write_checkpoint`    | Save design state to `.dcp`                                  |
| `write_xdc`           | Export constraints of the open design                        |
| `read_xdc`            | Add an `.xdc` file to a constraints fileset                  |
| `set_top`             | `set_property top` on a source fileset                       |

Runs & flow:

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `run_synthesis`       | Launch `launch_runs synth_1`, with progress events           |
| `run_implementation`  | Launch `launch_runs impl_1`, with progress events            |
| `generate_bitstream`  | Launch `launch_runs impl_1 -to_step write_bitstream`         |
| `get_run_status`      | Snapshot of STATUS/PROGRESS of a run                         |
| `reset_run`           | `reset_run <run>`                                            |
| `list_strategies`     | Enumerate synth or impl strategies                           |
| `set_run_strategy`    | `set_property strategy` on a run (optional reset)            |
| `get_run_stats`       | Strategy + status + WNS/TNS/WHS/THS + elapsed                |
| `wait_on_run`         | Block until run completes or timeout                         |

Reports (all big ones accept optional `path=` to dump to file):

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `get_timing_summary`  | `report_timing_summary` + WNS/TNS/WHS/THS extraction         |
| `get_timing_paths`    | `get_timing_paths` (top N paths)                             |
| `get_utilization`     | `report_utilization` + table parsing                         |
| `get_messages`        | Filter by severity                                           |
| `get_drc`             | `report_drc`                                                 |
| `get_power_report`    | `report_power` (requires implemented design)                 |
| `get_cdc_report`      | `report_cdc` — clock domain crossing analysis                |
| `get_methodology_violations` | `report_methodology`                                  |
| `get_io_report`       | `report_io` — I/O pin assignments and standards              |
| `get_fanout_report`   | `report_high_fanout_nets`                                    |

Netlist queries:

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `get_cells`           | `get_cells <pattern>` with `-hierarchical` support           |
| `get_nets`            | `get_nets <pattern>`                                         |
| `get_ports`           | `get_ports <pattern>`                                        |
| `get_clocks`          | `get_clocks`                                                 |
| `get_design_hierarchy`| Module tree up to `max_depth`                                |

Timing constraints (in-memory; use `write_xdc` to persist):

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `create_clock`        | Primary clock on a port/pin                                  |
| `create_generated_clock` | Derived from an existing clock                            |
| `set_input_delay`     | I/O timing relative to a clock                               |
| `set_output_delay`    | Same, output side                                            |
| `set_false_path`      | Ignore timing on a path                                      |
| `set_multicycle_path` | Relax by N cycles                                            |
| `set_clock_groups`    | Mark clocks as async/exclusive (common CDC waiver)           |
| `report_exceptions`   | `report_exceptions` — list all false/multicycle/groups       |

Hardware Manager (JTAG):

| Tool                  | Description                                                  |
|-----------------------|--------------------------------------------------------------|
| `connect_hw`          | open_hw_manager + connect_hw_server + open_hw_target         |
| `disconnect_hw`       | Teardown                                                     |
| `get_hw_info`         | Server + target + devices + ILAs + VIOs inventory            |
| `program_device`      | Flash `.bit` (+ optional `.ltx`)                             |
| `list_hw_probes`      | Probes on an ILA/VIO core                                    |
| `set_ila_trigger`     | Single-probe compare on an ILA                               |
| `arm_ila`             | Configure depth/position/mode + `run_hw_ila`                 |
| `wait_ila`            | Block until trigger or timeout                               |
| `read_ila_data`       | Upload capture to CSV or VCD                                 |
| `get_vio`             | Refresh + read a VIO input probe                             |
| `set_vio`             | Write + commit a VIO output probe                            |
| `list_hw_axis`        | Enumerate JTAG-to-AXI masters                                |
| `axi_read`            | AXI read via JTAG (peek)                                     |
| `axi_write`           | AXI write via JTAG (poke, supports bursts)                   |

## Timeouts

Defined in `python/config.py` (`COMMAND_TIMEOUTS` dict). Representative values:

| Category                                                    | Timeout (s) |
|-------------------------------------------------------------|-------------|
| Fast (`get_*`, `close_project`, constraints setters)        | 30          |
| `open_project`, medium reports, `wait_ila`                  | 60–300      |
| `program_device`, `get_power_report`                        | 300         |
| `run_synthesis`, `run_implementation`, `generate_bitstream`, `wait_on_run` | 3600–7200   |
| `run_tcl`                                                   | 600         |

Override by editing `COMMAND_TIMEOUTS` or by passing a bigger `timeout=` from any tool call in code.

## Extending

To add a new tool:

1. **TCL handler**: add a `proc ::vmcp::handlers::<domain>::<name>` in `tcl/handlers/<domain>.tcl`, then register with `::vmcp::dispatcher::register <cmd> <proc>`. Return `"__async__"` for long-running ops (see `synthesis.tcl`).
2. **Python tool**: add a `@mcp.tool()` function in `python/tools/<domain>.py` inside `register(mcp, client_factory)`. Call `client.send_command("<cmd>", params, timeout=config.timeout_for("<cmd>"))`.
3. **Timeout**: add an entry in `python/config.py` `COMMAND_TIMEOUTS`.
4. **Reload**: run `install/install_windows.ps1` then call `reload_plugin` (TCL) + restart the MCP process (Python).

See `TODO.md` in the repo root for the current backlog of pro features.

## Development

```bash
pip install -e ".[dev]"
ruff check python/
mypy python/
pytest
```

## License

MIT.
