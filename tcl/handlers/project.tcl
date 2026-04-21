# ==============================================================================
# vivado-mcp-socket :: handlers/project.tcl
# ------------------------------------------------------------------------------
# Handlers for Vivado project management:
#   - open_project       open a .xpr file
#   - close_project      close the active project
#   - get_project_info   return name, part, runs, top module, ...
# ==============================================================================

namespace eval ::vmcp::handlers::project {}

# ------------------------------------------------------------------------------
# open_project
# params:
#   path      (string, required) — path to the .xpr file
#   read_only (bool, optional, default false)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::project::open {client_id req_id params} {
    if {![dict exists $params path]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'path' parameter"
        return
    }
    set path [dict get $params path]
    set read_only 0
    if {[dict exists $params read_only]} {
        set v [dict get $params read_only]
        if {[string is true -strict $v]} { set read_only 1 }
    }

    if {![file exists $path]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "FILE_NOT_FOUND" "Project file not found: $path"
        return
    }

    # Close any currently open project to avoid warnings.
    catch {close_project -quiet}

    set cmd [list open_project $path]
    if {$read_only} { lappend cmd -read_only }

    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "VIVADO_ERROR" "open_project failed: $err" \
            [dict get $opts -errorinfo]
        return
    }

    # Collect info about the newly opened project.
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::handlers::project::_gather_info]
    return ok
}

# ------------------------------------------------------------------------------
# close_project
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::project::close {client_id req_id params} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project to close"
        return
    }
    if {[catch {close_project} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "VIVADO_ERROR" "close_project failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [list closed [::vmcp::json::bool 1]]
    return ok
}

# ------------------------------------------------------------------------------
# get_project_info
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::project::info {client_id req_id params} {
    if {[catch {current_project} cp]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_PROJECT" "No open project"
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::handlers::project::_gather_info]
    return ok
}

# ------------------------------------------------------------------------------
# Collect information from the active project and return pre-formatted JSON.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::project::_gather_info {} {
    set name   ""
    set part   ""
    set dir    ""
    set xpr    ""
    set top    ""
    set runs   [list]

    catch {
        set name [get_property NAME [current_project]]
        set part [get_property PART [current_project]]
        set dir  [get_property DIRECTORY [current_project]]
        set xpr  [get_property XPR_FILE [current_project]]
    }
    # Top module from the sources_1 fileset.
    catch {
        set top [get_property top [current_fileset]]
    }
    # Available runs (synth_*, impl_*).
    catch {
        foreach r [get_runs] {
            set r_name   [get_property NAME $r]
            set r_status [get_property STATUS $r]
            set r_progress 0
            catch { set r_progress [get_property PROGRESS $r] }
            # Vivado reports PROGRESS as "NN%" — strip the symbol.
            set r_progress [regsub -all {%} $r_progress ""]
            if {![string is integer -strict $r_progress]} { set r_progress 0 }
            lappend runs [::vmcp::json::obj [list \
                name     $r_name \
                status   $r_status \
                progress [::vmcp::json::num $r_progress]]]
        }
    }
    set runs_json [::vmcp::json::arr $runs]

    return [::vmcp::json::obj [list \
        name      $name \
        part      $part \
        directory $dir \
        xpr_file  $xpr \
        top       $top \
        runs      $runs_json]]
}

# ------------------------------------------------------------------------------
# Register with the dispatcher.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register open_project       ::vmcp::handlers::project::open
::vmcp::dispatcher::register close_project      ::vmcp::handlers::project::close
::vmcp::dispatcher::register get_project_info   ::vmcp::handlers::project::info
