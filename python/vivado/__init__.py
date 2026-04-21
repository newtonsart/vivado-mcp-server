"""Asyncio client for the Vivado TCL plugin.

Typical usage (outside of the MCP context):

    from vivado.client import VivadoClient

    async def main():
        async with VivadoClient() as vv:
            await vv.ping()
            result = await vv.send_command("get_project_info", {})
            print(result)

The package also exposes the error types: `VivadoError`,
`VivadoConnectionError`, `VivadoTimeoutError`.
"""

from vivado.client import VivadoClient
from vivado.exceptions import (
    VivadoConnectionError,
    VivadoError,
    VivadoProtocolError,
    VivadoRemoteError,
    VivadoTimeoutError,
)

__all__ = [
    "VivadoClient",
    "VivadoError",
    "VivadoConnectionError",
    "VivadoTimeoutError",
    "VivadoProtocolError",
    "VivadoRemoteError",
]
