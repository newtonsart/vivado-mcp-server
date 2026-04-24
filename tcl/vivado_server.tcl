# ==============================================================================
# vivado-mcp-socket :: vivado_server.tcl  (ENTRY POINT)
# ------------------------------------------------------------------------------
# This script is loaded automatically from Vivado_init.tcl:
#
#   source [file join $env(USERPROFILE) .vivado-mcp tcl vivado_server.tcl]
#
# and starts the TCP plugin server.
#
# Optional environment variables:
#   VMCP_PORT     (default 7654)
#   VMCP_HOST     (default 127.0.0.1)
#   VMCP_LOGFILE  (default <script_dir>/../vmcp.log)
#   VMCP_LOGLEVEL (default INFO)
#
# Manual / batch-mode usage:
#   source vivado_server.tcl
#   ::vmcp::server::start          ;# start the server
#   ::vmcp::server::stop           ;# stop the server
#   ::vmcp::server::reload         ;# hot-reload all handler files
#
# In batch mode (`vivado -mode batch` or `vivado -mode tcl`), append:
#   vwait ::vmcp::core::started
# ==============================================================================

namespace eval ::vmcp {}
namespace eval ::vmcp::server {}

# ------------------------------------------------------------------------------
# Robust detection of this script's directory.
# ------------------------------------------------------------------------------
set ::vmcp::server::SCRIPT_DIR [file normalize [file dirname [info script]]]

# ------------------------------------------------------------------------------
# Load modules in dependency order:
#   1. logger         (no deps)
#   2. json           (no deps; optionally uses tcllib)
#   3. protocol       (depends on json + logger)
#   4. core           (depends on logger; calls dispatcher in callbacks)
#   5. dispatcher     (depends on protocol, logger)
#   6. handlers/*     (depend on everything above)
# ------------------------------------------------------------------------------
proc ::vmcp::server::_source_all {} {
    variable SCRIPT_DIR
    set dir $::vmcp::server::SCRIPT_DIR
    set files [list \
        [file join $dir lib      logger.tcl] \
        [file join $dir lib      json.tcl] \
        [file join $dir server   protocol.tcl] \
        [file join $dir server   core.tcl] \
        [file join $dir server   dispatcher.tcl] \
        [file join $dir handlers runs_common.tcl] \
        [file join $dir handlers project.tcl] \
        [file join $dir handlers synthesis.tcl] \
        [file join $dir handlers implementation.tcl] \
        [file join $dir handlers reports.tcl] \
        [file join $dir handlers netlist.tcl] \
        [file join $dir handlers hardware.tcl] \
        [file join $dir handlers constraints.tcl] \
        [file join $dir handlers runs.tcl]]

    foreach f $files {
        if {![file exists $f]} {
            puts "\[vmcp\] ERROR: file not found: $f"
            continue
        }
        if {[catch {source $f} err opts]} {
            puts "\[vmcp\] ERROR loading $f: $err"
            puts [dict get $opts -errorinfo]
        }
    }
}

# ------------------------------------------------------------------------------
# Configure logging from environment variables.
# ------------------------------------------------------------------------------
proc ::vmcp::server::_configure_logging {} {
    variable SCRIPT_DIR
    set level "INFO"
    if {[info exists ::env(VMCP_LOGLEVEL)]} {
        set level $::env(VMCP_LOGLEVEL)
    }
    ::vmcp::log::set_level $level

    set logfile ""
    if {[info exists ::env(VMCP_LOGFILE)]} {
        set logfile $::env(VMCP_LOGFILE)
    } else {
        # Default: vmcp.log next to the entry-point script (one level up).
        set logfile [file join [file dirname $SCRIPT_DIR] vmcp.log]
    }
    if {$logfile ne ""} {
        ::vmcp::log::set_file $logfile
    }
}

# ------------------------------------------------------------------------------
# Register built-in commands (ping, run_tcl) once the dispatcher is loaded.
# ------------------------------------------------------------------------------
proc ::vmcp::server::_register_builtins {} {
    ::vmcp::dispatcher::register ping           ::vmcp::dispatcher::handler_ping
    ::vmcp::dispatcher::register run_tcl        ::vmcp::dispatcher::handler_run_tcl
    ::vmcp::dispatcher::register reload_plugin  ::vmcp::dispatcher::handler_reload
}

# ------------------------------------------------------------------------------
# Start the full server.
# ------------------------------------------------------------------------------
proc ::vmcp::server::start {{port ""} {host ""}} {
    if {$port eq ""} {
        set port [expr {[info exists ::env(VMCP_PORT)] ? $::env(VMCP_PORT) : 7654}]
    }
    if {$host eq ""} {
        set host [expr {[info exists ::env(VMCP_HOST)] ? $::env(VMCP_HOST) : "127.0.0.1"}]
    }

    # Defense-in-depth: force localhost even if a different IP is passed.
    if {$host ne "127.0.0.1" && $host ne "localhost" && $host ne "::1"} {
        ::vmcp::log::log_warn "host '$host' is not localhost; forcing 127.0.0.1"
        set host "127.0.0.1"
    }

    ::vmcp::core::start $port $host
}

# ------------------------------------------------------------------------------
# Stop the server.
# ------------------------------------------------------------------------------
proc ::vmcp::server::stop {} {
    ::vmcp::core::stop
}

# ------------------------------------------------------------------------------
# Hot-reload all handler files without restarting the server.
# Safe to call while the server is running: only re-sources handler files,
# which re-define procs and re-register commands. Core state is untouched.
# ------------------------------------------------------------------------------
proc ::vmcp::server::reload {} {
    variable SCRIPT_DIR
    set dir $::vmcp::server::SCRIPT_DIR
    set handler_files [list \
        [file join $dir handlers runs_common.tcl] \
        [file join $dir handlers project.tcl] \
        [file join $dir handlers synthesis.tcl] \
        [file join $dir handlers implementation.tcl] \
        [file join $dir handlers reports.tcl] \
        [file join $dir handlers netlist.tcl] \
        [file join $dir handlers hardware.tcl] \
        [file join $dir handlers constraints.tcl] \
        [file join $dir handlers runs.tcl]]

    set ok   0
    set fail 0
    foreach f $handler_files {
        set short [file tail $f]
        if {![file exists $f]} {
            puts "\[vmcp\] reload: file not found: $f"
            incr fail
            continue
        }
        if {[catch {source $f} err opts]} {
            puts "\[vmcp\] reload: error in $short: $err"
            puts [dict get $opts -errorinfo]
            incr fail
        } else {
            puts "\[vmcp\] reload: OK $short"
            incr ok
        }
    }
    puts "\[vmcp\] reload complete: $ok reloaded, $fail failed"
}

# ==============================================================================
# BOOTSTRAP
# ==============================================================================

# Re-source guard: Vivado re-runs Vivado_init.tcl on start_gui and some
# project operations. We must not re-bind the TCP socket or re-log the banner.
if {[info exists ::vmcp::core::started] && $::vmcp::core::started} {
    # Already running. Silently re-register handlers only (hot-reload-friendly).
    ::vmcp::server::_source_all
    ::vmcp::server::_register_builtins
    return
}

::vmcp::server::_source_all
::vmcp::server::_configure_logging
::vmcp::server::_register_builtins

# Auto-start (can be disabled with `set ::env(VMCP_AUTOSTART) 0`).
set _autostart 1
if {[info exists ::env(VMCP_AUTOSTART)]} {
    if {![string is true -strict $::env(VMCP_AUTOSTART)]} { set _autostart 0 }
}

if {$_autostart} {
    ::vmcp::server::start
}

puts "vivado-mcp-server: plugin loaded. Commands: ::vmcp::server::start / ::vmcp::server::stop / ::vmcp::server::reload"
