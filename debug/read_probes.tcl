# Dump all ISSP probe instances (LDBG, LVID, LRAM) over JTAG.
# Run with: quartus_stp -t read_probes.tcl
package require ::quartus::insystem_source_probe

set usb [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $usb] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $usb] 1] }
puts "hardware: $usb"
puts "device:   $dev"

# NOTE: get_insystem_source_probe_instance_info must be called BEFORE start_
set insts [get_insystem_source_probe_instance_info -hardware_name $usb -device_name $dev]
start_insystem_source_probe -hardware_name $usb -device_name $dev
foreach inst $insts {
    set idx  [lindex $inst 0]
    set name [lindex $inst 3]
    set val  [read_probe_data -instance_index $idx -value_in_hex]
    puts "$name\[$idx\] = 0x$val"
}
end_insystem_source_probe
