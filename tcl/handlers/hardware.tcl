# ==============================================================================
# vivado-mcp-socket :: handlers/hardware.tcl
# ------------------------------------------------------------------------------
# JTAG / Hardware Manager handlers.
#
#   - connect_hw          open hw_manager, connect hw_server, open target
#   - disconnect_hw       teardown
#   - get_hw_info         server + targets + devices + ilas + vios summary
#   - program_device      set PROGRAM.FILE / PROBES.FILE, program_hw_devices
#   - list_hw_probes      list probes on an ILA/VIO core
#   - set_ila_trigger     set a single-probe compare value on an ILA
#   - arm_ila             configure data_depth/trigger_position + run_hw_ila
#   - wait_ila            wait_on_hw_ila (blocking with timeout)
#   - read_ila_data       upload_hw_ila_data + write_hw_ila_data (CSV/VCD)
#   - get_vio             refresh_hw_vio + read INPUT_VALUE of a probe
#   - set_vio             set OUTPUT_VALUE of a probe + commit_hw_vio
# ==============================================================================

namespace eval ::vmcp::handlers::hardware {}

# ------------------------------------------------------------------------------
# Helper: ensure hw_manager is open.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::_require_hw {client_id req_id} {
    if {[catch {current_hw_server} hs] || $hs eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_HW_SERVER" "No hw_server connected. Call connect_hw first."
        return 0
    }
    return 1
}

# ------------------------------------------------------------------------------
# connect_hw
# params:
#   server_url (string, optional, default "localhost:3121")
#   target     (string, optional) — substring match on target name
#   device     (string, optional) — substring match on device name
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::connect {client_id req_id params} {
    set url "localhost:3121"
    if {[dict exists $params server_url]} {
        set v [dict get $params server_url]
        if {$v ne ""} { set url $v }
    }
    # Only open hw_manager if no hw_server already connected. Avoids
    # a locale-dependent string match on the "already open" error.
    set hs ""
    catch { set hs [current_hw_server] }
    if {$hs eq ""} {
        if {[catch {open_hw_manager} err opts]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "HW_ERROR" "open_hw_manager failed: $err" \
                [dict get $opts -errorinfo]
            return
        }
    }
    # Disconnect stale server before reconnecting.
    catch {disconnect_hw_server}
    if {[catch {connect_hw_server -url $url} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "connect_hw_server failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    # Select hw_target.
    set targets [get_hw_targets]
    if {[llength $targets] == 0} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_HW_TARGET" "No hw_targets detected on $url"
        return
    }
    set tgt [lindex $targets 0]
    if {[dict exists $params target] && [dict get $params target] ne ""} {
        set want [dict get $params target]
        foreach t $targets {
            if {[string match -nocase "*$want*" $t]} { set tgt $t; break }
        }
    }
    if {[catch {current_hw_target $tgt} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "current_hw_target failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    catch {open_hw_target}
    # Select hw_device.
    set devices [get_hw_devices]
    set dev ""
    if {[llength $devices] > 0} {
        set dev [lindex $devices 0]
        if {[dict exists $params device] && [dict get $params device] ne ""} {
            set want [dict get $params device]
            foreach d $devices {
                if {[string match -nocase "*$want*" $d]} { set dev $d; break }
            }
        }
        catch {current_hw_device $dev}
    }
    set targets_json [list]
    foreach t $targets { lappend targets_json $t }
    set devices_json [list]
    foreach d $devices { lappend devices_json $d }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            server_url       $url \
            current_target   $tgt \
            current_device   $dev \
            targets          [::vmcp::json::arr $targets_json] \
            devices          [::vmcp::json::arr $devices_json]]]
    return ok
}

# ------------------------------------------------------------------------------
# disconnect_hw — best-effort teardown.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::disconnect {client_id req_id params} {
    catch {close_hw_target}
    catch {disconnect_hw_server}
    catch {close_hw_manager}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list disconnected [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_hw_info — full hw_manager inventory.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::info {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return

    set server [current_hw_server]
    set target ""
    catch {set target [current_hw_target]}
    set device ""
    catch {set device [current_hw_device]}

    set devices [list]
    catch {set devices [get_hw_devices]}
    set devices_json [list]
    foreach d $devices { lappend devices_json $d }

    set ilas [list]
    catch {set ilas [get_hw_ilas -quiet]}
    set ilas_json [list]
    foreach i $ilas {
        set dd 0
        set tpos 0
        set tmode ""
        catch {set dd   [get_property CONTROL.DATA_DEPTH $i]}
        catch {set tpos [get_property CONTROL.TRIGGER_POSITION $i]}
        catch {set tmode [get_property CONTROL.TRIGGER_MODE $i]}
        lappend ilas_json [::vmcp::json::obj [list \
            name              $i \
            data_depth        [::vmcp::json::num $dd] \
            trigger_position  [::vmcp::json::num $tpos] \
            trigger_mode      $tmode]]
    }

    set vios [list]
    catch {set vios [get_hw_vios -quiet]}
    set vios_json [list]
    foreach v $vios { lappend vios_json $v }

    set probes [list]
    catch {set probes [get_hw_probes -quiet]}
    set nprobes [llength $probes]

    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            server          $server \
            current_target  $target \
            current_device  $device \
            devices         [::vmcp::json::arr $devices_json] \
            ilas            [::vmcp::json::arr $ilas_json] \
            vios            [::vmcp::json::arr $vios_json] \
            probe_count     [::vmcp::json::num $nprobes]]]
    return ok
}

# ------------------------------------------------------------------------------
# program_device
# params:
#   bitstream (string, required) — absolute path to .bit
#   probes    (string, optional) — absolute path to .ltx
#   device    (string, optional) — substring match, default current
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::program {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    if {![dict exists $params bitstream]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'bitstream' parameter"
        return
    }
    set bit [dict get $params bitstream]
    if {![file exists $bit]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "FILE_NOT_FOUND" "bitstream not found: $bit"
        return
    }
    set probes ""
    if {[dict exists $params probes]} {
        set probes [dict get $params probes]
        if {$probes ne "" && ![file exists $probes]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "FILE_NOT_FOUND" "probes file not found: $probes"
            return
        }
    }
    set dev ""
    catch { set dev [current_hw_device] }
    if {[dict exists $params device] && [dict get $params device] ne ""} {
        set want [dict get $params device]
        foreach d [get_hw_devices] {
            if {[string match -nocase "*$want*" $d]} { set dev $d; break }
        }
        catch {current_hw_device $dev}
    }
    if {$dev eq ""} {
        # No device selected and none discoverable on this target.
        set all [list]
        catch { set all [get_hw_devices] }
        if {[llength $all] > 0} { set dev [lindex $all 0]; catch {current_hw_device $dev} }
    }
    if {$dev eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NO_HW_DEVICE" "No hw_device selected on current hw_target"
        return
    }
    if {[catch {set_property PROGRAM.FILE $bit $dev} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "set_property PROGRAM.FILE failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    if {$probes ne ""} {
        catch {set_property PROBES.FILE $probes $dev}
    }
    if {[catch {program_hw_devices $dev} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "program_hw_devices failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    catch {refresh_hw_device $dev}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            device     $dev \
            bitstream  $bit \
            probes     $probes \
            programmed [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# list_hw_probes — probes attached to an ILA or VIO core.
# params:
#   core (string, required) — ILA/VIO name (or substring)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::list_probes {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    if {![dict exists $params core]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'core' parameter"
        return
    }
    set want [dict get $params core]
    set all_cores [concat [get_hw_ilas -quiet] [get_hw_vios -quiet]]
    set core ""
    foreach c $all_cores {
        if {[string match -nocase "*$want*" $c]} { set core $c; break }
    }
    if {$core eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No ILA/VIO matching '$want'"
        return
    }
    set probes [get_hw_probes -of_objects $core]
    set json [list]
    foreach p $probes {
        set w 0
        set type ""
        catch {set w    [get_property WIDTH $p]}
        catch {set type [get_property TYPE  $p]}
        lappend json [::vmcp::json::obj [list \
            name  $p \
            width [::vmcp::json::num $w] \
            type  $type]]
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            core   $core \
            probes [::vmcp::json::arr $json]]]
    return ok
}

# ------------------------------------------------------------------------------
# set_ila_trigger — single-probe compare on an ILA.
# params:
#   ila      (string, required)  — ILA name substring
#   probe    (string, required)  — probe name substring
#   value    (string, required)  — compare value (radix-encoded)
#   operator (string, optional)  — default "==" ; also "!=", ">", "<", etc.
#   radix    (string, optional)  — BINARY|HEX|UNSIGNED|SIGNED (default BINARY)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::set_ila_trigger {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    foreach k {ila probe value} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set ila_want   [dict get $params ila]
    set probe_want [dict get $params probe]
    set value      [dict get $params value]
    set op "=="
    if {[dict exists $params operator]} {
        set v [dict get $params operator]
        if {$v ne ""} { set op $v }
    }
    set radix "BINARY"
    if {[dict exists $params radix]} {
        set v [dict get $params radix]
        if {$v ne ""} { set radix [string toupper $v] }
    }
    set ila ""
    foreach i [get_hw_ilas -quiet] {
        if {[string match -nocase "*$ila_want*" $i]} { set ila $i; break }
    }
    if {$ila eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No ILA matching '$ila_want'"
        return
    }
    set probe ""
    foreach p [get_hw_probes -of_objects $ila] {
        if {[string match -nocase "*$probe_want*" $p]} { set probe $p; break }
    }
    if {$probe eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No probe matching '$probe_want' on ILA $ila"
        return
    }
    if {[catch {
        set_property TRIGGER_COMPARE_VALUE "${op}${radix}_${value}" $probe
    } err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "set trigger value failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            ila      $ila \
            probe    $probe \
            operator $op \
            radix    $radix \
            value    $value]]
    return ok
}

# ------------------------------------------------------------------------------
# arm_ila — configure data depth / trigger position / mode, run_hw_ila.
# params:
#   ila              (string, required)
#   data_depth       (int, optional)    — leave current if omitted
#   trigger_position (int, optional)    — leave current if omitted
#   trigger_mode     (string, optional) — BASIC_ONLY, BASIC_OR_TRIG_IMMEDIATE, ...
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::arm_ila {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    if {![dict exists $params ila]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'ila' parameter"
        return
    }
    set want [dict get $params ila]
    set ila ""
    foreach i [get_hw_ilas -quiet] {
        if {[string match -nocase "*$want*" $i]} { set ila $i; break }
    }
    if {$ila eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No ILA matching '$want'"
        return
    }
    if {[dict exists $params data_depth]} {
        set dd [dict get $params data_depth]
        catch {set_property CONTROL.DATA_DEPTH $dd $ila}
    }
    if {[dict exists $params trigger_position]} {
        set tp [dict get $params trigger_position]
        catch {set_property CONTROL.TRIGGER_POSITION $tp $ila}
    }
    if {[dict exists $params trigger_mode]} {
        set tm [dict get $params trigger_mode]
        if {$tm ne ""} {
            catch {set_property CONTROL.TRIGGER_MODE $tm $ila}
        }
    }
    if {[catch {run_hw_ila $ila} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "run_hw_ila failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            ila   $ila \
            armed [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# wait_ila — wait_on_hw_ila until trigger or timeout.
# params:
#   ila      (string, required)
#   timeout  (int, optional, default 30) — seconds
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::wait_ila {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    if {![dict exists $params ila]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'ila' parameter"
        return
    }
    set want [dict get $params ila]
    set to 30
    if {[dict exists $params timeout]} {
        set v [dict get $params timeout]
        if {[string is integer -strict $v] && $v > 0} { set to $v }
    }
    set ila ""
    foreach i [get_hw_ilas -quiet] {
        if {[string match -nocase "*$want*" $i]} { set ila $i; break }
    }
    if {$ila eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No ILA matching '$want'"
        return
    }
    set triggered 1
    if {[catch {wait_on_hw_ila -timeout $to $ila} err]} {
        set triggered 0
    }
    set status ""
    catch {set status [get_property CORE_STATUS $ila]}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            ila       $ila \
            triggered [::vmcp::json::bool $triggered] \
            status    $status]]
    return ok
}

# ------------------------------------------------------------------------------
# read_ila_data — upload capture + write to file (CSV or VCD by extension).
# params:
#   ila  (string, required)
#   path (string, required)  — .csv or .vcd
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::read_ila_data {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    foreach k {ila path} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set want [dict get $params ila]
    set path [dict get $params path]
    set ila ""
    foreach i [get_hw_ilas -quiet] {
        if {[string match -nocase "*$want*" $i]} { set ila $i; break }
    }
    if {$ila eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No ILA matching '$want'"
        return
    }
    if {[catch {upload_hw_ila_data $ila} data opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "upload_hw_ila_data failed: $data" \
            [dict get $opts -errorinfo]
        return
    }
    set ext [string tolower [file extension $path]]
    set format "csv"
    if {$ext eq ".vcd"} { set format "vcd" }
    if {[catch {write_hw_ila_data -force -${format}_file $path $data} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "write_hw_ila_data failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    set size 0
    catch {set size [file size $path]}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            ila        $ila \
            path       $path \
            format     $format \
            size_bytes [::vmcp::json::num $size]]]
    return ok
}

# ------------------------------------------------------------------------------
# get_vio — refresh and read a VIO input probe.
# params:
#   probe (string, required) — probe name substring
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::get_vio {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    if {![dict exists $params probe]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "INVALID_PARAMS" "Missing 'probe' parameter"
        return
    }
    set want [dict get $params probe]
    set probe ""
    foreach p [get_hw_probes -quiet] {
        if {[string match -nocase "*$want*" $p]} { set probe $p; break }
    }
    if {$probe eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No probe matching '$want'"
        return
    }
    set vio ""
    catch {set vio [get_hw_vios -of_objects $probe]}
    if {$vio ne ""} { catch {refresh_hw_vio $vio} }
    set value ""
    catch {set value [get_property INPUT_VALUE $probe]}
    set radix ""
    catch {set radix [get_property INPUT_VALUE_RADIX $probe]}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            probe $probe \
            vio   $vio \
            value $value \
            radix $radix]]
    return ok
}

# ------------------------------------------------------------------------------
# set_vio — write a VIO output probe.
# params:
#   probe (string, required)
#   value (string, required)
#   radix (string, optional) — BINARY|HEX|UNSIGNED|SIGNED (default BINARY)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::set_vio {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    foreach k {probe value} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set want  [dict get $params probe]
    set value [dict get $params value]
    set radix "BINARY"
    if {[dict exists $params radix]} {
        set v [dict get $params radix]
        if {$v ne ""} { set radix [string toupper $v] }
    }
    set probe ""
    foreach p [get_hw_probes -quiet] {
        if {[string match -nocase "*$want*" $p]} { set probe $p; break }
    }
    if {$probe eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No probe matching '$want'"
        return
    }
    if {[catch {set_property OUTPUT_VALUE_RADIX $radix $probe} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "set OUTPUT_VALUE_RADIX failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    if {[catch {set_property OUTPUT_VALUE $value $probe} err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "set OUTPUT_VALUE failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    set vio ""
    catch {set vio [get_hw_vios -of_objects $probe]}
    if {$vio ne ""} {
        if {[catch {commit_hw_vio $vio} err opts]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "HW_ERROR" "commit_hw_vio failed: $err" \
                [dict get $opts -errorinfo]
            return
        }
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            probe    $probe \
            vio      $vio \
            value    $value \
            radix    $radix \
            committed [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# list_hw_axis — enumerate JTAG-to-AXI masters in the programmed design.
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::list_hw_axis {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    set axis [list]
    catch {set axis [get_hw_axis -quiet]}
    set json [list]
    foreach a $axis {
        set w ""; set proto ""
        catch {set w     [get_property DATA_WIDTH $a]}
        catch {set proto [get_property PROTOCOL   $a]}
        lappend json [::vmcp::json::obj [list \
            name       $a \
            data_width [::vmcp::json::num $w] \
            protocol   $proto]]
    }
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            count [::vmcp::json::num [llength $axis]] \
            masters [::vmcp::json::arr $json]]]
    return ok
}

# ------------------------------------------------------------------------------
# axi_read — create+run a read txn on a JTAG-to-AXI master.
# params:
#   axi  (string, required) — hw_axi name substring
#   addr (string, required) — hex address (e.g. "40000000")
#   len  (int   , optional) — number of beats (default 1)
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::axi_read {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    foreach k {axi addr} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set want [dict get $params axi]
    set addr [dict get $params addr]
    set len 1
    if {[dict exists $params len]} {
        set v [dict get $params len]
        if {[string is integer -strict $v] && $v > 0} { set len $v }
    }
    set axi ""
    foreach a [get_hw_axis -quiet] {
        if {[string match -nocase "*$want*" $a]} { set axi $a; break }
    }
    if {$axi eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No hw_axi matching '$want'"
        return
    }
    # Unique txn name; delete if exists.
    set txn "vmcp_rd_[clock clicks]"
    catch {delete_hw_axi_txn $txn}
    if {[catch {
        create_hw_axi_txn -type read -address $addr -len $len $txn $axi
    } err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "create_hw_axi_txn failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    if {[catch {run_hw_axi -quiet $txn} err opts]} {
        catch {delete_hw_axi_txn $txn}
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "run_hw_axi failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    set data ""
    catch {set data [get_property DATA [get_hw_axi_txns $txn]]}
    catch {delete_hw_axi_txn $txn}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            axi   $axi \
            addr  $addr \
            len   [::vmcp::json::num $len] \
            data  $data]]
    return ok
}

# ------------------------------------------------------------------------------
# axi_write — create+run a write txn on a JTAG-to-AXI master.
# params:
#   axi  (string, required)
#   addr (string, required) — hex
#   data (string, required) — hex (one beat) or space-separated hex list
# ------------------------------------------------------------------------------
proc ::vmcp::handlers::hardware::axi_write {client_id req_id params} {
    if {![::vmcp::handlers::hardware::_require_hw $client_id $req_id]} return
    foreach k {axi addr data} {
        if {![dict exists $params $k]} {
            ::vmcp::protocol::send_error $client_id $req_id \
                "INVALID_PARAMS" "Missing '$k' parameter"
            return
        }
    }
    set want [dict get $params axi]
    set addr [dict get $params addr]
    set data [dict get $params data]
    set axi ""
    foreach a [get_hw_axis -quiet] {
        if {[string match -nocase "*$want*" $a]} { set axi $a; break }
    }
    if {$axi eq ""} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "NOT_FOUND" "No hw_axi matching '$want'"
        return
    }
    set beats [split [string trim $data]]
    set len [llength $beats]
    if {$len == 0} { set len 1; set beats [list $data] }
    set txn "vmcp_wr_[clock clicks]"
    catch {delete_hw_axi_txn $txn}
    if {[catch {
        create_hw_axi_txn -type write -address $addr -len $len -data $beats $txn $axi
    } err opts]} {
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "create_hw_axi_txn failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    if {[catch {run_hw_axi -quiet $txn} err opts]} {
        catch {delete_hw_axi_txn $txn}
        ::vmcp::protocol::send_error $client_id $req_id \
            "HW_ERROR" "run_hw_axi failed: $err" \
            [dict get $opts -errorinfo]
        return
    }
    catch {delete_hw_axi_txn $txn}
    ::vmcp::protocol::send_result $client_id $req_id \
        [::vmcp::json::obj [list \
            axi      $axi \
            addr     $addr \
            len      [::vmcp::json::num $len] \
            written  [::vmcp::json::bool 1]]]
    return ok
}

# ------------------------------------------------------------------------------
# Registration.
# ------------------------------------------------------------------------------
::vmcp::dispatcher::register connect_hw       ::vmcp::handlers::hardware::connect
::vmcp::dispatcher::register disconnect_hw    ::vmcp::handlers::hardware::disconnect
::vmcp::dispatcher::register get_hw_info      ::vmcp::handlers::hardware::info
::vmcp::dispatcher::register program_device   ::vmcp::handlers::hardware::program
::vmcp::dispatcher::register list_hw_probes   ::vmcp::handlers::hardware::list_probes
::vmcp::dispatcher::register set_ila_trigger  ::vmcp::handlers::hardware::set_ila_trigger
::vmcp::dispatcher::register arm_ila          ::vmcp::handlers::hardware::arm_ila
::vmcp::dispatcher::register wait_ila         ::vmcp::handlers::hardware::wait_ila
::vmcp::dispatcher::register read_ila_data    ::vmcp::handlers::hardware::read_ila_data
::vmcp::dispatcher::register get_vio          ::vmcp::handlers::hardware::get_vio
::vmcp::dispatcher::register set_vio          ::vmcp::handlers::hardware::set_vio
::vmcp::dispatcher::register list_hw_axis     ::vmcp::handlers::hardware::list_hw_axis
::vmcp::dispatcher::register axi_read         ::vmcp::handlers::hardware::axi_read
::vmcp::dispatcher::register axi_write        ::vmcp::handlers::hardware::axi_write
