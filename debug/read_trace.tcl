# Re-arm the LTRC trace, wait for trigger, dump all 128 samples.
# Usage: quartus_stp -t read_trace.tcl
package require ::quartus::insystem_source_probe

set usb [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $usb] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
set insts [get_insystem_source_probe_instance_info -hardware_name $usb -device_name $dev]
set idx -1
foreach inst $insts {
    if {[lindex $inst 3] eq "LTRC"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "LTRC not found"; exit 1 }
start_insystem_source_probe -hardware_name $usb -device_name $dev

# re-arm: source bit7 pulse
write_source_data -instance_index $idx -value 80 -value_in_hex
write_source_data -instance_index $idx -value 00 -value_in_hex
after 500

# check triggered
set v [read_probe_data -instance_index $idx -value_in_hex]
puts "status: 0x$v"

# dump 128 samples
for {set a 0} {$a < 128} {incr a} {
    write_source_data -instance_index $idx -value [format %02X $a] -value_in_hex
    set v [read_probe_data -instance_index $idx -value_in_hex]
    puts [format "S%03d: 0x%s" $a $v]
}
end_insystem_source_probe
