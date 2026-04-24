"""vivado-mcp-server: MCP bridge to a running Vivado instance.

Public entry point: `vivado_mcp_server.server.main`. The console script
`vivado-mcp-server` and `python -m vivado_mcp_server` both dispatch there.
"""

from .server import main

__all__ = ["main"]
