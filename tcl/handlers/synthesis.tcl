# ==============================================================================
# vivado-mcp-socket :: handlers/synthesis.tcl
# ------------------------------------------------------------------------------
# Handlers related to synthesis:
#   - run_synthesis  (async, with 5s polling and progress events)
#   - get_run_status (sync, returns a point-in-time snapshot)
#   - reset_run      (resets a run)
#
# Pattern used for run_synthesis:
#   1. Validate that a project is open
#   2. Optional `reset_run synth_1` if it has already run
#   3. `launch_runs synth_1 -jobs N` (non-blocking in Vivado)
#   4. `send_ack` to the client
#   5. Schedule `after 5000 poll_run` to check STATUS/PROGRESS
#   6. While not "Complete" or "Failed", emit `send_progress`
#   7. On completion, `send_result` with relevant info and release dispatcher
# ==============================================================================

namespace eval ::vmcp::handlers::synthesis {
    # Per-req_id state for in-progress polls. Guard against re-source wiping
    # state during an active run.
    if {![info exists active_polls]} { variable active_polls [dict create] }
}

# ------------------------------------------------------------------------------
# run_synthesis
# params:
#   run      (string, optional, default "synth_1")
#   jobs     (int,    optional, default 4)
#   strategy (string, optional)
#   reset    (bool,   optional, default false) — reset before launching
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::run {client_id req_id params} {
    variable active_polls

    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }

    set run_name [expr {[dict exists $params run]  ? [dict get $params run]  : "synth_1"}]
    set jobs     [expr {[dict exists $params jobs] ? [dict get $params jobs] : 4}]
    set reset    0
    if {[dict exists $params reset]} {
        set v [dict get $params reset]
        if {[string is true -strict $v]} { set reset 1 }
    }

    # Validate that the run exists.
    if {[catch {get_runs $run_name} run_obj]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run_name' does not exist: $run_obj"
        return
    }

    # Optional strategy.
    if {[dict exists $params strategy]} {
        set strategy [dict get $params strategy]
        catch {set_property strategy $strategy [get_runs $run_name]}
    }

    # Reset if requested.
    if {$reset} {
        ::vmcp::log::log_info "reset_run $run_name (before launch)"
        catch {reset_run $run_name}
    }

    # launch_runs is NON-BLOCKING in Vivado: spawns a child process and returns.
    if {[catch {launch_runs $run_name -jobs $jobs} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "LAUNCH_FAILED" "launch_runs failed: $err" \
            [dict get $opts -errorinfo]
        return
    }

    ::vmcp::protocol::send_ack $client_id $req_id \
        "Synthesis launched ($run_name, jobs=$jobs)"

    dict set active_polls $req_id [dict create \
        client_id $client_id \
        run_name  $run_name \
        jobs      $jobs \
        start_ts  [clock seconds] \
        last_pct  -1]

    # First poll after 2s (startup), then every 5s.
    after 2000 [list ::vmcp::handlers::synthesis::_poll $req_id]
    return "__async__"
}

# ------------------------------------------------------------------------------
# Periodic poll: checks STATUS/PROGRESS and emits progress or result.
# Shared pieces live in ::vmcp::runs (handlers/runs_common.tcl).
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::_poll {req_id} {
    variable active_polls

    if {![dict exists $active_polls $req_id]} return
    set ctx [dict get $active_polls $req_id]
    set client_id [dict get $ctx client_id]
    set run_name  [dict get $ctx run_name]

    if {[::vmcp::runs::client_gone $client_id]} {
        ::vmcp::log::log_info "poll $run_name: client $client_id disconnected, stopping poll"
        dict unset active_polls $req_id
        ::vmcp::dispatcher::release_async
        return
    }

    set state [::vmcp::runs::read_state $client_id $req_id $run_name]
    if {$state eq ""} {
        dict unset active_polls $req_id
        ::vmcp::dispatcher::release_async
        return
    }
    lassign $state status pct

    if {[string match -nocase "*Complete*" $status]} {
        ::vmcp::log::log_info "run $run_name: Complete"
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::handlers::synthesis::_final_payload $run_name $status $pct ok]
        dict unset active_polls $req_id
        ::vmcp::protocol::broadcast_notification "run_complete" \
            [list run $run_name status $status]
        ::vmcp::dispatcher::release_async
        return
    }

    if {[::vmcp::runs::is_failed $status]} {
        ::vmcp::log::log_warn "run $run_name: Failed ($status)"
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_FAILED" "Synthesis run failed" $status
        dict unset active_polls $req_id
        ::vmcp::protocol::broadcast_notification "run_failed" \
            [list run $run_name status $status]
        ::vmcp::dispatcher::release_async
        return
    }

    set last_pct [dict get $ctx last_pct]
    set new_last [::vmcp::runs::maybe_emit_progress $client_id $req_id $status $pct $last_pct]
    dict set ctx last_pct $new_last
    dict set active_polls $req_id $ctx

    after 5000 [list ::vmcp::handlers::synthesis::_poll $req_id]
}

# ------------------------------------------------------------------------------
# Build the final payload for a completed run. Cached STATS.* are only
# meaningful once synth_design has written a DCP.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::_final_payload {run_name status pct outcome} {
    set t [::vmcp::runs::timing_stats $run_name]
    return [::vmcp::json::obj [list \
        run      $run_name \
        status   $status \
        progress [::vmcp::json::num $pct] \
        outcome  $outcome \
        wns      [::vmcp::json::num_or_null [dict get $t wns]] \
        tns      [::vmcp::json::num_or_null [dict get $t tns]] \
        whs      [::vmcp::json::num_or_null [dict get $t whs]] \
        ths      [::vmcp::json::num_or_null [dict get $t ths]]]]
}

# ------------------------------------------------------------------------------
# get_run_status — synchronous point-in-time snapshot.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::status {client_id req_id params} {
    set run_name [expr {[dict exists $params run] ? [dict get $params run] : "synth_1"}]
    if {[catch {get_runs $run_name} err]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run_name' does not exist: $err"
        return
    }
    set status [get_property STATUS [get_runs $run_name]]
    set prog   0
    catch { set prog [get_property PROGRESS [get_runs $run_name]] }
    set pct [::vmcp::runs::percent $prog]

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            run      $run_name \
            status   $status \
            progress [::vmcp::json::num $pct]]]
    return ok
}

# ------------------------------------------------------------------------------
# reset_run — reset a run so it can be re-launched.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::reset {client_id req_id params} {
    set run_name [expr {[dict exists $params run] ? [dict get $params run] : "synth_1"}]
    if {[catch {reset_run $run_name} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RESET_FAILED" "reset_run failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [list run $run_name reset [::vmcp::json::bool 1]]
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register run_synthesis   ::vmcp::handlers::synthesis::run
::vmcp::dispatcher::register get_run_status  ::vmcp::handlers::synthesis::status
::vmcp::dispatcher::register reset_run       ::vmcp::handlers::synthesis::reset
