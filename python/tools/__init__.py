"""MCP tools for vivado-mcp-socket.

Each sub-module exposes a `register(mcp, client_factory)` function that
registers its tools in the supplied FastMCP instance. The `client_factory`
is a callable `() -> Awaitable[VivadoClient]` that returns (lazily
initializing if needed) the shared VivadoClient.
"""

from tools import (
    constraints,
    hardware,
    implementation,
    netlist,
    project,
    reports,
    runs,
    synthesis,
)


def register_all(mcp, client_factory) -> None:
    """Register all tools in the given FastMCP instance."""
    project.register(mcp, client_factory)
    synthesis.register(mcp, client_factory)
    implementation.register(mcp, client_factory)
    reports.register(mcp, client_factory)
    netlist.register(mcp, client_factory)
    hardware.register(mcp, client_factory)
    constraints.register(mcp, client_factory)
    runs.register(mcp, client_factory)


__all__ = ["register_all"]
