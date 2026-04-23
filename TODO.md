# TODO — Vivado MCP Server

Backlog de features pro no implementadas todavía. Marcar con `[x]` al hacer.

## Implementado esta iteración

- [x] Run strategies: `list_strategies`, `set_run_strategy`, `get_run_stats`, `wait_on_run`
- [x] JTAG-to-AXI: `list_hw_axis`, `axi_read`, `axi_write`
- [x] Constraints setters: `create_clock`, `create_generated_clock`,
      `set_input_delay`, `set_output_delay`, `set_false_path`,
      `set_multicycle_path`, `set_clock_groups`, `report_exceptions`

## Pendiente — alto impacto

### Source / fileset management
- [ ] `add_files(path, fileset, file_type?, library?)` — src/xdc/sim
- [ ] `remove_files(path, fileset)`
- [ ] `reorder_files(fileset, order)` — XDC order matters
- [ ] `set_file_property(path, property, value)` — FILE_TYPE, LIBRARY,
      USED_IN_{SYNTHESIS,SIMULATION,IMPLEMENTATION}, IS_GLOBAL_INCLUDE
- [ ] `update_compile_order(fileset)`
- [ ] `list_files(fileset, type?)` — enumerate sources + properties

### Run automation
- [ ] `launch_runs_parallel(runs, jobs)` — `launch_runs -jobs N` over list
- [ ] `sweep_strategies(strategies, flow, target_wns?)` — async:
      reset → set strategy → launch → wait, return WNS/TNS table
- [ ] `archive_run(run, dest_dir)` — snapshot logs+reports+checkpoints

### IP Catalog / Block Design
- [ ] `create_ip(vlnv, name, properties?)` — instantiate from catalog
- [ ] `set_ip_property(ip, property, value)` / `generate_target(ip, targets)`
- [ ] `upgrade_ip(ip?)` / `report_ip_status()`
- [ ] `create_bd_design(name)` + `create_bd_cell` / `connect_bd_net` /
      `connect_bd_intf_net` / `validate_bd_design` / `make_wrapper`
- [ ] `save_bd_design()` / `open_bd_design(path)`

### Simulación
- [ ] `launch_simulation(testbench?, fileset=sim_1)` — xsim
- [ ] `add_sim_files(paths, testbench?)` — simset management
- [ ] `read_saif(path)` — vector-based power analysis input

### Debug insertion sin recompilar RTL
- [ ] `mark_debug(nets, value=true)` — flag nets para debug
- [ ] `create_debug_core(name, type=ila)` — core nuevo
- [ ] `connect_debug_port(core, port, nets)`
- [ ] `write_debug_probes(path)` — genera .ltx

## Pendiente — media

### SysMon / telemetry en runtime
- [ ] `read_hw_sysmon(sensor)` — TEMP/VCCINT/VCCAUX/VCCBRAM
- [ ] `get_hw_sysmon_reg(addr)` — raw DRP read
- [ ] `monitor_sysmon(interval, count)` — streaming samples

### Flash boot (SPI/QSPI/BPI)
- [ ] `write_cfgmem(bit, output, format=mcs|bin, interface=spix4, size?)` —
      convertir .bit a .mcs/.bin
- [ ] `create_hw_cfgmem(device, part)` — objeto cfgmem
- [ ] `program_hw_cfgmem(cfgmem, file)` — flashear memoria externa
- [ ] `boot_hw_device(device)` — trigger arranque

### Reproducibilidad / archive
- [ ] `write_project_tcl(path)` — script que recrea proyecto
- [ ] `archive_project(path, include_runs?)` — zip con todo

### Análisis avanzado
- [ ] `report_pulse_width(path?)`
- [ ] `report_bus_skew(path?)`
- [ ] `report_ssn(path?)` — signal integrity
- [ ] `report_carry_chains(path?)`
- [ ] `report_control_sets(path?)`
- [ ] `report_ram_utilization(path?)`
- [ ] `report_design_analysis(path?)` — complexity + congestion
- [ ] `report_qor_assessment(path?)`

## Pendiente — baja

- [ ] `create_project(name, dir, part)` — proyecto desde cero
- [ ] `get_clock_interaction(path?)` — report_clock_interaction
- [ ] `open_checkpoint(dcp)` — sin proyecto (non-project flow)
- [ ] `link_design(part, top)` — non-project flow
- [ ] `set_property(object, property, value)` — setter genérico
      escape hatch tipado
- [ ] `boot_hw_device` / `reset_hw_axi` variants

## Bugs/TechDebt conocidos

- Python MCP server requiere reinicio manual para activar tools nuevos
  (hot-reload es solo TCL-side). Posible mejora: watchdog + auto-restart.
- `asyncio.open_connection limit=64 MB` ya fijo; verificar en tests.
- `run_tcl` con `return` en escopes no raíz falla en dispatcher viejos;
  revisar si queda algún Vivado con dispatcher stale en memoria.
- `reload_plugin` no resource el core/dispatcher, solo handlers. Para
  cambios en core/dispatcher hay que reiniciar Vivado o re-source
  manualmente via `run_tcl`.
