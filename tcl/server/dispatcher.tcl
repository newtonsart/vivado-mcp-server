# ==============================================================================
# vivado-mcp-socket :: server/dispatcher.tcl
# ------------------------------------------------------------------------------
# FIFO command queue and dispatch to handlers.
#
# Vivado's TCL interpreter is single-threaded. Commands received from multiple
# clients are serialized in a queue and processed one at a time.
# Each command:
#   1. Is parsed as JSON (via protocol::parse_request)
#   2. Is routed to a handler registered in `::vmcp::handlers`
#   3. The handler decides whether it is synchronous (emits result/error
#      immediately) or asynchronous (emits ack, schedules `after`, and emits
#      result later)
#
# Async handlers keep `busy` at 1 while waiting for completion via `after ...`
# and call `release_async` when done, allowing the next queued command to run.
# ==============================================================================

namespace eval ::vmcp::dispatcher {
    variable queue {}          ;# list of {client_id raw_line}
    variable busy  0           ;# 1 while a command is in flight
    variable current_client "" ;# client whose command is currently executing
    variable current_req_id ""
    variable async_refcount 0  ;# reference counter for async commands
    # Preserve handler registrations across re-source / reload.
    if {![info exists handlers]} {
        variable handlers [dict create]
    }
}

# ------------------------------------------------------------------------------
# Register a handler for a command.
#   name:     MCP command name (e.g. "run_synthesis")
#   proc_ref: TCL procedure that receives (client_id, req_id, params_dict)
#             and MUST emit a response via protocol::send_result / send_error,
#             OR return the string "__async__" to signal that the response
#             will arrive in a later callback (after `after ...`).
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::register {name proc_ref} {
    variable handlers
    dict set handlers $name $proc_ref
    ::vmcp::log::debug "handler registered: $name -> $proc_ref"
}

# ------------------------------------------------------------------------------
# Returns 1 if a handler is registered for the given command name.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::has_handler {name} {
    variable handlers
    return [dict exists $handlers $name]
}

# ------------------------------------------------------------------------------
# Enqueue a raw command. The processing cycle is started with `after idle`
# to avoid re-entering the event loop in the middle of a read.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::enqueue_command {client_id raw_line} {
    variable queue
    lappend queue [list $client_id $raw_line]
    after idle ::vmcp::dispatcher::_process_next
}

# ------------------------------------------------------------------------------
# Process the next queued command if none is in flight.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::_process_next {} {
    variable queue
    variable busy
    variable current_client
    variable current_req_id

    if {$busy} return
    if {[llength $queue] == 0} return

    set item  [lindex $queue 0]
    set queue [lrange $queue 1 end]
    lassign $item client_id raw_line

    # If the client disconnected in the meantime, discard the command.
    if {[::vmcp::core::get_channel $client_id] eq ""} {
        ::vmcp::log::debug "discarding command from disconnected client $client_id"
        after idle ::vmcp::dispatcher::_process_next
        return
    }

    set busy 1
    set current_client $client_id

    # Parse JSON.
    if {[catch {::vmcp::protocol::parse_request $raw_line} parsed]} {
        ::vmcp::log::warn "malformed command from client $client_id: $parsed"
        # No valid req_id available; emit with empty id.
        ::vmcp::protocol::send_error $client_id "" "BAD_REQUEST" \
            "Malformed request" $parsed
        ::vmcp::dispatcher::_release
        return
    }

    set req_id  [dict get $parsed id]
    set command [dict get $parsed command]
    set params  [expr {[dict exists $parsed params] ? [dict get $parsed params] : [dict create]}]
    set current_req_id $req_id

    ::vmcp::log::info "▶ client=$client_id cmd=$command id=$req_id"

    # Look up the handler.
    variable handlers
    if {![dict exists $handlers $command]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "UNKNOWN_COMMAND" "Unknown command: $command"
        ::vmcp::dispatcher::_release
        return
    }
    set proc_ref [dict get $handlers $command]

    # Execute the handler. Any uncaught error is translated to a JSON error.
    if {[catch {
        set rc [eval [list $proc_ref $client_id $req_id $params]]
    } errmsg opts]} {
        set detail [dict get $opts -errorinfo]
        ::vmcp::log::error "handler $command threw exception: $errmsg\n$detail"
        ::vmcp::protocol::send_error $client_id $req_id \
            "TCL_ERROR" $errmsg $detail
        ::vmcp::dispatcher::_release
        return
    }

    # If the handler returns "__async__", the dispatcher stays busy until
    # the handler explicitly calls `release_async`.
    if {$rc eq "__async__"} {
        ::vmcp::log::debug "handler $command marked as async"
        # busy stays at 1; we do not release until release_async is called.
        return
    }

    ::vmcp::dispatcher::_release
}

# ------------------------------------------------------------------------------
# Release the "busy" slot and schedule the next iteration.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::_release {} {
    variable busy
    variable current_client
    variable current_req_id
    set busy 0
    set current_client ""
    set current_req_id ""
    after idle ::vmcp::dispatcher::_process_next
}

# ------------------------------------------------------------------------------
# For async handlers: call this when the operation completes (from an `after`
# callback) to let the dispatcher move on to the next queued command.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::release_async {} {
    ::vmcp::dispatcher::_release
}

# ------------------------------------------------------------------------------
# Called by core when a client disconnects. If the in-flight command belonged
# to that client, we choose to keep running it (synthesis should not be aborted)
# and only flush that client's queued (not-yet-started) commands.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::on_client_disconnect {client_id} {
    variable queue
    set new {}
    foreach item $queue {
        if {[lindex $item 0] ne $client_id} {
            lappend new $item
        }
    }
    set queue $new
}

# ------------------------------------------------------------------------------
# Built-in handler: `ping`. Health check from the Python client.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::handler_ping {client_id req_id params} {
    set ts [clock seconds]
    ::vmcp::protocol::send_result $client_id $req_id [list \
        pong [::vmcp::json::bool 1] \
        timestamp [::vmcp::json::num $ts] \
        vivado_version [::vmcp::dispatcher::_vivado_version]]
    return ok
}

proc ::vmcp::dispatcher::_vivado_version {} {
    if {[catch {version -short} v]} { return "unknown" }
    return $v
}

# ------------------------------------------------------------------------------
# Built-in handler: `run_tcl` — generic escape hatch.
# Executes an arbitrary TCL expression in the Vivado context and returns the
# result as a string. No security filtering; use responsibly.
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::handler_run_tcl {client_id req_id params} {
    if {![dict exists $params expr]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'expr' parameter"
        return
    }
    set expr [dict get $params expr]
    ::vmcp::log::info "run_tcl: $expr"
    set catchcode [catch {uplevel #0 $expr} result opts]
    if {$catchcode == 1} {
        set detail ""
        catch { set detail [dict get $opts -errorinfo] }
        ::vmcp::protocol::send_error $client_id $req_id \
            "TCL_ERROR" $result $detail
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id [list \
        result  $result \
        type    [::vmcp::dispatcher::_guess_type $result]]
    return ok
}

# ------------------------------------------------------------------------------
# Built-in handler: `reload_plugin` — hot-reload all handler files via MCP.
# Optionally accepts a `source_dir` param to reload from a different path
# (e.g. the repo checkout instead of the installed copy).
# ------------------------------------------------------------------------------
proc ::vmcp::dispatcher::handler_reload {client_id req_id params} {
    set src_dir ""
    if {[dict exists $params source_dir]} {
        set src_dir [dict get $params source_dir]
    }
    if {$src_dir eq ""} {
        set src_dir $::vmcp::server::SCRIPT_DIR
    }

    if {![file isdirectory $src_dir]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "source_dir does not exist: $src_dir"
        return
    }

    set handler_files [list \
        [file join $src_dir handlers project.tcl] \
        [file join $src_dir handlers synthesis.tcl] \
        [file join $src_dir handlers implementation.tcl] \
        [file join $src_dir handlers reports.tcl] \
        [file join $src_dir handlers netlist.tcl]]

    set ok 0
    set fail 0
    set errors [list]
    foreach f $handler_files {
        set short [file tail $f]
        if {![file exists $f]} {
            incr fail
            lappend errors "not found: $short"
            continue
        }
        if {[catch {source $f} err]} {
            incr fail
            lappend errors "error in $short: $err"
        } else {
            incr ok
        }
    }

    # Re-register builtins (ping, run_tcl, reload_plugin).
    catch {::vmcp::server::_register_builtins}
    # Fallback if _register_builtins doesn't exist (old installed vivado_server.tcl).
    catch {::vmcp::dispatcher::register ping           ::vmcp::dispatcher::handler_ping}
    catch {::vmcp::dispatcher::register run_tcl        ::vmcp::dispatcher::handler_run_tcl}
    catch {::vmcp::dispatcher::register reload_plugin  ::vmcp::dispatcher::handler_reload}

    set summary "$ok reloaded, $fail failed"
    if {[llength $errors] > 0} {
        append summary "; errors: [join $errors {, }]"
    }

    ::vmcp::protocol::send_result $client_id $req_id [list \
        result     $summary \
        source_dir $src_dir \
        ok         [::vmcp::json::num $ok] \
        failed     [::vmcp::json::num $fail]]
    return ok
}

proc ::vmcp::dispatcher::_guess_type {val} {
    if {[string is integer -strict $val]} { return "int" }
    if {[string is double -strict $val]}  { return "float" }
    return "string"
}
