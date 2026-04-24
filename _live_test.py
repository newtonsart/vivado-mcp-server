"""Live tool exercise against running Vivado on 127.0.0.1:7654.

Runs read-only / non-destructive tests. Skips:
  - run_synthesis / run_implementation / generate_bitstream (slow, mutate)
  - close_project / open_project with different xpr (would lose state)
  - restart_server (would kill us)
  - Hardware Manager tools (no board)
  - Constraints that mutate the live design
  - reset_run (destroys cached run data)
"""
from __future__ import annotations
import asyncio, json, os, sys, tempfile, time
sys.path.insert(0, 'python')
from vivado_mcp_server.vivado.client import VivadoClient
from vivado_mcp_server.vivado.exceptions import VivadoRemoteError, VivadoTimeoutError

PASS, FAIL, SKIP = [], [], []

async def call(vv, cmd, params=None, timeout=120.0, expect=None, note=""):
    try:
        d = await vv.send_command(cmd, params or {}, timeout=timeout)
        if expect and not expect(d):
            FAIL.append((cmd, f"expect mismatch: {d}"))
            print(f"  FAIL {cmd}: expect mismatch")
            return d
        PASS.append((cmd, note))
        print(f"  PASS {cmd}" + (f" ({note})" if note else ""))
        return d
    except VivadoRemoteError as e:
        FAIL.append((cmd, f"{e.code}: {e.message}"))
        print(f"  FAIL {cmd}: {e.code}: {e.message[:100]}")
    except VivadoTimeoutError as e:
        FAIL.append((cmd, f"timeout: {e}"))
        print(f"  FAIL {cmd}: timeout")
    return None

async def call_expect_err(vv, cmd, params, code, timeout=30.0):
    try:
        d = await vv.send_command(cmd, params, timeout=timeout)
        FAIL.append((cmd, f"expected error {code}, got {d}"))
        print(f"  FAIL {cmd}: expected err {code}")
    except VivadoRemoteError as e:
        if e.code == code:
            PASS.append((cmd, f"err {code} as expected"))
            print(f"  PASS {cmd} (err {code} as expected)")
        else:
            FAIL.append((cmd, f"got {e.code}, wanted {code}"))
            print(f"  FAIL {cmd}: got {e.code}, wanted {code}")

def skip(cmd, reason):
    SKIP.append((cmd, reason))
    print(f"  SKIP {cmd}: {reason}")

async def main():
    tmpdir = tempfile.mkdtemp(prefix="vmcp_test_")
    print(f"tmpdir: {tmpdir}\n")
    async with VivadoClient(host='127.0.0.1', port=7654, reconnect_max_attempts=2) as vv:

        print("== Meta ==")
        await call(vv, "ping", timeout=5, expect=lambda d: d.get("pong") is True)
        await call(vv, "run_tcl", {"expr": "expr 2+2"}, timeout=10,
                   expect=lambda d: d.get("result") == "4")
        await call(vv, "run_tcl", {"expr": "version -short"}, timeout=10,
                   expect=lambda d: "2023" in str(d.get("result", "")))
        await call(vv, "get_recent_events" if False else "ping", timeout=5)  # recent_events is Python-side
        await call_expect_err(vv, "run_tcl", {}, "INVALID_PARAMS")
        await call_expect_err(vv, "no_such_command", {}, "UNKNOWN_COMMAND")
        skip("reload_plugin", "would churn handlers; tested separately")
        skip("restart_server", "Python-side only, would kill us")

        print("\n== Project ==")
        info = await call(vv, "get_project_info", timeout=15,
                          expect=lambda d: d.get("name"))
        if info:
            top = info.get("top", "")
            xpr = info.get("xpr_file", "")
            print(f"  project: {info.get('name')} part={info.get('part')} top={top}")
        # write_checkpoint
        dcp = os.path.join(tmpdir, "test.dcp").replace("\\", "/")
        await call(vv, "write_checkpoint", {"path": dcp}, timeout=120,
                   expect=lambda d: d.get("written") is True)
        # write_xdc
        xdc = os.path.join(tmpdir, "test.xdc").replace("\\", "/")
        await call(vv, "write_xdc", {"path": xdc}, timeout=60,
                   expect=lambda d: d.get("size_bytes", 0) >= 0)
        # read_xdc — use the file we just wrote
        if os.path.exists(xdc):
            await call(vv, "read_xdc", {"path": xdc}, timeout=30,
                       expect=lambda d: d.get("added") is True)
        # set_top — set current top back to itself (no-op)
        if info and info.get("top"):
            await call(vv, "set_top", {"top": info["top"]}, timeout=30,
                       expect=lambda d: d.get("top") == info["top"])
        skip("open_project", "already open; different xpr would lose state")
        skip("close_project", "would lose test context")

        print("\n== Synthesis/runs ==")
        await call(vv, "get_run_status", {"run": "synth_1"}, timeout=10,
                   expect=lambda d: d.get("run") == "synth_1")
        await call(vv, "get_run_status", {"run": "impl_1"}, timeout=10,
                   expect=lambda d: d.get("run") == "impl_1")
        await call(vv, "list_strategies", {"flow": "synth"}, timeout=30,
                   expect=lambda d: d.get("count", 0) > 0)
        await call(vv, "list_strategies", {"flow": "impl"}, timeout=30,
                   expect=lambda d: d.get("count", 0) > 0)
        await call(vv, "get_run_stats", {"run": "synth_1"}, timeout=15)
        await call(vv, "get_run_stats", {"run": "impl_1"}, timeout=15)
        await call_expect_err(vv, "get_run_stats", {"run": "no_such_run"}, "RUN_NOT_FOUND")
        skip("run_synthesis", "slow, mutates")
        skip("run_implementation", "slow, mutates")
        skip("generate_bitstream", "slow, mutates")
        skip("reset_run", "destroys cached run data")
        skip("set_run_strategy", "mutates run config")
        skip("wait_on_run", "blocks on non-running run")

        print("\n== Reports ==")
        await call(vv, "get_timing_summary", {"run": "impl_1"}, timeout=60)
        await call(vv, "get_utilization", {}, timeout=120)
        await call(vv, "get_messages", {"severity": "ERROR", "limit": 10}, timeout=30)
        await call(vv, "get_messages", {"severity": "WARNING", "limit": 5}, timeout=30)
        # Design-open reports — use path= to avoid 64MB socket buffer issues
        for cmd in ["get_drc", "get_timing_paths", "get_power_report",
                    "get_cdc_report", "get_methodology_violations",
                    "get_io_report", "get_fanout_report"]:
            p = os.path.join(tmpdir, f"{cmd}.txt").replace("\\", "/")
            params = {"path": p} if cmd != "get_timing_paths" else {"max_paths": 3, "delay_type": "max"}
            await call(vv, cmd, params, timeout=600)

        print("\n== Netlist ==")
        await call(vv, "get_cells", {"pattern": "*", "limit": 20}, timeout=60,
                   expect=lambda d: d.get("returned", 0) >= 0)
        await call(vv, "get_nets", {"pattern": "*", "limit": 20}, timeout=60)
        await call(vv, "get_ports", {"pattern": "*"}, timeout=30)
        await call(vv, "get_clocks", {}, timeout=30)
        await call(vv, "get_design_hierarchy", {"max_depth": 2}, timeout=60)

        print("\n== Constraints (read-only probes) ==")
        skip("create_clock", "would mutate design constraints")
        skip("create_generated_clock", "same")
        skip("set_input_delay", "same")
        skip("set_output_delay", "same")
        skip("set_false_path", "same")
        skip("set_multicycle_path", "same")
        skip("set_clock_groups", "same")
        await call(vv, "report_exceptions", {}, timeout=120)

        print("\n== Hardware Manager ==")
        for cmd in ["connect_hw", "disconnect_hw", "get_hw_info", "program_device",
                    "list_hw_probes", "set_ila_trigger", "arm_ila", "wait_ila",
                    "read_ila_data", "get_vio", "set_vio", "list_hw_axis",
                    "axi_read", "axi_write"]:
            skip(cmd, "no FPGA connected")

    print(f"\n==== SUMMARY ====")
    print(f"PASS:  {len(PASS)}")
    print(f"FAIL:  {len(FAIL)}")
    print(f"SKIP:  {len(SKIP)}")
    if FAIL:
        print("\nFAILURES:")
        for c, r in FAIL:
            print(f"  {c}: {r}")
    return 0 if not FAIL else 1

sys.exit(asyncio.run(main()))
