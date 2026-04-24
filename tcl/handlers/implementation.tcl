# ==============================================================================
# vivado-mcp-socket :: handlers/implementation.tcl
# ------------------------------------------------------------------------------
# Implementation and bitstream handlers. Reuses the polling pattern from
# synthesis.tcl: non-blocking launch_runs -> ack -> `after 5000` polling.
#
#   - run_implementation  (impl_1)
#   - generate_bitstream  (impl_1 -to_step write_bitstream)
# ==============================================================================

namespace eval ::vmcp::handlers::impl {
    if {![info exists active_polls]} { variable active_polls [dict create] }
}

# ------------------------------------------------------------------------------
# run_implementation
# params:
#   run      (default impl_1), jobs (default 4), strategy, reset (bool)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::impl::run {client_id req_id params} {
    variable active_polls

    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }

    set run_name [expr {[dict exists $params run]  ? [dict get $params run]  : "impl_1"}]
    set jobs     [expr {[dict exists $params jobs] ? [dict get $params jobs] : 4}]
    set reset    0
    if {[dict exists $params reset]} {
        set v [dict get $params reset]
        if {[string is true -strict $v]} { set reset 1 }
    }

    if {[catch {get_runs $run_name} err]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run_name' does not exist: $err"
        return
    }

    if {[dict exists $params strategy]} {
        catch {set_property strategy [dict get $params strategy] [get_runs $run_name]}
    }

    if {$reset} {
        catch {reset_run $run_name}
    }

    if {[catch {launch_runs $run_name -jobs $jobs} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "LAUNCH_FAILED" "launch_runs failed: $err" \
            [dict get $opts -errorinfo]
        return
    }

    ::vmcp::protocol::send_ack $client_id $req_id \
        "Implementation launched ($run_name, jobs=$jobs)"

    dict set active_polls $req_id [dict create \
        client_id  $client_id \
        run_name   $run_name \
        target     "impl" \
        jobs       $jobs \
        bitstream  0 \
        last_pct   -1]

    after 3000 [list ::vmcp::handlers::impl::_poll $req_id]
    return "__async__"
}

# ------------------------------------------------------------------------------
# generate_bitstream
# params:
#   run (default impl_1), jobs (default 4), reset (bool)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::impl::bitstream {client_id req_id params} {
    variable active_polls

    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }

    set run_name [expr {[dict exists $params run]  ? [dict get $params run]  : "impl_1"}]
    set jobs     [expr {[dict exists $params jobs] ? [dict get $params jobs] : 4}]
    set reset    0
    if {[dict exists $params reset]} {
        set v [dict get $params reset]
        if {[string is true -strict $v]} { set reset 1 }
    }

    if {[catch {get_runs $run_name} err]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run_name' does not exist: $err"
        return
    }

    if {$reset} { catch {reset_run $run_name} }

    if {[catch {launch_runs $run_name -to_step write_bitstream -jobs $jobs} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "LAUNCH_FAILED" "launch_runs (bitstream) failed: $err" \
            [dict get $opts -errorinfo]
        return
    }

    ::vmcp::protocol::send_ack $client_id $req_id \
        "Bitstream generation launched ($run_name)"

    dict set active_polls $req_id [dict create \
        client_id  $client_id \
        run_name   $run_name \
        target     "bitstream" \
        jobs       $jobs \
        bitstream  1 \
        last_pct   -1]

    after 3000 [list ::vmcp::handlers::impl::_poll $req_id]
    return "__async__"
}

# ------------------------------------------------------------------------------
# Poll loop: reuses helpers from ::vmcp::runs (handlers/runs_common.tcl).
# The "done" condition branches on whether we're tracking impl or bitstream.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::impl::_poll {req_id} {
    variable active_polls

    if {![dict exists $active_polls $req_id]} return
    set ctx [dict get $active_polls $req_id]
    set client_id [dict get $ctx client_id]
    set run_name  [dict get $ctx run_name]
    set bitstream [dict get $ctx bitstream]

    if {[::vmcp::runs::client_gone $client_id]} {
        ::vmcp::log::log_info "poll $run_name: client $client_id disconnected"
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

    # "Done" differs for impl vs bitstream:
    # - impl_1 Complete means place_design/route_design finished
    # - `-to_step write_bitstream` sets status to "write_bitstream Complete!"
    set done 0
    if {$bitstream} {
        if {[string match -nocase "*write_bitstream*Complete*" $status] || \
            [string match -nocase "*Complete*" $status]} { set done 1 }
    } else {
        if {[string match -nocase "*route_design Complete*" $status] || \
            [string match -nocase "*impl*Complete*" $status] || \
            [string match -nocase "*Complete*" $status]} { set done 1 }
    }

    if {$done} {
        ::vmcp::log::log_info "run $run_name: Complete"
        set payload [::vmcp::handlers::impl::_final_payload $run_name $status $pct $bitstream]
        ::vmcp::protocol::send_result $client_id $req_id $payload
        dict unset active_polls $req_id
        set evt [expr {$bitstream ? "bitstream_complete" : "run_complete"}]
        ::vmcp::protocol::broadcast_notification $evt \
            [list run $run_name status $status]
        ::vmcp::dispatcher::release_async
        return
    }

    if {[::vmcp::runs::is_failed $status]} {
        ::vmcp::log::log_warn "run $run_name: Failed ($status)"
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_FAILED" "Implementation run failed" $status
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

    after 5000 [list ::vmcp::handlers::impl::_poll $req_id]
}

# ------------------------------------------------------------------------------
# Build the final payload for impl / bitstream.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::impl::_final_payload {run_name status pct is_bitstream} {
    set t [::vmcp::runs::timing_stats $run_name]
    set bitpath ""
    if {$is_bitstream} {
        catch {
            set run_dir [get_property DIRECTORY [get_runs $run_name]]
            set top     [get_property top [current_fileset]]
            set candidate [file join $run_dir "${top}.bit"]
            if {[file exists $candidate]} { set bitpath $candidate }
        }
    }
    set fields [list \
        run      $run_name \
        status   $status \
        progress [::vmcp::json::num $pct] \
        wns      [::vmcp::json::num_or_null [dict get $t wns]] \
        tns      [::vmcp::json::num_or_null [dict get $t tns]] \
        whs      [::vmcp::json::num_or_null [dict get $t whs]] \
        ths      [::vmcp::json::num_or_null [dict get $t ths]]]
    if {$is_bitstream} { lappend fields bitstream_path $bitpath }
    return [::vmcp::json::obj $fields]
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register run_implementation  ::vmcp::handlers::impl::run
::vmcp::dispatcher::register generate_bitstream  ::vmcp::handlers::impl::bitstream
