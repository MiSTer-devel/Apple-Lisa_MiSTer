# Watch the 6504 error-counter table live: samples $26 (retry), $27 (recal),
# $48-$4F (errcnt_tbl), $08 (errstat), $22 (drv_trk) repeatedly in ONE JTAG
# session so the per-command counter reset can't hide the failures.
#   quartus_stp -t debug/errwatch.tcl [iterations] [delay_ms]
package require ::quartus::insystem_source_probe

proc argi {i d} { global argv; if {[llength $argv] > $i} { return [lindex $argv $i] } else { return $d } }
set iters [argi 0 60]
set dly   [argi 1 250]

set usb [lindex [get_hardware_names] 0]
set dev ""
foreach d [get_device_names -hardware_name $usb] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $usb] 1] }

set insts [get_insystem_source_probe_instance_info -hardware_name $usb -device_name $dev]
start_insystem_source_probe -hardware_name $usb -device_name $dev
set idx -1
foreach inst $insts {
    if {[lindex $inst 3] eq "LFDR"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "no LFDR"; exit 1 }

set addrs {0x26 0x27 0x08 0x22 0x48 0x49 0x4a 0x4b 0x4c 0x4d 0x4e 0x4f}
for {set k 0} {$k < $iters} {incr k} {
    set row ""
    foreach a $addrs {
        write_source_data -instance_index $idx -value [format %03x $a] -value_in_hex
        set p [read_probe_data -instance_index $idx -value_in_hex]
        # probe[7:0] = byte
        set byte [string range $p end-1 end]
        append row [format "%s:%s " [format %02x $a] $byte]
    }
    puts "T$k $row"
    after $dly
}
end_insystem_source_probe -instance_index $idx
