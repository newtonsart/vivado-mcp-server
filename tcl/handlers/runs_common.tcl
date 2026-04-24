# ==============================================================================
# vivado-mcp-socket :: handlers/runs_common.tcl
# ------------------------------------------------------------------------------
# Shared helpers for the run-polling handlers (synthesis, implementation,
# bitstream). Extracts the pieces that used to be duplicated between
# synthesis::_poll and impl::_poll.
# ==============================================================================

namespace eval ::vmcp::runs {}

# ------------------------------------------------------------------------------
# Parse a PROGRESS value (e.g. "15%" or "15") into an integer 0..100.
# ------------------------------------------------------------------------------
proc ::vmcp::runs::percent {raw} {
    set clean [regsub -all {%} $raw ""]
    set clean [string trim $clean]
    if {[string is integer -strict $clean]} { return $clean }
    if {[string is double  -strict $clean]} { return [expr {int($clean)}] }
    return 0
}

# ------------------------------------------------------------------------------
# Run STATUS is considered a failure if it contains "Error" or "Failed".
# ------------------------------------------------------------------------------
proc ::vmcp::runs::is_failed {status} {
    return [expr {[string match -nocase "*Error*"  $status] || \
                  [string match -nocase "*Failed*" $status]}]
}

# ------------------------------------------------------------------------------
# Whether the client that launched the poll has disconnected.
# ------------------------------------------------------------------------------
proc ::vmcp::runs::client_gone {client_id} {
    return [expr {[::vmcp::core::get_channel $client_id] eq ""}]
}

# ------------------------------------------------------------------------------
# Read {STATUS percent} for a run. On failure, emits send_error and returns
# an empty string; callers should treat "" as terminal (dict unset + release).
# ------------------------------------------------------------------------------
proc ::vmcp::runs::read_state {client_id req_id run_name} {
    if {[catch {get_property STATUS [get_runs $run_name]} status]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "POLL_FAILED" "Cannot read run STATUS: $status"
        return ""
    }
    set prog 0
    catch { set prog [get_property PROGRESS [get_runs $run_name]] }
    return [list $status [::vmcp::runs::percent $prog]]
}

# ------------------------------------------------------------------------------
# Emit a progress event only if the percent changed since the last emission.
# Returns the value to store as the new last_pct.
# ------------------------------------------------------------------------------
proc ::vmcp::runs::maybe_emit_progress {client_id req_id status pct last_pct} {
    if {$pct != $last_pct} {
        ::vmcp::protocol::send_progress $client_id $req_id $pct $status
        return $pct
    }
    return $last_pct
}

# ------------------------------------------------------------------------------
# Read cached timing stats from a run as a dict {wns .. tns .. whs .. ths ..}.
# Missing values are empty strings.
# ------------------------------------------------------------------------------
proc ::vmcp::runs::timing_stats {run_name} {
    set out [dict create wns "" tns "" whs "" ths ""]
    catch { dict set out wns [get_property STATS.WNS [get_runs $run_name]] }
    catch { dict set out tns [get_property STATS.TNS [get_runs $run_name]] }
    catch { dict set out whs [get_property STATS.WHS [get_runs $run_name]] }
    catch { dict set out ths [get_property STATS.THS [get_runs $run_name]] }
    return $out
}
