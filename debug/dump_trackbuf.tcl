# DEBUG (remove for release): dump the sony_drive per-track buffer over JTAG.
#   quartus_stp -t debug/dump_trackbuf.tcl <first_word> <last_word>
# Prints "<word_index> <hex16>" per line plus a STATE line (loaded_track etc),
# for debug/diff_trackbuf.py to diff against the DC42 image.
#
# ISSP API gotcha: get_insystem_source_probe_instance_info MUST be called BEFORE
# start_insystem_source_probe.

set first 0
set last  4095
if {$argc >= 1} { set first [lindex $argv 0] }
if {$argc >= 2} { set last  [lindex $argv 1] }

set found 0
foreach hw [get_hardware_names] {
    if {[string match "*DE-SoC*" $hw]} {
        foreach dev [get_device_names -hardware_name $hw] {
            if {[string match "*5CSEBA6*" $dev] || [string match "*5CSEMA6*" $dev]} {
                if {[catch {set insts [get_insystem_source_probe_instance_info \
                        -hardware_name $hw -device_name $dev]}]} { continue }
                foreach inst $insts {
                    if {[lindex $inst 3] ne "LBUF"} { continue }
                    set idx [lindex $inst 0]
                    start_insystem_source_probe -hardware_name $hw -device_name $dev
                    set found 1
                    for {set w $first} {$w <= $last} {incr w} {
                        write_source_data -instance_index $idx \
                            -value [format %x $w] -value_in_hex
                        # two reads: let the registered trackbuf read settle
                        read_probe_data -instance_index $idx
                        set p [read_probe_data -instance_index $idx]
                        # probe is 64 bits, MSB-first binary string
                        set word [string range $p 48 63]
                        set state [string range $p 14 31]
                        puts [format "%d %04X" $w [expr 0b$word]]
                        if {$w == $first} { puts "STATE $state" }
                    }
                    end_insystem_source_probe
                }
            }
        }
    }
}
if {!$found} { puts "ERROR: LBUF probe not found (is the new .rbf loaded?)" }
