# ==============================================================================
# vivado-mcp-socket :: handlers/reports.tcl
# ------------------------------------------------------------------------------
# Vivado report handlers. All synchronous (may take seconds, but not minutes):
#   - get_timing_summary
#   - get_timing_paths
#   - get_utilization
#   - get_messages
#   - get_drc
# ==============================================================================

namespace eval ::vmcp::handlers::reports {}

# ------------------------------------------------------------------------------
# Helper: verify that a project is open.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::_require_project {client_id req_id} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return 0
    }
    return 1
}

# ------------------------------------------------------------------------------
# Helper: open the implemented or synthesized design if none is currently open.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::_ensure_design_open {prefer} {
    # prefer: "impl" or "synth"
    if {[catch {current_design} cd] == 0 && $cd ne ""} {
        return 1
    }
    if {$prefer eq "impl"} {
        if {[catch {open_run impl_1} err]} {
            if {[catch {open_run synth_1} err2]} { return 0 }
        }
    } else {
        if {[catch {open_run synth_1} err]} { return 0 }
    }
    return 1
}

# ------------------------------------------------------------------------------
# Helper: emit a potentially large report. If params has non-empty `path`,
# write full report to disk and return {path, size_bytes, head}. Otherwise
# return {report} inline (caller must ensure line fits socket buffer).
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::_emit_report {client_id req_id params report} {
    set path ""
    if {[dict exists $params path]} { set path [dict get $params path] }
    if {$path ne ""} {
        if {[catch {
            set fh [open $path w]
            fconfigure $fh -translation lf -encoding utf-8
            puts -nonewline $fh $report
            close $fh
        } err]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "FILE_WRITE" "Could not write report to $path: $err"
            return
        }
        set head [string range $report 0 1999]
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::json::obj [list \
                path       $path \
                size_bytes [::vmcp::json::num [string length $report]] \
                head       $head]]
    } else {
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::json::obj [list report $report]]
    }
}

# ------------------------------------------------------------------------------
# get_timing_summary
# params:
#   run (string, optional, default "impl_1")
#   max_paths (int, optional, default 10)
#
# FAST PATH: reads STATS.WNS/TNS/WHS/THS cached on the run object.
#   Does not require open_run or report_timing_summary — returns in <1 s.
#   STATS.* values are computed when launch_runs finishes and persist.
#
# SLOW PATH (fallback): if STATS are unavailable, opens the design and
#   generates report_timing_summary. Only reached when the run has no cached
#   statistics (e.g. very old run or in-memory design).
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::timing_summary {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return

    set run_name  [expr {[dict exists $params run]       ? [dict get $params run]       : "impl_1"}]
    set max_paths [expr {[dict exists $params max_paths] ? [dict get $params max_paths] : 10}]

    # --- FAST PATH: cached run properties (instantaneous, no open_run) --------
    set wns   ""
    set tns   ""
    set whs   ""
    set ths   ""
    set fails ""
    catch { set wns   [get_property -quiet STATS.WNS          [get_runs $run_name]] }
    catch { set tns   [get_property -quiet STATS.TNS          [get_runs $run_name]] }
    catch { set whs   [get_property -quiet STATS.WHS          [get_runs $run_name]] }
    catch { set ths   [get_property -quiet STATS.THS          [get_runs $run_name]] }
    catch { set fails [get_property -quiet STATS.FAILED_NETS  [get_runs $run_name]] }

    if {$wns ne "" || $tns ne ""} {
        # Cached data available — fast response.
        set note "(cached run statistics; use run_tcl with report_timing_summary for the full report)"
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::json::obj [list \
                run         $run_name \
                wns         $wns \
                tns         $tns \
                whs         $whs \
                ths         $ths \
                failed_nets $fails \
                report      $note]]
        return ok
    }

    # --- SLOW PATH: open design and generate full report ----------------------
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open and could not open $run_name"
        return
    }

    set report ""
    if {[catch {report_timing_summary -return_string -max_paths $max_paths} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_timing_summary failed: $report" \
            [dict get $opts -errorinfo]
        return
    }

    # Extract WNS/TNS/WHS/THS from the report text.
    catch {
        regexp -line {WNS\(ns\)\s*:?\s*(-?[0-9.]+)} $report _ wns
        regexp -line {TNS\(ns\)\s*:?\s*(-?[0-9.]+)} $report _ tns
        regexp -line {WHS\(ns\)\s*:?\s*(-?[0-9.]+)} $report _ whs
        regexp -line {THS\(ns\)\s*:?\s*(-?[0-9.]+)} $report _ ths
    }

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            run         $run_name \
            wns         $wns \
            tns         $tns \
            whs         $whs \
            ths         $ths \
            failed_nets $fails \
            report      $report]]
    return ok
}

# ------------------------------------------------------------------------------
# get_timing_paths
# params:
#   max_paths (int, default 10)
#   delay_type (string, default "max")  — "max", "min", "min_max"
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::timing_paths {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    set max_paths [expr {[dict exists $params max_paths]  ? [dict get $params max_paths]  : 10}]
    set delay_type [expr {[dict exists $params delay_type] ? [dict get $params delay_type] : "max"}]

    if {[catch {
        set paths [get_timing_paths -max_paths $max_paths -delay_type $delay_type]
    } err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "get_timing_paths failed: $err" \
            [dict get $opts -errorinfo]
        return
    }

    set out [list]
    foreach p $paths {
        set slack ""
        set from ""
        set to ""
        set group ""
        catch { set slack [get_property SLACK $p] }
        catch { set from  [get_property STARTPOINT_PIN $p] }
        catch { set to    [get_property ENDPOINT_PIN $p] }
        catch { set group [get_property GROUP $p] }
        lappend out [::vmcp::json::obj [list \
            slack $slack \
            from  $from \
            to    $to \
            group $group]]
    }

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list paths [::vmcp::json::arr $out]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_utilization
#
# FAST PATH: reads STATS.SLICE_LUTS, STATS.REGISTERS, STATS.RAMB36, etc.
#   cached on the run object (instantaneous, no open_run required).
#
# SLOW PATH: report_utilization -return_string (can take >60 s on large
#   designs — only used when the fast path yields no data).
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::utilization {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return

    set run_name [expr {[dict exists $params run] ? [dict get $params run] : "impl_1"}]

    # --- FAST PATH: cached STATS from the run object (no open_run needed) -----
    # Vivado stores the main resource counts in STATS.* properties of the run.
    # Property names vary by device family (DSP48E1 vs DSP48E2, RAMB36 vs
    # RAMB36E1, etc.), so we try variants with -quiet to suppress warnings.
    set luts      ""
    set regs      ""
    set bram      ""
    set dsp       ""
    set io        ""
    catch { set luts [get_property -quiet STATS.SLICE_LUTS   [get_runs $run_name]] }
    catch { set regs [get_property -quiet STATS.REGISTERS    [get_runs $run_name]] }
    foreach prop {STATS.RAMB36 STATS.RAMB36E1 STATS.RAMB18} {
        catch { set bram [get_property -quiet $prop [get_runs $run_name]] }
        if {$bram ne ""} break
    }
    foreach prop {STATS.DSP48E2 STATS.DSP48E1 STATS.DSP48} {
        catch { set dsp [get_property -quiet $prop [get_runs $run_name]] }
        if {$dsp ne ""} break
    }
    catch { set io   [get_property -quiet STATS.BONDED_IOB   [get_runs $run_name]] }

    if {$luts ne "" || $regs ne ""} {
        # Build a minimal summary from the cached values.
        set summary [list]
        foreach {label val} [list \
            "Slice LUTs"  $luts \
            "Registers"   $regs \
            "RAMB36"      $bram \
            "DSP48"       $dsp  \
            "Bonded IOBs" $io   \
        ] {
            if {$val ne ""} {
                lappend summary [::vmcp::json::obj [list \
                    name $label \
                    used [::vmcp::json::num $val]]]
            }
        }
        set note "(cached run statistics — no percentages; use run_tcl with report_utilization for the full report)"
        ::vmcp::protocol::send_result $client_id $req_id \
            [::vmcp::json::obj [list \
                summary [::vmcp::json::arr $summary] \
                report  $note]]
        return ok
    }

    # --- SLOW PATH: open design and generate full report ----------------------
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }

    if {[catch {report_utilization -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_utilization failed: $report" \
            [dict get $opts -errorinfo]
        return
    }

    # Heuristic parse of the utilization table.
    # Vivado 2023.2+ has 6 columns: | Site Type | Used | Fixed | Prohibited | Available | Util% |
    # Older versions have 5 columns: | Site Type | Used | Fixed | Available | Util% |
    # We try the 6-column format first, then fall back to 5-column.
    set summary [list]
    foreach line [split $report "\n"] {
        if {[regexp {^\|\s*([A-Za-z0-9 _.\-]+?)\s*\|\s*([0-9]+)\s*\|\s*[0-9]+\s*\|\s*[0-9]+\s*\|\s*([0-9]+)\s*\|\s*([0-9.]+)} $line _ name used avail pct] ||
            [regexp {^\|\s*([A-Za-z0-9 _.\-]+?)\s*\|\s*([0-9]+)\s*\|\s*[0-9]+\s*\|\s*([0-9]+)\s*\|\s*([0-9.]+)} $line _ name used avail pct]} {
            lappend summary [::vmcp::json::obj [list \
                name      [string trim $name] \
                used      [::vmcp::json::num $used] \
                available [::vmcp::json::num $avail] \
                percent   [::vmcp::json::num $pct]]]
        }
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            summary [::vmcp::json::arr $summary] \
            report  $report]]
    return ok
}

# ------------------------------------------------------------------------------
# get_messages
# params:
#   severity (string, default "ERROR")  — ERROR, WARNING, CRITICAL WARNING, INFO
#   limit    (int, default 100)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::messages {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return

    set severity [expr {[dict exists $params severity] ? [dict get $params severity] : "ERROR"}]
    set limit    [expr {[dict exists $params limit]    ? [dict get $params limit]    : 100}]

    if {[catch {get_msg_config -severity $severity -count} count]} {
        set count 0
    }

    set msgs [list]
    # get_messages returns strings, typically formatted "ID-NN msg...".
    # Modern Vivado has `get_messages -severity`, but iterating the on-disk
    # buffer is safe as a fallback.
    if {[catch {
        set all [get_messages -severity $severity]
    } all]} {
        set all [list]
    }
    set n 0
    foreach m $all {
        if {$n >= $limit} break
        lappend msgs $m
        incr n
    }
    set json_msgs [list]
    foreach m $msgs { lappend json_msgs $m }

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            severity $severity \
            count    [::vmcp::json::num $count] \
            returned [::vmcp::json::num [llength $msgs]] \
            messages [::vmcp::json::arr $json_msgs]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_drc — design rule check.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::drc {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    if {[catch {report_drc -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_drc failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# get_power_report — report_power -return_string
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::power_report {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    if {[catch {report_power -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_power failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# get_cdc_report — report_cdc -return_string
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::cdc_report {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    if {[catch {report_cdc -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_cdc failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# get_methodology_violations — report_methodology -return_string
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::methodology_report {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    if {[catch {report_methodology -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_methodology failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# get_io_report — report_io -return_string
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::io_report {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    if {[catch {report_io -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_io failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# get_fanout_report — report_high_fanout_nets -return_string
# params:
#   max_nets (int, optional, default 20)
#   path     (string, optional) — if set, dump full report to file
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::reports::fanout_report {client_id req_id params} {
    if {![::vmcp::handlers::reports::_require_project $client_id $req_id]} return
    if {![::vmcp::handlers::reports::_ensure_design_open "impl"]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open"
        return
    }
    set max_nets 20
    if {[dict exists $params max_nets]} {
        set v [dict get $params max_nets]
        if {[string is integer -strict $v] && $v > 0} { set max_nets $v }
    }
    if {[catch {report_high_fanout_nets -max_nets $max_nets -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_high_fanout_nets failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register get_timing_summary       ::vmcp::handlers::reports::timing_summary
::vmcp::dispatcher::register get_timing_paths         ::vmcp::handlers::reports::timing_paths
::vmcp::dispatcher::register get_utilization          ::vmcp::handlers::reports::utilization
::vmcp::dispatcher::register get_messages             ::vmcp::handlers::reports::messages
::vmcp::dispatcher::register get_drc                  ::vmcp::handlers::reports::drc
::vmcp::dispatcher::register get_power_report         ::vmcp::handlers::reports::power_report
::vmcp::dispatcher::register get_cdc_report           ::vmcp::handlers::reports::cdc_report
::vmcp::dispatcher::register get_methodology_violations ::vmcp::handlers::reports::methodology_report
::vmcp::dispatcher::register get_io_report            ::vmcp::handlers::reports::io_report
::vmcp::dispatcher::register get_fanout_report        ::vmcp::handlers::reports::fanout_report
