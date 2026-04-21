# ==============================================================================
# vivado-mcp-socket :: lib/logger.tcl
# ------------------------------------------------------------------------------
# Minimal logger compatible with TCL 8.5.
#
# Writes messages to:
#   - stdout (Vivado TCL console) with [vmcp] prefix
#   - log file (if configured) with timestamp and level
#
# Supported levels: DEBUG, INFO, WARN, ERROR
# Minimum level configurable via ::vmcp::log::set_level
# ==============================================================================

namespace eval ::vmcp::log {
    variable level_num
    array set level_num {
        DEBUG 10
        INFO  20
        WARN  30
        ERROR 40
    }

    variable current_level 20    ;# INFO by default
    variable log_file ""
    variable log_chan ""
}

# ------------------------------------------------------------------------------
# Set the minimum logging level.
# ------------------------------------------------------------------------------
proc ::vmcp::log::set_level {name} {
    variable level_num
    variable current_level
    set name [string toupper $name]
    if {[::info exists level_num($name)]} {
        set current_level $level_num($name)
    }
}

# ------------------------------------------------------------------------------
# Open (or reopen) a file for persistent logging.
# ------------------------------------------------------------------------------
proc ::vmcp::log::set_file {path} {
    variable log_file
    variable log_chan
    if {$log_chan ne ""} {
        catch {close $log_chan}
        set log_chan ""
    }
    set log_file $path
    if {$path ne ""} {
        if {[catch {open $path a} chan]} {
            set log_chan ""
            return 0
        }
        fconfigure $chan -buffering line
        set log_chan $chan
    }
    return 1
}

# ------------------------------------------------------------------------------
# Close the log file (if open).
# ------------------------------------------------------------------------------
proc ::vmcp::log::close_file {} {
    variable log_chan
    if {$log_chan ne ""} {
        catch {close $log_chan}
        set log_chan ""
    }
}

# ------------------------------------------------------------------------------
# Internal emit: writes to stdout and to the file if configured.
# ------------------------------------------------------------------------------
proc ::vmcp::log::_emit {level msg} {
    variable level_num
    variable current_level
    variable log_chan

    set level [string toupper $level]
    if {![::info exists level_num($level)]} {
        set level "INFO"
    }
    if {$level_num($level) < $current_level} {
        return
    }

    set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set line "\[$ts\] \[$level\] $msg"

    # Vivado console (short prefix)
    catch {puts "\[vmcp\] $msg"}

    # Log file (if open)
    if {$log_chan ne ""} {
        catch {puts $log_chan $line}
    }
}

proc ::vmcp::log::debug {msg} { ::vmcp::log::_emit DEBUG $msg }
proc ::vmcp::log::info  {msg} { ::vmcp::log::_emit INFO  $msg }
proc ::vmcp::log::warn  {msg} { ::vmcp::log::_emit WARN  $msg }
proc ::vmcp::log::error {msg} { ::vmcp::log::_emit ERROR $msg }
