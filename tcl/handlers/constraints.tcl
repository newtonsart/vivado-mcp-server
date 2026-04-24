# ==============================================================================
# vivado-mcp-socket :: handlers/constraints.tcl
# ------------------------------------------------------------------------------
# Timing constraint setters. All operate on the current in-memory design — run
# write_xdc afterwards to persist to an .xdc file.
#
#   - create_clock
#   - create_generated_clock
#   - set_input_delay / set_output_delay
#   - set_false_path / set_multicycle_path / set_clock_groups
#   - report_exceptions
# ==============================================================================

namespace eval ::vmcp::handlers::constraints {}

# ------------------------------------------------------------------------------
# Helper: require a design (synth or impl) to be open.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::_require_design {client_id req_id} {
    if {[catch {current_design} cd] || $cd eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_DESIGN" "No design open. Run synthesis or open_run first."
        return 0
    }
    return 1
}

# ------------------------------------------------------------------------------
# create_clock
# params:
#   port     (string, required)  — port or pin name
#   period   (double, required)  — period in ns
#   name     (string, optional)
#   waveform (list  , optional)  — e.g. {0 5} for 50% duty 10ns
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::create_clock {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    foreach k {port period} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set port   [dict get $params port]
    set period [dict get $params period]
    set name ""
    if {[dict exists $params name]} { set name [dict get $params name] }
    set wave ""
    if {[dict exists $params waveform]} { set wave [dict get $params waveform] }

    set obj [get_ports -quiet $port]
    if {$obj eq ""} { set obj [get_pins -quiet $port] }
    if {$obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No port or pin matching '$port'"
        return
    }
    set cmd [list create_clock -period $period]
    if {$name ne ""} { lappend cmd -name $name }
    if {$wave ne ""} { lappend cmd -waveform $wave }
    lappend cmd $obj
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "create_clock failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            port   $port \
            period $period \
            name   $name]]
    return ok
}

# ------------------------------------------------------------------------------
# create_generated_clock
# params:
#   source     (string, required)
#   target     (string, required)
#   divide_by  (int   , optional)
#   multiply_by(int   , optional)
#   name       (string, optional)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::create_generated_clock {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    foreach k {source target} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set src [dict get $params source]
    set tgt [dict get $params target]
    set src_obj [get_pins -quiet $src]
    if {$src_obj eq ""} { set src_obj [get_ports -quiet $src] }
    set tgt_obj [get_pins -quiet $tgt]
    if {$tgt_obj eq ""} { set tgt_obj [get_ports -quiet $tgt] }
    if {$src_obj eq "" || $tgt_obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "source='$src' or target='$tgt' not found"
        return
    }
    set cmd [list create_generated_clock -source $src_obj]
    if {[dict exists $params divide_by]}   { lappend cmd -divide_by [dict get $params divide_by] }
    if {[dict exists $params multiply_by]} { lappend cmd -multiply_by [dict get $params multiply_by] }
    if {[dict exists $params name] && [dict get $params name] ne ""} {
        lappend cmd -name [dict get $params name]
    }
    lappend cmd $tgt_obj
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "create_generated_clock failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list source $src target $tgt]]
    return ok
}

# ------------------------------------------------------------------------------
# Helper for input/output delay.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::_io_delay {direction client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    foreach k {clock port delay} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set clk   [dict get $params clock]
    set port  [dict get $params port]
    set delay [dict get $params delay]
    set kind  "max"
    if {[dict exists $params kind]} {
        set v [string tolower [dict get $params kind]]
        if {$v eq "min" || $v eq "max" || $v eq "both"} { set kind $v }
    }
    set add 0
    if {[dict exists $params add] && [string is true -strict [dict get $params add]]} {
        set add 1
    }
    set clk_obj [get_clocks -quiet $clk]
    if {$clk_obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No clock named '$clk'"
        return
    }
    set port_obj [get_ports -quiet $port]
    if {$port_obj eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No port matching '$port'"
        return
    }
    if {$direction eq "input"} {
        set cmd [list set_input_delay -clock $clk_obj $delay]
    } else {
        set cmd [list set_output_delay -clock $clk_obj $delay]
    }
    switch -- $kind {
        min  { lappend cmd -min }
        max  { lappend cmd -max }
    }
    if {$add} { lappend cmd -add_delay }
    lappend cmd $port_obj
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "set_${direction}_delay failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            direction $direction \
            clock     $clk \
            port      $port \
            delay     $delay \
            kind      $kind]]
    return ok
}

proc ::vmcp::handlers::constraints::set_input_delay  {c r p} {
    ::vmcp::handlers::constraints::_io_delay input  $c $r $p
}
proc ::vmcp::handlers::constraints::set_output_delay {c r p} {
    ::vmcp::handlers::constraints::_io_delay output $c $r $p
}

# ------------------------------------------------------------------------------
# set_false_path
# params: from (string, optional), to (string, optional), through (string, optional)
# At least one of from/to/through required.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::set_false_path {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    set cmd [list set_false_path]
    set any 0
    foreach k {from to through} {
        if {[dict exists $params $k]} {
            set v [dict get $params $k]
            if {$v ne ""} {
                lappend cmd -$k $v
                incr any
            }
        }
    }
    if {!$any} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "At least one of from/to/through required"
        return
    }
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "set_false_path failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list applied [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# set_multicycle_path
# params:
#   cycles (int, required)
#   from/to/through (string, optional; at least one)
#   kind   (setup|hold, optional, default setup)
#   start  (bool, optional)
#   end    (bool, optional)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::set_multicycle_path {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    if {![dict exists $params cycles]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'cycles' parameter"
        return
    }
    set cycles [dict get $params cycles]
    set kind "setup"
    if {[dict exists $params kind]} {
        set v [string tolower [dict get $params kind]]
        if {$v eq "hold"} { set kind "hold" }
    }
    set cmd [list set_multicycle_path]
    switch -- $kind {
        setup { lappend cmd -setup }
        hold  { lappend cmd -hold  }
    }
    if {[dict exists $params start] && [string is true -strict [dict get $params start]]} {
        lappend cmd -start
    }
    if {[dict exists $params end] && [string is true -strict [dict get $params end]]} {
        lappend cmd -end
    }
    lappend cmd $cycles
    set any 0
    foreach k {from to through} {
        if {[dict exists $params $k]} {
            set v [dict get $params $k]
            if {$v ne ""} { lappend cmd -$k $v; incr any }
        }
    }
    if {!$any} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "At least one of from/to/through required"
        return
    }
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "set_multicycle_path failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list cycles $cycles kind $kind applied [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# set_clock_groups
# params:
#   groups (list of lists, required) — e.g. {{clk_a} {clk_b clk_c}}
#   mode   (string, optional, default "asynchronous") — asynchronous | exclusive
#   name   (string, optional)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::set_clock_groups {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    if {![dict exists $params groups]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'groups' parameter"
        return
    }
    set groups [dict get $params groups]
    set mode "asynchronous"
    if {[dict exists $params mode]} {
        set v [string tolower [dict get $params mode]]
        if {$v eq "exclusive"} { set mode "exclusive" }
    }
    set cmd [list set_clock_groups -${mode}]
    if {[dict exists $params name] && [dict get $params name] ne ""} {
        lappend cmd -name [dict get $params name]
    }
    foreach g $groups {
        # $g is a list of clock names; expand so get_clocks sees each as a
        # separate pattern arg, not a single combined pattern string.
        lappend cmd -group [get_clocks -quiet {*}$g]
    }
    if {[catch {eval $cmd} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "CONSTRAINT_FAILED" "set_clock_groups failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list mode $mode groups [llength $groups] applied [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# report_exceptions — report_exceptions -return_string (may be large).
# params:
#   path (string, optional) — write to file if given
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::constraints::report_exceptions {client_id req_id params} {
    if {![::vmcp::handlers::constraints::_require_design $client_id $req_id]} return
    if {[catch {report_exceptions -return_string} report opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "REPORT_FAILED" "report_exceptions failed: $report" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::handlers::reports::_emit_report $client_id $req_id $params $report
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register create_clock            ::vmcp::handlers::constraints::create_clock
::vmcp::dispatcher::register create_generated_clock  ::vmcp::handlers::constraints::create_generated_clock
::vmcp::dispatcher::register set_input_delay         ::vmcp::handlers::constraints::set_input_delay
::vmcp::dispatcher::register set_output_delay        ::vmcp::handlers::constraints::set_output_delay
::vmcp::dispatcher::register set_false_path          ::vmcp::handlers::constraints::set_false_path
::vmcp::dispatcher::register set_multicycle_path     ::vmcp::handlers::constraints::set_multicycle_path
::vmcp::dispatcher::register set_clock_groups        ::vmcp::handlers::constraints::set_clock_groups
::vmcp::dispatcher::register report_exceptions       ::vmcp::handlers::constraints::report_exceptions
