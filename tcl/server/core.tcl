# ==============================================================================
# vivado-mcp-socket :: server/core.tcl
# ------------------------------------------------------------------------------
# TCP core of the plugin:
#   - opens `socket -server` on 127.0.0.1:<port>
#   - accepts incoming connections and tracks each client in a dict
#   - sets up `fileevent readable` on each channel for non-blocking NDJSON reads,
#     leveraging Vivado's internal event loop
#   - detects EOF / errors and cleans up channels
#
# Command logic lives in dispatcher.tcl, not here.
# ==============================================================================

namespace eval ::vmcp::core {
    variable server_socket ""
    variable port          7654
    variable host          "127.0.0.1"
    variable clients       [dict create]
    variable next_client_id 1
    variable started       0

    # Per-channel partial read buffers for non-blocking gets.
    variable read_buffer  [dict create]
}

# ------------------------------------------------------------------------------
# Returns a monotonically increasing client identifier.
# ------------------------------------------------------------------------------
proc ::vmcp::core::_new_client_id {} {
    variable next_client_id
    set id $next_client_id
    incr next_client_id
    return $id
}

# ------------------------------------------------------------------------------
# Returns the TCL channel associated with a client_id, or "" if not found.
# ------------------------------------------------------------------------------
proc ::vmcp::core::get_channel {client_id} {
    variable clients
    if {![dict exists $clients $client_id]} { return "" }
    return [dict get $clients $client_id chan]
}

# ------------------------------------------------------------------------------
# Returns the list of currently connected client_ids.
# ------------------------------------------------------------------------------
proc ::vmcp::core::list_clients {} {
    variable clients
    return [dict keys $clients]
}

# ------------------------------------------------------------------------------
# Closes the connection with a specific client and cleans up state.
# ------------------------------------------------------------------------------
proc ::vmcp::core::disconnect_client {client_id} {
    variable clients
    variable read_buffer
    if {![dict exists $clients $client_id]} return
    set chan [dict get $clients $client_id chan]
    catch {fileevent $chan readable {}}
    catch {close $chan}
    dict unset clients $client_id
    if {[dict exists $read_buffer $chan]} {
        dict unset read_buffer $chan
    }
    ::vmcp::log::info "client $client_id disconnected"
    # Notify the dispatcher in case it had queued commands for this client.
    ::vmcp::dispatcher::on_client_disconnect $client_id
}

# ------------------------------------------------------------------------------
# Accept callback: called by Vivado with (chan, addr, port).
# ------------------------------------------------------------------------------
proc ::vmcp::core::_accept_connection {chan addr port} {
    variable clients
    variable read_buffer

    # Security: only accept localhost connections.
    if {$addr ne "127.0.0.1" && $addr ne "::1"} {
        ::vmcp::log::warn "connection rejected from $addr (not localhost)"
        catch {close $chan}
        return
    }

    set id [::vmcp::core::_new_client_id]
    dict set clients $id [dict create chan $chan addr $addr port $port]
    dict set read_buffer $chan ""

    # Channel configuration:
    #   -blocking 0      -> gets returns -1 if no full line is available yet
    #   -buffering line  -> puts flushes each line immediately
    #   -translation lf  -> LF line endings (portable across Windows/Linux)
    #   -encoding utf-8  -> JSON travels as UTF-8
    if {[catch {
        fconfigure $chan -blocking 0 -buffering line -translation lf -encoding utf-8
    } err]} {
        ::vmcp::log::error "fconfigure failed for client $id: $err"
        ::vmcp::core::disconnect_client $id
        return
    }

    fileevent $chan readable [list ::vmcp::core::_on_readable $id $chan]
    ::vmcp::log::info "client $id connected from $addr:$port"
}

# ------------------------------------------------------------------------------
# Readable callback: drains all available complete lines.
# Uses a per-channel buffer to handle fragmented TCP data.
# ------------------------------------------------------------------------------
proc ::vmcp::core::_on_readable {client_id chan} {
    variable read_buffer

    # Detect EOF or peer-closed channel.
    if {[eof $chan]} {
        ::vmcp::core::disconnect_client $client_id
        return
    }

    # Read as many complete lines as available. `gets` returns the number of
    # characters in the line, or -1 if no complete line is available yet.
    while {1} {
        if {[catch {gets $chan line} n]} {
            ::vmcp::log::warn "error reading from client $client_id: $n"
            ::vmcp::core::disconnect_client $client_id
            return
        }
        if {$n < 0} {
            # No complete line yet. If also EOF, disconnect.
            if {[eof $chan]} {
                ::vmcp::core::disconnect_client $client_id
            }
            return
        }
        # Ignore empty lines (trivial keep-alives).
        set trimmed [string trim $line]
        if {$trimmed eq ""} { continue }

        ::vmcp::log::debug "<- client $client_id: $trimmed"
        ::vmcp::dispatcher::enqueue_command $client_id $trimmed
    }
}

# ------------------------------------------------------------------------------
# Start the server. Idempotent: does nothing if already started.
# ------------------------------------------------------------------------------
proc ::vmcp::core::start {{port 7654} {host "127.0.0.1"}} {
    variable server_socket
    variable started

    if {$started} {
        ::vmcp::log::info "server already started, ignoring start"
        return
    }

    set ::vmcp::core::port $port
    set ::vmcp::core::host $host

    if {[catch {
        # -myaddr 127.0.0.1 ensures bind to loopback only.
        set server_socket [socket -server ::vmcp::core::_accept_connection \
                                  -myaddr $host $port]
    } err]} {
        ::vmcp::log::error "could not open socket on $host:$port -> $err"
        return
    }
    set started 1
    ::vmcp::log::info "server listening on $host:$port"
}

# ------------------------------------------------------------------------------
# Stop the server: close the listening socket and all active connections.
# ------------------------------------------------------------------------------
proc ::vmcp::core::stop {} {
    variable server_socket
    variable clients
    variable started

    if {!$started} return

    # Disconnect all active clients.
    foreach id [dict keys $clients] {
        ::vmcp::core::disconnect_client $id
    }

    # Close the listening socket.
    if {$server_socket ne ""} {
        catch {close $server_socket}
        set server_socket ""
    }
    set started 0
    ::vmcp::log::info "server stopped"
}
