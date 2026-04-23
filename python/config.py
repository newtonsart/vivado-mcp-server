"""MCP server configuration.

All variables can be overridden via environment:

    VMCP_HOST           (default "127.0.0.1")
    VMCP_PORT           (default 7654)
    VMCP_RECONNECT_MAX  (default 30, maximum backoff in seconds)
    VMCP_LOGLEVEL       (default "INFO")

Command timeouts can be inspected and modified in `COMMAND_TIMEOUTS`.
"""

from __future__ import annotations

import os
from typing import Dict

# -----------------------------------------------------------------------------
# Connection to the TCL plugin
# -----------------------------------------------------------------------------
HOST: str = os.environ.get("VMCP_HOST", "127.0.0.1")
PORT: int = int(os.environ.get("VMCP_PORT", "7654"))

# Reconnection retries when Vivado is not yet running or has been closed.
# Exponential backoff up to RECONNECT_MAX seconds.
RECONNECT_INITIAL_DELAY: float = 1.0
RECONNECT_MAX_DELAY: float = float(os.environ.get("VMCP_RECONNECT_MAX", "30"))
RECONNECT_MAX_ATTEMPTS: int = int(os.environ.get("VMCP_RECONNECT_ATTEMPTS", "0"))  # 0 = unlimited

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
LOG_LEVEL: str = os.environ.get("VMCP_LOGLEVEL", "INFO").upper()

# -----------------------------------------------------------------------------
# Per-command timeouts, in seconds.
#
# Rationale:
#   * Fast commands (netlist queries, close_project):  30 s
#   * open_project: may be slow for large projects:  120 s
#   * Synthesis / implementation / bitstream:        7200 s (2 h)
#   * run_tcl: generic escape hatch:                  600 s
# -----------------------------------------------------------------------------
COMMAND_TIMEOUTS: Dict[str, float] = {
    "default":              30.0,
    "ping":                  5.0,
    "open_project":        120.0,
    "close_project":        30.0,
    "get_project_info":     30.0,
    "run_synthesis":      7200.0,
    "run_implementation": 7200.0,
    "generate_bitstream": 7200.0,
    "get_run_status":       10.0,
    "reset_run":            30.0,
    "get_timing_summary":  300.0,
    "get_timing_paths":    300.0,
    "get_utilization":     120.0,
    "get_messages":         60.0,
    "get_drc":             300.0,
    "get_cells":            60.0,
    "get_nets":             60.0,
    "get_ports":            30.0,
    "get_clocks":           30.0,
    "get_design_hierarchy": 60.0,
    "run_tcl":             600.0,
    "reload_plugin":        30.0,
    "get_power_report":    300.0,
    "get_cdc_report":      120.0,
    "get_methodology_violations": 120.0,
    "get_io_report":        60.0,
    "write_checkpoint":    120.0,
    "get_fanout_report":   120.0,
    "write_xdc":            60.0,
    "read_xdc":             60.0,
    "set_top":              30.0,
    "connect_hw":          120.0,
    "disconnect_hw":        30.0,
    "get_hw_info":          60.0,
    "program_device":      300.0,
    "list_hw_probes":       60.0,
    "set_ila_trigger":      30.0,
    "arm_ila":              30.0,
    "wait_ila":            600.0,
    "read_ila_data":       120.0,
    "get_vio":              30.0,
    "set_vio":              30.0,
    "list_hw_axis":         30.0,
    "axi_read":             60.0,
    "axi_write":            60.0,
    "create_clock":         30.0,
    "create_generated_clock": 30.0,
    "set_input_delay":      30.0,
    "set_output_delay":     30.0,
    "set_false_path":       30.0,
    "set_multicycle_path":  30.0,
    "set_clock_groups":     30.0,
    "report_exceptions":   120.0,
    "list_strategies":      30.0,
    "set_run_strategy":     60.0,
    "get_run_stats":        30.0,
    "wait_on_run":        3600.0,
}


def timeout_for(command: str) -> float:
    """Return the timeout associated with a command, or the default."""
    return COMMAND_TIMEOUTS.get(command, COMMAND_TIMEOUTS["default"])
