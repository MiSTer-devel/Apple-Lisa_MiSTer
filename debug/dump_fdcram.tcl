# DEBUG (remove for release): dump the shared 6504<->68000 FDC RAM over JTAG.
#   quartus_stp -t debug/dump_fdcram.tcl [first] [last]
# Prints "<addr> <hex8>" per line. The 6504 sees this RAM at $0000-$03FF;
# the 68000 sees the same bytes at FCC001 + 2n.
#
# ISSP API gotcha: get_insystem_source_probe_instance_info MUST be called BEFORE
# start_insystem_source_probe.

set first 0
set last  1023
if {$argc >= 1} { set first [lindex $argv 0] }
if {$argc >= 2} { set last  [lindex $argv 1] }

set found 0
foreach hw [get_hardware_names] {
    if {![string match "*DE-SoC*" $hw]} { continue }
    foreach dev [get_device_names -hardware_name $hw] {
        if {!([string match "*5CSEBA6*" $dev] || [string match "*5CSEMA6*" $dev])} { continue }
        if {[catch {set insts [get_insystem_source_probe_instance_info \
                -hardware_name $hw -device_name $dev]}]} { continue }
        foreach inst $insts {
            if {[lindex $inst 3] ne "LFDR"} { continue }
            set idx [lindex $inst 0]
            start_insystem_source_probe -hardware_name $hw -device_name $dev
            set found 1
            for {set a $first} {$a <= $last} {incr a} {
                write_source_data -instance_index $idx \
                    -value [format %x $a] -value_in_hex
                read_probe_data -instance_index $idx
                set p [read_probe_data -instance_index $idx]
                # probe is 32 bits MSB-first: [31:18]=0 [17:8]=addr echo [7:0]=byte
                set byte [string range $p 24 31]
                set aecho [string range $p 14 23]
                if {[expr 0b$aecho] != $a} {
                    puts "WARN addr echo mismatch: wrote $a read [expr 0b$aecho]"
                }
                puts [format "%d %02X" $a [expr 0b$byte]]
            }
            end_insystem_source_probe
        }
    }
}
if {!$found} { puts "ERROR: LFDR probe not found (is the new .rbf loaded?)" }
