# ==============================================================================
# vivado-mcp-socket :: lib/json.tcl
# ------------------------------------------------------------------------------
# Minimal JSON encode/decode compatible with TCL 8.5.
#
# Typing: TCL has no native types, so the encoder wraps non-string values in
# a tagged-dict envelope with keys `__vmcp_j` (type) and `__vmcp_v` (value).
# A value is recognised as tagged only when it is a valid dict with exactly
# those two keys, so accidental collision with user strings is effectively
# impossible.
#
# To produce typed values, use the helpers:
#   ::vmcp::json::num  <numeric>          -> JSON number
#   ::vmcp::json::bool <anything>         -> JSON true/false
#   ::vmcp::json::null                    -> JSON null
#   ::vmcp::json::obj  {k1 v1 k2 v2 ...}  -> JSON object
#   ::vmcp::json::arr  {v1 v2 v3 ...}     -> JSON array
#
# Any other value is encoded as a JSON string (with RFC 8259 escaping).
# Tagged values nest freely:
#   ::vmcp::json::obj [list count [::vmcp::json::num 5] ok [::vmcp::json::bool 1]]
#
# `::vmcp::json::emit` flattens a (possibly nested) tagged structure into the
# final JSON text.
# ==============================================================================

namespace eval ::vmcp::json {
    variable have_tcllib 0
}

# Decoder uses tcllib if available (faster, more robust).
if {[catch {package require json} _err] == 0} {
    set ::vmcp::json::have_tcllib 1
}

# ------------------------------------------------------------------------------
# Typed-value constructors.
# ------------------------------------------------------------------------------
proc ::vmcp::json::num {v} {
    # Emit as raw JSON number if parseable; fall back to 0 otherwise so we
    # never produce invalid JSON.
    if {[string is integer -strict $v]} {
        return [dict create __vmcp_j raw __vmcp_v $v]
    }
    if {[string is double -strict $v]} {
        return [dict create __vmcp_j raw __vmcp_v $v]
    }
    return [dict create __vmcp_j raw __vmcp_v 0]
}

proc ::vmcp::json::bool {v} {
    if {[string is true -strict $v]} {
        return [dict create __vmcp_j raw __vmcp_v true]
    }
    return [dict create __vmcp_j raw __vmcp_v false]
}

proc ::vmcp::json::null {} {
    return [dict create __vmcp_j raw __vmcp_v null]
}

# Empty string → JSON null; numeric → JSON number; else → null (never quoted).
# For fields like timing stats where the cached value may be missing.
proc ::vmcp::json::num_or_null {v} {
    set v [string trim $v]
    if {$v eq ""} { return [::vmcp::json::null] }
    if {[string is integer -strict $v]} { return [::vmcp::json::num $v] }
    if {[string is double  -strict $v]} { return [::vmcp::json::num $v] }
    return [::vmcp::json::null]
}

proc ::vmcp::json::obj {kv} {
    return [dict create __vmcp_j obj __vmcp_v $kv]
}

proc ::vmcp::json::arr {items} {
    return [dict create __vmcp_j arr __vmcp_v $items]
}

# ------------------------------------------------------------------------------
# Detect a tagged wrapper. Must be a dict with exactly __vmcp_j and __vmcp_v
# keys — guards against even-length user lists that merely look dict-shaped.
# ------------------------------------------------------------------------------
proc ::vmcp::json::_is_tagged {value} {
    if {[catch {dict size $value} sz]} { return 0 }
    if {$sz != 2} { return 0 }
    if {![dict exists $value __vmcp_j]} { return 0 }
    if {![dict exists $value __vmcp_v]} { return 0 }
    return 1
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
            "\b"    { append out "\\b"  }
            "\f"    { append out "\\f"  }
            "\n"    { append out "\\n"  }
            "\r"    { append out "\\r"  }
            "\t"    { append out "\\t"  }
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
# Encode a value (plain string or tagged wrapper) to JSON text.
# ------------------------------------------------------------------------------
proc ::vmcp::json::encode {value} {
    if {[::vmcp::json::_is_tagged $value]} {
        set tag [dict get $value __vmcp_j]
        set v   [dict get $value __vmcp_v]
        switch -- $tag {
            raw { return $v }
            obj {
                set parts [list]
                foreach {k sub} $v {
                    lappend parts "[::vmcp::json::_escape_string $k]:[::vmcp::json::encode $sub]"
                }
                return "\{[join $parts ,]\}"
            }
            arr {
                set parts [list]
                foreach sub $v {
                    lappend parts [::vmcp::json::encode $sub]
                }
                return "\[[join $parts ,]\]"
            }
        }
    }
    return [::vmcp::json::_escape_string $value]
}

# ------------------------------------------------------------------------------
# Emit final JSON text from a (possibly nested) tagged value.
# ------------------------------------------------------------------------------
proc ::vmcp::json::emit {value} {
    return [::vmcp::json::encode $value]
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
        if {[catch {::json::json2dict $json} result]} {
            error "JSON decode error: $result"
        }
        return $result
    }
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
    incr pos
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
    incr pos
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
    incr pos
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
    # Glob char class: `-` must be first (or escaped) to be literal; placing
    # `+-` at the end turns it into the ASCII range `+`(43)..`-`(45), which
    # silently matches `,`(44) and walks past the end of the number.
    while {$pos < $len && [string match {[-+0-9.eE]} [string index $json $pos]]} {
        incr pos
    }
    return [string range $json $start [expr {$pos-1}]]
}
