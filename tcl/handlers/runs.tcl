# ==============================================================================
# vivado-mcp-socket :: handlers/runs.tcl
# ------------------------------------------------------------------------------
# Run management / timing-closure helpers.
#
#   - list_strategies   list available synthesis or implementation strategies
#   - set_run_strategy  set_property strategy on a run (reset first if needed)
#   - get_run_stats     strategy + status + WNS/TNS/WHS/THS + wall time
#   - wait_on_run       blocking wait_on_run with timeout
# ==============================================================================

namespace eval ::vmcp::handlers::runs {}

# ------------------------------------------------------------------------------
# list_strategies
# params:
#   flow (string, optional, default "impl") — "synth" or "impl"
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::runs::list_strategies {client_id req_id params} {
    set flow "impl"
    if {[dict exists $params flow]} {
        set v [string tolower [dict get $params flow]]
        if {$v eq "synth" || $v eq "synthesis"} { set flow "synth" }
    }
    set run [expr {$flow eq "synth" ? "synth_1" : "impl_1"}]
    set strategies [list]
    # Query from a real run of that flow (robust across versions).
    if {[catch {get_runs $run} _err] == 0} {
        catch {set strategies [list_property_value strategy [get_runs $run]]}
    }
    # Fallback: common Xilinx-shipped strategy names.
    if {[llength $strategies] == 0} {
        if {$flow eq "synth"} {
            set strategies [list \
                "Vivado Synthesis Defaults" \
                "Flow_AreaOptimized_high" \
                "Flow_AreaOptimized_medium" \
                "Flow_AlternateRoutability" \
                "Flow_PerfOptimized_high" \
                "Flow_PerfThresholdCarry" \
                "Flow_RuntimeOptimized"]
        } else {
            set strategies [list \
                "Vivado Implementation Defaults" \
                "Performance_Explore" \
                "Performance_ExplorePostRoutePhysOpt" \
                "Performance_WLBlockPlacement" \
                "Performance_NetDelay_high" \
                "Performance_Retiming" \
                "Performance_ExtraTimingOpt" \
                "Congestion_SpreadLogic_high" \
                "Congestion_SSI_SpreadLogic_high" \
                "Area_Explore" \
                "Power_DefaultOpt" \
                "Flow_RunPhysOpt" \
                "Flow_RuntimeOptimized"]
        }
    }
    set json [list]
    foreach s $strategies { lappend json $s }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            flow       $flow \
            strategies [::vmcp::json::arr $json] \
            count      [::vmcp::json::num [llength $strategies]]]]
    return ok
}

# ------------------------------------------------------------------------------
# set_run_strategy
# params:
#   run      (string, required) — e.g. "impl_1" / "synth_1"
#   strategy (string, required)
#   reset    (bool  , optional, default true) — reset run if not already queued
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::runs::set_strategy {client_id req_id params} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }
    foreach k {run strategy} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set run      [dict get $params run]
    set strategy [dict get $params strategy]
    set do_reset 1
    if {[dict exists $params reset] && \
        ![string is true -strict [dict get $params reset]]} {
        set do_reset 0
    }
    set run_obj [get_runs -quiet $run]
    if {$run_obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run' does not exist"
        return
    }
    if {$do_reset} {
        set status [get_property STATUS $run_obj]
        if {![string match -nocase "*Not started*" $status]} {
            catch {reset_run $run}
        }
    }
    if {[catch {set_property strategy $strategy $run_obj} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "VIVADO_ERROR" "set_property strategy failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            run      $run \
            strategy $strategy \
            reset    [::vmcp::json::bool $do_reset]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_run_stats — current strategy + status + STATS.* (WNS/TNS/WHS/THS).
# params:
#   run (string, optional, default "impl_1")
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::runs::stats {client_id req_id params} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }
    set run "impl_1"
    if {[dict exists $params run]} {
        set v [dict get $params run]
        if {$v ne ""} { set run $v }
    }
    set obj [get_runs -quiet $run]
    if {$obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run' does not exist"
        return
    }
    set status   [get_property STATUS $obj]
    set strategy ""
    catch {set strategy [get_property STRATEGY $obj]}
    set progress 0
    catch {set progress [get_property PROGRESS $obj]}
    if {[string match *%* $progress]} {
        regexp {([0-9]+)} $progress _ progress
    }
    set wns ""; set tns ""; set whs ""; set ths ""
    set wpws ""; set failed 0
    catch {set wns  [get_property STATS.WNS $obj]}
    catch {set tns  [get_property STATS.TNS $obj]}
    catch {set whs  [get_property STATS.WHS $obj]}
    catch {set ths  [get_property STATS.THS $obj]}
    catch {set wpws [get_property STATS.WPWS $obj]}
    catch {set failed [get_property STATS.FAILED_ROUTES $obj]}
    set elapsed ""
    catch {set elapsed [get_property STATS.ELAPSED $obj]}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            run      $run \
            status   $status \
            strategy $strategy \
            progress [::vmcp::json::num $progress] \
            wns      [::vmcp::json::num_or_null $wns] \
            tns      [::vmcp::json::num_or_null $tns] \
            whs      [::vmcp::json::num_or_null $whs] \
            ths      [::vmcp::json::num_or_null $ths] \
            wpws     [::vmcp::json::num_or_null $wpws] \
            failed_routes [::vmcp::json::num $failed] \
            elapsed  $elapsed]]
    return ok
}

# ------------------------------------------------------------------------------
# wait_on_run — blocking wait until run completes or timeout.
# params:
#   run     (string, optional, default "impl_1")
#   timeout (int   , optional, default 3600) — seconds
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::runs::wait {client_id req_id params} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }
    set run "impl_1"
    if {[dict exists $params run]} {
        set v [dict get $params run]
        if {$v ne ""} { set run $v }
    }
    set to 3600
    if {[dict exists $params timeout]} {
        set v [dict get $params timeout]
        if {[string is integer -strict $v] && $v > 0} { set to $v }
    }
    set obj [get_runs -quiet $run]
    if {$obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "RUN_NOT_FOUND" "Run '$run' does not exist"
        return
    }
    # wait_on_run accepts -timeout in minutes (not seconds); convert.
    set to_min [expr {($to + 59) / 60}]
    set ok 1
    if {[catch {wait_on_run -timeout $to_min $run} err]} {
        set ok 0
    }
    set status [get_property STATUS $obj]
    set wns ""; set tns ""
    catch {set wns [get_property STATS.WNS $obj]}
    catch {set tns [get_property STATS.TNS $obj]}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            run       $run \
            status    $status \
            wns       [::vmcp::json::num_or_null $wns] \
            tns       [::vmcp::json::num_or_null $tns] \
            completed [::vmcp::json::bool $ok]]]
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register list_strategies   ::vmcp::handlers::runs::list_strategies
::vmcp::dispatcher::register set_run_strategy  ::vmcp::handlers::runs::set_strategy
::vmcp::dispatcher::register get_run_stats     ::vmcp::handlers::runs::stats
::vmcp::dispatcher::register wait_on_run       ::vmcp::handlers::runs::wait
