# ==============================================================================
# vivado-mcp-socket :: server/protocol.tcl
# ------------------------------------------------------------------------------
# NDJSON (Newline-Delimited JSON) framing and emission of the message types
# understood by the Python client:
#
#   - ack          (status=started, for long-running commands)
#   - progress     (percent + message, streaming)
#   - result       (status=ok|error)
#   - notification (no id, broadcast to all connected clients)
#
# All functions receive a `client_id` already resolved by `core.tcl`
# (which is responsible for translating it to the corresponding TCL channel).
# ==============================================================================

namespace eval ::vmcp::protocol {}

# ------------------------------------------------------------------------------
# Send a JSON line on a specific client's channel.
# Silent on write errors (the client may have closed the connection).
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::send_raw {client_id json_line} {
    set chan [::vmcp::core::get_channel $client_id]
    if {$chan eq ""} {
        ::vmcp::log::log_debug "send_raw: client $client_id not found (message discarded)"
        return 0
    }
    if {[catch {
        puts $chan $json_line
        flush $chan
    } err]} {
        ::vmcp::log::log_warn "send_raw: write error for client $client_id: $err"
        ::vmcp::core::disconnect_client $client_id
        return 0
    }
    return 1
}

# ------------------------------------------------------------------------------
# Send an ACK for a long-running command.
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::send_ack {client_id req_id message} {
    set msg [::vmcp::json::obj [list \
        id      $req_id \
        type    "ack" \
        status  "started" \
        message $message]]
    ::vmcp::protocol::send_raw $client_id [::vmcp::json::emit $msg]
}

# ------------------------------------------------------------------------------
# Send a progress event.
#
#   percent: integer 0-100 (or -1 if not available)
#   message: human-readable description of the current step
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::send_progress {client_id req_id percent message} {
    # Sanitize percent to emit as a JSON number without quotes.
    if {![string is integer -strict $percent]} {
        if {![string is double -strict $percent]} {
            set percent 0
        }
    }
    set msg [::vmcp::json::obj [list \
        id      $req_id \
        type    "progress" \
        percent [::vmcp::json::num $percent] \
        message $message]]
    ::vmcp::protocol::send_raw $client_id [::vmcp::json::emit $msg]
}

# ------------------------------------------------------------------------------
# Send a successful final result.
#
#   data: a tagged JSON wrapper (::vmcp::json::obj / ::arr / ::num / ::bool),
#         an even-length key/value list (wrapped as an object), or a plain
#         string.
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::send_result {client_id req_id data} {
    set data_encoded [::vmcp::protocol::_normalize_data $data]
    set msg [::vmcp::json::obj [list \
        id     $req_id \
        type   "result" \
        status "ok" \
        data   $data_encoded]]
    ::vmcp::protocol::send_raw $client_id [::vmcp::json::emit $msg]
}

# ------------------------------------------------------------------------------
# Send a final error result.
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::send_error {client_id req_id code message {detail ""}} {
    set err_obj [::vmcp::json::obj [list \
        code    $code \
        message $message \
        detail  $detail]]
    set msg [::vmcp::json::obj [list \
        id     $req_id \
        type   "result" \
        status "error" \
        error  $err_obj]]
    ::vmcp::protocol::send_raw $client_id [::vmcp::json::emit $msg]
}

# ------------------------------------------------------------------------------
# Broadcast a notification (no req_id) to all connected clients.
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::broadcast_notification {event data} {
    set data_encoded [::vmcp::protocol::_normalize_data $data]
    set msg [::vmcp::json::obj [list \
        type  "notification" \
        event $event \
        data  $data_encoded]]
    set line [::vmcp::json::emit $msg]
    foreach client_id [::vmcp::core::list_clients] {
        ::vmcp::protocol::send_raw $client_id $line
    }
}

# ------------------------------------------------------------------------------
# Normalize `data` to embed as a JSON sub-value.
# Accepts:
#   - a tagged JSON wrapper (::vmcp::json::obj / ::arr / ::num / ::bool / ::null)
#   - TCL dict / even-length key-value list  -> wrapped as JSON object
#   - plain string
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::_normalize_data {data} {
    if {[::vmcp::json::_is_tagged $data]} {
        return $data
    }
    if {[llength $data] % 2 == 0 && [llength $data] > 0} {
        return [::vmcp::json::obj $data]
    }
    return $data
}

# ------------------------------------------------------------------------------
# Decode an NDJSON line into a TCL dict. Raises an error if the JSON is
# invalid or required fields are missing.
# ------------------------------------------------------------------------------
proc ::vmcp::protocol::parse_request {line} {
    if {[catch {::vmcp::json::decode $line} parsed]} {
        error "Invalid JSON: $parsed"
    }
    foreach field {id type command} {
        if {![dict exists $parsed $field]} {
            error "Missing required field: $field"
        }
    }
    return $parsed
}
