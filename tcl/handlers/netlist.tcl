# ==============================================================================
# vivado-mcp-socket :: handlers/netlist.tcl
# ------------------------------------------------------------------------------
# Netlist / elaborated design queries:
#   - get_cells
#   - get_nets
#   - get_ports
#   - get_clocks
#   - get_design_hierarchy
# ==============================================================================

namespace eval ::vmcp::handlers::netlist {}

# ------------------------------------------------------------------------------
# Helper: require an open design.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::_require_design {client_id req_id} {
    if {[catch {current_design} cd] || $cd eq ""} {
        # Try opening synth_1.
        if {[catch {open_run synth_1} err]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "NO_DESIGN" "No design open (open_run synth_1 failed: $err)"
            return 0
        }
    }
    return 1
}

# ------------------------------------------------------------------------------
# get_cells
# params:
#   pattern      (string, optional, default "*")
#   hierarchical (bool,   optional, default false)
#   limit        (int,    optional, default 200)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::cells {client_id req_id params} {
    if {![::vmcp::handlers::netlist::_require_design $client_id $req_id]} return

    set pattern [expr {[dict exists $params pattern]      ? [dict get $params pattern]      : "*"}]
    set hier    [expr {[dict exists $params hierarchical] ? [dict get $params hierarchical] : 0}]
    set limit   [expr {[dict exists $params limit]        ? [dict get $params limit]        : 200}]

    set cmd [list get_cells]
    if {$hier} { lappend cmd -hierarchical }
    lappend cmd $pattern

    if {[catch {eval $cmd} cells opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "QUERY_FAILED" "get_cells failed: $cells" \
            [dict get $opts -errorinfo]
        return
    }

    set out [list]
    set n 0
    foreach c $cells {
        if {$n >= $limit} break
        set name [get_property NAME $c]
        set ref  ""
        catch { set ref [get_property REF_NAME $c] }
        lappend out [::vmcp::json::obj [list \
            name $name \
            ref  $ref]]
        incr n
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            pattern  $pattern \
            total    [::vmcp::json::num [llength $cells]] \
            returned [::vmcp::json::num [llength $out]] \
            cells    [::vmcp::json::arr $out]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_nets
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::nets {client_id req_id params} {
    if {![::vmcp::handlers::netlist::_require_design $client_id $req_id]} return

    set pattern [expr {[dict exists $params pattern]      ? [dict get $params pattern]      : "*"}]
    set hier    [expr {[dict exists $params hierarchical] ? [dict get $params hierarchical] : 0}]
    set limit   [expr {[dict exists $params limit]        ? [dict get $params limit]        : 200}]

    set cmd [list get_nets]
    if {$hier} { lappend cmd -hierarchical }
    lappend cmd $pattern

    if {[catch {eval $cmd} nets opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "QUERY_FAILED" "get_nets failed: $nets" \
            [dict get $opts -errorinfo]
        return
    }

    set out [list]
    set n 0
    foreach nt $nets {
        if {$n >= $limit} break
        set name [get_property NAME $nt]
        set type ""
        catch { set type [get_property TYPE $nt] }
        lappend out [::vmcp::json::obj [list name $name type $type]]
        incr n
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            pattern  $pattern \
            total    [::vmcp::json::num [llength $nets]] \
            returned [::vmcp::json::num [llength $out]] \
            nets     [::vmcp::json::arr $out]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_ports
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::ports {client_id req_id params} {
    if {![::vmcp::handlers::netlist::_require_design $client_id $req_id]} return

    set pattern [expr {[dict exists $params pattern] ? [dict get $params pattern] : "*"}]
    if {[catch {get_ports $pattern} ports opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "QUERY_FAILED" "get_ports failed: $ports" \
            [dict get $opts -errorinfo]
        return
    }

    set out [list]
    foreach p $ports {
        set name  [get_property NAME $p]
        set dir   ""
        set pkg   ""
        set iostd ""
        catch { set dir   [get_property -quiet DIRECTION   $p] }
        catch { set pkg   [get_property -quiet PACKAGE_PIN $p] }
        catch { set iostd [get_property -quiet IOSTANDARD  $p] }
        lappend out [::vmcp::json::obj [list \
            name        $name \
            direction   $dir \
            package_pin $pkg \
            iostandard  $iostd]]
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            pattern $pattern \
            ports   [::vmcp::json::arr $out]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_clocks
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::clocks {client_id req_id params} {
    if {![::vmcp::handlers::netlist::_require_design $client_id $req_id]} return

    if {[catch {get_clocks} clocks opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "QUERY_FAILED" "get_clocks failed: $clocks" \
            [dict get $opts -errorinfo]
        return
    }

    set out [list]
    foreach c $clocks {
        set name     [get_property NAME $c]
        set period   ""
        set source   ""
        set waveform ""
        catch { set period   [get_property -quiet PERIOD   $c] }
        catch { set source   [get_property -quiet SOURCE   $c] }
        catch { set waveform [get_property -quiet WAVEFORM $c] }
        lappend out [::vmcp::json::obj [list \
            name     $name \
            period   $period \
            source   $source \
            waveform $waveform]]
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list clocks [::vmcp::json::arr $out]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_design_hierarchy — hierarchical tree from the top module.
# params:
#   max_depth (int, default 5)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::netlist::hierarchy {client_id req_id params} {
    if {![::vmcp::handlers::netlist::_require_design $client_id $req_id]} return

    set max_depth [expr {[dict exists $params max_depth] ? [dict get $params max_depth] : 5}]

    set top_cell ""
    catch {
        set top [get_property top [current_fileset]]
        set top_cell $top
    }

    set nodes [list]
    if {[catch {get_cells -hierarchical} all opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "QUERY_FAILED" "get_cells -hierarchical failed: $all" \
            [dict get $opts -errorinfo]
        return
    }

    foreach c $all {
        set name  $c
        set depth [llength [split $name "/"]]
        if {$depth > $max_depth} continue
        set ref ""
        catch { set ref [get_property REF_NAME $c] }
        lappend nodes [::vmcp::json::obj [list \
            name  $name \
            ref   $ref \
            depth [::vmcp::json::num $depth]]]
    }

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            top       $top_cell \
            max_depth [::vmcp::json::num $max_depth] \
            total     [::vmcp::json::num [llength $nodes]] \
            nodes     [::vmcp::json::arr $nodes]]]
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register get_cells              ::vmcp::handlers::netlist::cells
::vmcp::dispatcher::register get_nets               ::vmcp::handlers::netlist::nets
::vmcp::dispatcher::register get_ports              ::vmcp::handlers::netlist::ports
::vmcp::dispatcher::register get_clocks             ::vmcp::handlers::netlist::clocks
::vmcp::dispatcher::register get_design_hierarchy   ::vmcp::handlers::netlist::hierarchy
