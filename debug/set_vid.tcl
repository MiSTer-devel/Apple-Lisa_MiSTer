# Live video-position trim via the LVID ISSP source (16 bits).
#   vid_src[10:0]  = h_de_start   (DE window start; RTL default 20 when 0)
#   vid_src[15:11] = origin coarse (x16 dots; RTL default 144 when 0)
# Usage: quartus_stp -t debug/set_vid.tcl <h_de_start> [origin_coarse_index]
#   e.g. quartus_stp -t debug/set_vid.tcl 70        -> h_de_start=70, origin default
#        quartus_stp -t debug/set_vid.tcl 70 18     -> h_de_start=70, origin=18*16=288
package require ::quartus::insystem_source_probe

set hde [lindex $quartus(args) 0]
set org [lindex $quartus(args) 1]
if {$org eq ""} { set org 0 }
set val [expr {(($org & 0x1F) << 11) | ($hde & 0x7FF)}]

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
write_source_data -instance_index $idx -value [format %04X $val] -value_in_hex
end_insystem_source_probe
puts "LVID set: h_de_start=$hde origin_idx=$org  (source=0x[format %04X $val])"
