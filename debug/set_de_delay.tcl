# Set the DE pixel-delay trim via the LVID ISSP source (5 bits, 0 = default 18).
# Usage: quartus_stp -t set_de_delay.tcl <delay 1..31>
package require ::quartus::insystem_source_probe

set delay [lindex $quartus(args) 0]
set usb [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $usb] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
set insts [get_insystem_source_probe_instance_info -hardware_name $usb -device_name $dev]
set idx -1
foreach inst $insts {
    if {[lindex $inst 3] eq "LVID"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "LVID instance not found"; exit 1 }
start_insystem_source_probe -hardware_name $usb -device_name $dev
write_source_data -instance_index $idx -value [format %04X $delay] -value_in_hex
end_insystem_source_probe
puts "de_delay set to $delay"
