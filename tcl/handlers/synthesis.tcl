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
    # Per-req_id state for in-progress polls.
    # key: req_id -> dict {client_id ... run_name ... jobs ... start_ts ...}
    variable active_polls [dict create]
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
        ::vmcp::log::info "reset_run $run_name (before launch)"
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
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::_poll {req_id} {
    variable active_polls

    if {![dict exists $active_polls $req_id]} {
        # Polling was cancelled (client disconnected, project closed, ...).
        return
    }
    set ctx [dict get $active_polls $req_id]
    set client_id [dict get $ctx client_id]
    set run_name  [dict get $ctx run_name]

    # If the client is gone, stop polling but do NOT abort the run.
    if {[::vmcp::core::get_channel $client_id] eq ""} {
        ::vmcp::log::info "poll $run_name: client $client_id disconnected, stopping poll"
        dict unset active_polls $req_id
        ::vmcp::dispatcher::release_async
        return
    }

    # Read run state.
    if {[catch {get_property STATUS   [get_runs $run_name]} status]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "POLL_FAILED" "Cannot read run STATUS: $status"
        dict unset active_polls $req_id
        ::vmcp::dispatcher::release_async
        return
    }
    set progress_raw 0
    catch { set progress_raw [get_property PROGRESS [get_runs $run_name]] }
    set pct [::vmcp::handlers::synthesis::_percent $progress_raw]

    # Complete?
    if {[string match -nocase "*Complete*" $status]} {
        ::vmcp::log::info "run $run_name: Complete"
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::handlers::synthesis::_final_payload $run_name $status $pct ok]
        dict unset active_polls $req_id
        ::vmcp::protocol::broadcast_notification "run_complete" \
            [list run $run_name status $status]
        ::vmcp::dispatcher::release_async
        return
    }

    # Failed / Error?
    if {[string match -nocase "*Error*"  $status] || \
        [string match -nocase "*Failed*" $status]} {
        ::vmcp::log::warn "run $run_name: Failed ($status)"
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_FAILED" "Synthesis run failed" $status
        dict unset active_polls $req_id
        ::vmcp::protocol::broadcast_notification "run_failed" \
            [list run $run_name status $status]
        ::vmcp::dispatcher::release_async
        return
    }

    # Still running -> emit progress only if pct changed (avoid spam).
    set last_pct [dict get $ctx last_pct]
    if {$pct != $last_pct} {
        ::vmcp::protocol::send_progress $client_id $req_id $pct $status
        dict set ctx last_pct $pct
        dict set active_polls $req_id $ctx
    }

    # Schedule next poll.
    after 5000 [list ::vmcp::handlers::synthesis::_poll $req_id]
}

# ------------------------------------------------------------------------------
# Extract an integer 0-100 from the PROGRESS value (may arrive as "15%").
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::_percent {raw} {
    set clean [regsub -all {%} $raw ""]
    set clean [string trim $clean]
    if {[string is integer -strict $clean]} { return $clean }
    if {[string is double  -strict $clean]} { return [expr {int($clean)}] }
    return 0
}

# ------------------------------------------------------------------------------
# Build the final payload for a completed run.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::synthesis::_final_payload {run_name status pct outcome} {
    set wns ""
    set tns ""
    set whs ""
    set ths ""
    catch {
        # Only meaningful if synth_design generated a DCP.
        set wns [get_property STATS.WNS [get_runs $run_name]]
        set tns [get_property STATS.TNS [get_runs $run_name]]
        set whs [get_property STATS.WHS [get_runs $run_name]]
        set ths [get_property STATS.THS [get_runs $run_name]]
    }
    return [::vmcp::json::obj [list \
        run      $run_name \
        status   $status \
        progress [::vmcp::json::num $pct] \
        outcome  $outcome \
        wns      $wns \
        tns      $tns \
        whs      $whs \
        ths      $ths]]
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
    set pct [::vmcp::handlers::synthesis::_percent $prog]

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
