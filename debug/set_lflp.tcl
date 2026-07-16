# Write the LFLP floppy source (live tuning, no recompile).
#   quartus_stp -t debug/set_lflp.tcl <phmap> <bit_period> <force_absent> <lstrb_is_hds> <force_motor> <pulse_w>
# All args optional (default 0 = use RTL defaults: phmap 0, bit_period 163, pulse_w 4).
# SOURCE[8:0]=bit_period_ovr(0=default) [12:9]=pulse_w_ovr(0=default)
#   [14:13]=phmap [16]=force_present [17]=lstrb_is_hds [18]=force_motor
package require ::quartus::insystem_source_probe

proc argi {i d} { global argv; if {[llength $argv] > $i} { return [lindex $argv $i] } else { return $d } }
set phmap        [argi 0 0]
set bit_period   [argi 1 0]
set force_absent [argi 2 0]
set lstrb_is_hds [argi 3 0]
set force_motor  [argi 4 0]
set pulse_w      [argi 5 0]
set tach_ovr     [argi 6 0]
set flux_invert  [argi 7 0]
set sync_cells   [argi 8 0]

set src [expr {($bit_period & 0x1FF) | (($pulse_w & 0xF) << 9) | (($phmap & 0x3) << 13) \
    | (($flux_invert & 1) << 15) \
    | (($force_absent & 1) << 16) | (($lstrb_is_hds & 1) << 17) | (($force_motor & 1) << 18) \
    | (($sync_cells & 0xF) << 19) | (($tach_ovr & 0x1FF) << 23)}]

set usb [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $usb] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $usb] 1] }

set insts [get_insystem_source_probe_instance_info -hardware_name $usb -device_name $dev]
start_insystem_source_probe -hardware_name $usb -device_name $dev
foreach inst $insts {
    if {[lindex $inst 3] eq "LFLP"} {
        set idx [lindex $inst 0]
        write_source_data -instance_index $idx -value [format %x $src] -value_in_hex
        puts "LFLP source set: phmap=$phmap bit_period=$bit_period force_absent=$force_absent lstrb_is_hds=$lstrb_is_hds force_motor=$force_motor pulse_w=$pulse_w tach_ovr=$tach_ovr flux_invert=$flux_invert sync_cells=$sync_cells -> src=0x[format %x $src]"
    }
}
end_insystem_source_probe
