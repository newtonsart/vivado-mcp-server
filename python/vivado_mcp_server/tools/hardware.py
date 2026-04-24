"""MCP tools for JTAG / Hardware Manager debug.

Wraps Vivado hw_manager TCL commands (open_hw_manager, program_hw_devices,
run_hw_ila, wait_on_hw_ila, upload_hw_ila_data, commit_hw_vio, ...).
"""

from __future__ import annotations

import json
from typing import Any, Dict

from .. import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def connect_hw(
        server_url: str = "localhost:3121",
        target: str = "",
        device: str = "",
    ) -> str:
        """Open Hardware Manager, connect to hw_server, pick a target/device.

        Args:
            server_url: hw_server URL (default localhost:3121, started by Vivado
                        when you click "Open Hardware Target" or via cs_server).
            target: substring of the target name to select (default: first).
            device: substring of the device name to select (default: first).
        """
        client = await client_factory()
        data = await client.send_command(
            "connect_hw",
            {"server_url": server_url, "target": target, "device": device},
            timeout=config.timeout_for("connect_hw"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def disconnect_hw() -> str:
        """Close hw_target, disconnect hw_server, close Hardware Manager."""
        client = await client_factory()
        data = await client.send_command(
            "disconnect_hw",
            {},
            timeout=config.timeout_for("disconnect_hw"),
        )
        return json.dumps(data, ensure_ascii=False)

    @mcp.tool()
    async def get_hw_info() -> str:
        """Return Hardware Manager inventory: server, target, devices, ILAs, VIOs."""
        client = await client_factory()
        data = await client.send_command(
            "get_hw_info",
            {},
            timeout=config.timeout_for("get_hw_info"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def program_device(
        bitstream: str,
        probes: str = "",
        device: str = "",
    ) -> str:
        """Flash a bitstream to an FPGA via JTAG.

        Args:
            bitstream: absolute path to a .bit file.
            probes: optional absolute path to a .ltx file (ILA/VIO debug probes).
            device: substring of hw_device name to target (default: current).
        """
        client = await client_factory()
        data = await client.send_command(
            "program_device",
            {"bitstream": bitstream, "probes": probes, "device": device},
            timeout=config.timeout_for("program_device"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def list_hw_probes(core: str) -> str:
        """List probes attached to an ILA or VIO core.

        Args:
            core: ILA/VIO name or substring.
        """
        client = await client_factory()
        data = await client.send_command(
            "list_hw_probes",
            {"core": core},
            timeout=config.timeout_for("list_hw_probes"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_ila_trigger(
        ila: str,
        probe: str,
        value: str,
        operator: str = "==",
        radix: str = "BINARY",
    ) -> str:
        """Set a single-probe compare on an ILA trigger.

        Args:
            ila: ILA name substring.
            probe: probe name substring.
            value: compare value (radix-encoded, e.g. "1010" or "0xFF" or "42").
            operator: "==", "!=", ">", "<", ">=", "<=" (default "==").
            radix: BINARY|HEX|UNSIGNED|SIGNED (default BINARY).
        """
        client = await client_factory()
        data = await client.send_command(
            "set_ila_trigger",
            {
                "ila": ila,
                "probe": probe,
                "value": value,
                "operator": operator,
                "radix": radix,
            },
            timeout=config.timeout_for("set_ila_trigger"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def arm_ila(
        ila: str,
        data_depth: int = 0,
        trigger_position: int = -1,
        trigger_mode: str = "",
    ) -> str:
        """Configure ILA capture parameters and run_hw_ila (arm the trigger).

        Returns immediately — use wait_ila to block until trigger fires.

        Args:
            ila: ILA name substring.
            data_depth: capture depth. 0 = leave current setting.
            trigger_position: sample index where trigger lands. -1 = leave current.
            trigger_mode: "BASIC_ONLY", "BASIC_OR_TRIG_IMMEDIATE", ...
                          Empty = leave current.
        """
        params: Dict[str, Any] = {"ila": ila}
        if data_depth > 0:
            params["data_depth"] = data_depth
        if trigger_position >= 0:
            params["trigger_position"] = trigger_position
        if trigger_mode:
            params["trigger_mode"] = trigger_mode
        client = await client_factory()
        data = await client.send_command(
            "arm_ila",
            params,
            timeout=config.timeout_for("arm_ila"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def wait_ila(ila: str, timeout: int = 30) -> str:
        """Block until the ILA triggers or the timeout expires.

        Args:
            ila: ILA name substring.
            timeout: seconds to wait for trigger (default 30).
        """
        client = await client_factory()
        cmd_timeout = max(float(timeout) + 10.0, config.timeout_for("wait_ila"))
        data = await client.send_command(
            "wait_ila",
            {"ila": ila, "timeout": timeout},
            timeout=cmd_timeout,
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def read_ila_data(ila: str, path: str) -> str:
        """Upload the ILA capture buffer and write it to a CSV or VCD file.

        Args:
            ila: ILA name substring.
            path: absolute output path. Extension determines format:
                  .vcd → VCD waveform, anything else → CSV.
        """
        client = await client_factory()
        data = await client.send_command(
            "read_ila_data",
            {"ila": ila, "path": path},
            timeout=config.timeout_for("read_ila_data"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def get_vio(probe: str) -> str:
        """Refresh and read a VIO input probe value.

        Args:
            probe: probe name substring.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_vio",
            {"probe": probe},
            timeout=config.timeout_for("get_vio"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def list_hw_axis() -> str:
        """Enumerate JTAG-to-AXI masters present in the programmed design."""
        client = await client_factory()
        data = await client.send_command(
            "list_hw_axis", {},
            timeout=config.timeout_for("list_hw_axis"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def axi_read(axi: str, addr: str, len: int = 1) -> str:
        """Read from an AXI slave via a JTAG-to-AXI master.

        Args:
            axi: hw_axi master name substring.
            addr: hex address (e.g. "40000000").
            len: number of 32-bit beats (default 1).

        Returns:
            JSON with a `data` field. `data` is Vivado's DATA property on
            the transaction: a space-separated list of hex words, no
            0x prefix, in beat order — e.g. `"deadbeef cafebabe"` for
            len=2. A single-beat read returns one hex word.
        """
        client = await client_factory()
        data = await client.send_command(
            "axi_read",
            {"axi": axi, "addr": addr, "len": len},
            timeout=config.timeout_for("axi_read"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def axi_write(axi: str, addr: str, data: str) -> str:
        """Write to an AXI slave via a JTAG-to-AXI master.

        Args:
            axi: hw_axi master name substring.
            addr: hex address.
            data: hex value (one beat) or space-separated hex list (burst).
        """
        client = await client_factory()
        resp = await client.send_command(
            "axi_write",
            {"axi": axi, "addr": addr, "data": data},
            timeout=config.timeout_for("axi_write"),
        )
        return json.dumps(resp, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_vio(probe: str, value: str, radix: str = "BINARY") -> str:
        """Write a VIO output probe and commit to the FPGA.

        Args:
            probe: probe name substring.
            value: output value (radix-encoded).
            radix: BINARY|HEX|UNSIGNED|SIGNED (default BINARY).
        """
        client = await client_factory()
        data = await client.send_command(
            "set_vio",
            {"probe": probe, "value": value, "radix": radix},
            timeout=config.timeout_for("set_vio"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)
