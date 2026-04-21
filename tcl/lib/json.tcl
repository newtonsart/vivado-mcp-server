# ==============================================================================
# vivado-mcp-socket :: lib/json.tcl
# ------------------------------------------------------------------------------
# Minimal JSON encode/decode compatible with TCL 8.5.
#
# Tries to use tcllib (`package require json` / `json::write`) if available,
# since Vivado typically ships it. Falls back to a custom implementation that
# covers the protocol's use cases:
#   - strings, integers, floats, booleans, null
#   - lists (JSON arrays)
#   - TCL dicts (JSON objects) — keys are strings
#
# Typing in TCL: since TCL does not distinguish types natively, encoding uses
# these heuristics:
#   - value "true"/"false" -> JSON boolean (unambiguous)
#   - value "null"         -> JSON null
#   - value "##JSON:raw##..." -> emitted as-is (escape hatch)
#   - TCL dict             -> JSON object (alphabetic keys detected)
#   - TCL even-length list -> JSON object only if forced via helper
#
# To force types, use the helpers:
#   ::vmcp::json::num  value
#   ::vmcp::json::str  value
#   ::vmcp::json::bool value
#   ::vmcp::json::null
#   ::vmcp::json::obj  {k1 v1 k2 v2 ...}
#   ::vmcp::json::arr  {v1 v2 ...}
# ==============================================================================

namespace eval ::vmcp::json {
    variable have_tcllib 0
}

if {[catch {package require json} _err] == 0 && \
    [catch {package require json::write} _err] == 0} {
    set ::vmcp::json::have_tcllib 1
    # Force keys in the order given (not alphabetical) for reproducible output.
    catch {::json::write indented 0}
    catch {::json::write aligned  0}
}

# ------------------------------------------------------------------------------
# Escape a string per RFC 8259.
# ------------------------------------------------------------------------------
proc ::vmcp::json::_escape_string {s} {
    set out ""
    set len [string length $s]
    for {set i 0} {$i < $len} {incr i} {
        set c [string index $s $i]
        switch -- $c {
            "\""    { append out "\\\"" }
            "\\"    { append out "\\\\" }
            "/"     { append out "/"     }
            "\b"    { append out "\\b"   }
            "\f"    { append out "\\f"   }
            "\n"    { append out "\\n"   }
            "\r"    { append out "\\r"   }
            "\t"    { append out "\\t"   }
            default {
                scan $c %c code
                if {$code < 0x20} {
                    append out [format "\\u%04x" $code]
                } else {
                    append out $c
                }
            }
        }
    }
    return "\"$out\""
}

# ------------------------------------------------------------------------------
# Explicit type helpers (wrap values in an internal marker).
# ------------------------------------------------------------------------------
proc ::vmcp::json::num  {v}    { return "##JSON:raw##$v" }
proc ::vmcp::json::str  {v}    { return [::vmcp::json::_escape_string $v] \
                                        "##JSON:strraw##" }
proc ::vmcp::json::bool {v} {
    if {[string is true -strict $v]} { return "##JSON:raw##true" }
    return "##JSON:raw##false"
}
proc ::vmcp::json::null {}     { return "##JSON:raw##null" }

# ------------------------------------------------------------------------------
# Encode a TCL value to JSON.
#
# Rules:
#   - "##JSON:raw##X"   -> emit X without quotes (numbers, bool, null)
#   - dict with key "__type" = "object" -> JSON object
#   - dict with key "__type" = "array"  -> JSON array
#   - otherwise treated as string.
#
# Use ::vmcp::json::obj to build objects; ::vmcp::json::arr for arrays.
# ------------------------------------------------------------------------------
proc ::vmcp::json::encode {value} {
    # Raw marker (numbers, bool, null)
    if {[string first "##JSON:raw##" $value] == 0} {
        return [string range $value 12 end]
    }
    # Pre-formatted object marker
    if {[string first "##JSON:obj##" $value] == 0} {
        return [string range $value 12 end]
    }
    # Pre-formatted array marker
    if {[string first "##JSON:arr##" $value] == 0} {
        return [string range $value 12 end]
    }
    # Default: string
    return [::vmcp::json::_escape_string $value]
}

# ------------------------------------------------------------------------------
# Build a JSON object from a dict (flat key/value list).
# Values are encoded recursively.
# ------------------------------------------------------------------------------
proc ::vmcp::json::obj {kvlist} {
    set parts [list]
    foreach {k v} $kvlist {
        lappend parts "[::vmcp::json::_escape_string $k]:[::vmcp::json::encode $v]"
    }
    return "##JSON:obj##\{[join $parts ,]\}"
}

# ------------------------------------------------------------------------------
# Build a JSON array from a list.
# ------------------------------------------------------------------------------
proc ::vmcp::json::arr {items} {
    set parts [list]
    foreach v $items {
        lappend parts [::vmcp::json::encode $v]
    }
    return "##JSON:arr##\[[join $parts ,]\]"
}

# ------------------------------------------------------------------------------
# Emit final JSON (strips internal markers at the root).
# ------------------------------------------------------------------------------
proc ::vmcp::json::emit {value} {
    set out [::vmcp::json::encode $value]
    return $out
}

# ==============================================================================
# DECODER (JSON -> TCL value)
# ------------------------------------------------------------------------------
# Returns a TCL dict for objects, a TCL list for arrays, strings for strings,
# and the literals "true"/"false"/"null" as-is for bool/null.
# Numbers are returned as strings (preserving original precision).
# ==============================================================================

proc ::vmcp::json::decode {json} {
    variable have_tcllib
    if {$have_tcllib} {
        # tcllib returns dicts for objects, lists for arrays.
        if {[catch {::json::json2dict $json} result]} {
            error "JSON decode error: $result"
        }
        return $result
    }
    # Fallback: recursive parser.
    upvar 0 ::vmcp::json::_pos pos
    set pos 0
    set result [::vmcp::json::_parse_value $json]
    ::vmcp::json::_skip_ws $json
    return $result
}

proc ::vmcp::json::_skip_ws {json} {
    upvar 0 ::vmcp::json::_pos pos
    set len [string length $json]
    while {$pos < $len} {
        set c [string index $json $pos]
        if {$c ne " " && $c ne "\t" && $c ne "\n" && $c ne "\r"} break
        incr pos
    }
}

proc ::vmcp::json::_parse_value {json} {
    upvar 0 ::vmcp::json::_pos pos
    ::vmcp::json::_skip_ws $json
    if {$pos >= [string length $json]} {
        error "Unexpected end of JSON input"
    }
    set c [string index $json $pos]
    switch -- $c {
        "\{"    { return [::vmcp::json::_parse_object $json] }
        "\["    { return [::vmcp::json::_parse_array  $json] }
        "\""    { return [::vmcp::json::_parse_string $json] }
        default {
            if {[string match {[-0-9]} $c]} {
                return [::vmcp::json::_parse_number $json]
            }
            # true / false / null
            if {[string range $json $pos [expr {$pos+3}]] eq "true"} {
                incr pos 4
                return "true"
            }
            if {[string range $json $pos [expr {$pos+4}]] eq "false"} {
                incr pos 5
                return "false"
            }
            if {[string range $json $pos [expr {$pos+3}]] eq "null"} {
                incr pos 4
                return "null"
            }
            error "Unexpected character at position $pos: $c"
        }
    }
}

proc ::vmcp::json::_parse_object {json} {
    upvar 0 ::vmcp::json::_pos pos
    incr pos   ;# consume open-brace
    set result [dict create]
    ::vmcp::json::_skip_ws $json
    if {[string index $json $pos] eq "\}"} {
        incr pos
        return $result
    }
    while {1} {
        ::vmcp::json::_skip_ws $json
        if {[string index $json $pos] ne "\""} {
            error "Expected string key at $pos"
        }
        set key [::vmcp::json::_parse_string $json]
        ::vmcp::json::_skip_ws $json
        if {[string index $json $pos] ne ":"} {
            error "Expected ':' at $pos"
        }
        incr pos
        set val [::vmcp::json::_parse_value $json]
        dict set result $key $val
        ::vmcp::json::_skip_ws $json
        set c [string index $json $pos]
        if {$c eq ","} {
            incr pos
            continue
        }
        if {$c eq "\}"} {
            incr pos
            break
        }
        error "Expected ',' or '\}' at $pos"
    }
    return $result
}

proc ::vmcp::json::_parse_array {json} {
    upvar 0 ::vmcp::json::_pos pos
    incr pos   ;# consume "["
    set result [list]
    ::vmcp::json::_skip_ws $json
    if {[string index $json $pos] eq "\]"} {
        incr pos
        return $result
    }
    while {1} {
        set val [::vmcp::json::_parse_value $json]
        lappend result $val
        ::vmcp::json::_skip_ws $json
        set c [string index $json $pos]
        if {$c eq ","} {
            incr pos
            continue
        }
        if {$c eq "\]"} {
            incr pos
            break
        }
        error "Expected ',' or ']' at $pos"
    }
    return $result
}

proc ::vmcp::json::_parse_string {json} {
    upvar 0 ::vmcp::json::_pos pos
    incr pos   ;# consume opening "
    set out ""
    set len [string length $json]
    while {$pos < $len} {
        set c [string index $json $pos]
        if {$c eq "\""} {
            incr pos
            return $out
        }
        if {$c eq "\\"} {
            incr pos
            set esc [string index $json $pos]
            incr pos
            switch -- $esc {
                "\"" { append out "\"" }
                "\\" { append out "\\" }
                "/"  { append out "/"  }
                "b"  { append out "\b" }
                "f"  { append out "\f" }
                "n"  { append out "\n" }
                "r"  { append out "\r" }
                "t"  { append out "\t" }
                "u"  {
                    set hex [string range $json $pos [expr {$pos+3}]]
                    incr pos 4
                    scan $hex %x code
                    append out [format %c $code]
                }
                default { append out $esc }
            }
            continue
        }
        append out $c
        incr pos
    }
    error "Unterminated string"
}

proc ::vmcp::json::_parse_number {json} {
    upvar 0 ::vmcp::json::_pos pos
    set start $pos
    set len [string length $json]
    if {[string index $json $pos] eq "-"} { incr pos }
    while {$pos < $len && [string match {[0-9.eE+-]} [string index $json $pos]]} {
        incr pos
    }
    return [string range $json $start [expr {$pos-1}]]
}
