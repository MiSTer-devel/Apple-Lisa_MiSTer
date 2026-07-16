#!/usr/bin/env python3
# Decode the LFLP floppy bring-up probe (64-bit). Pipe `quartus_stp -t
# debug/read_probes.tcl` output into this, or pass the hex value as argv[1].
#
# PROBE layout (see rtl/sony_drive.sv "LFLP"):
#   [63:61] bit_period_eff[8:6]   [60] force_motor     [59] force_present
#   [58] lstrb_is_hds             [57:56] phmap        [55:48] sd_rd_cnt
#   [47:40] step_cnt              [39:32] rddata_cnt   [31:24] ph_activity_cnt
#   [23] sel  [22] motor_on  [21] disk_present  [20:18] ld_state
#   [17:14] raddr  [13:7] loaded_track  [6:0] driveTrack
import sys, re

REG = {0:"DIRTN",1:"CSTIN",2:"STEP",3:"WRTPRT",4:"MOTORON",5:"TK0",6:"EJECT",
       7:"TACH",8:"RDDATA0",9:"RDDATA1",10:"SUPERDR",12:"SIDES",13:"READY",
       14:"INSTALLED",15:"DRVIN"}
LDST = {0:"IDLE",1:"SETUP",2:"REQ",3:"STREAM",4:"BLKDONE"}

def bits(v,hi,lo): return (v >> lo) & ((1 << (hi-lo+1)) - 1)

def decode(v):
    raddr = bits(v,17,14)
    print(f"  driveTrack   = {bits(v,6,0)}")
    print(f"  loaded_track = {bits(v,13,7)}")
    print(f"  raddr        = {raddr:#x} ({REG.get(raddr,'?')})   <- register the 6504 is addressing")
    print(f"  ld_state     = {bits(v,20,18)} ({LDST.get(bits(v,20,18),'?')})")
    print(f"  disk_present = {bits(v,21,21)}   motor_on = {bits(v,22,22)}   sel = {bits(v,23,23)}")
    print(f"  ph_activity  = {bits(v,31,24)}   (FDC toggling PH/HDS -> talking to drive)")
    print(f"  rddata_cnt   = {bits(v,39,32)}   (times firmware selected RDDATA -> reading)")
    print(f"  step_cnt     = {bits(v,47,40)}   sd_rd_cnt = {bits(v,55,48)} (floppy SD loads)")
    print(f"  phmap        = {bits(v,57,56)}   lstrb_is_hds = {bits(v,58,58)}")
    print(f"  MOUNT: mnt_seen={bits(v,60,60)} img_size_nz={bits(v,59,59)} eject_seen={bits(v,58,58)} mnt_cnt={bits(v,57,56)}")
    print(f"  load_ever={bits(v,63,63)} sdack_ever={bits(v,62,62)} need_load={bits(v,61,61)}  (loader ran? / SD acked? / wants load)")

def regnames(mask):
    return " ".join(REG.get(i,f"r{i}") for i in range(16) if mask & (1<<i)) or "(none)"

def decode2(v):
    reg_seen    = bits(v,31,16)
    reg_wr_seen = bits(v,47,32)
    h = [bits(v,51,48),bits(v,55,52),bits(v,59,56),bits(v,63,60)]
    print(f"  registers ADDRESSED: {regnames(reg_seen)}")
    print(f"  registers WRITTEN:   {regnames(reg_wr_seen)}")
    print(f"  recent regs (new->old): " + " ".join(f"{REG.get(x,x)}" for x in h))

def main():
    if len(sys.argv) > 1:
        decode(int(sys.argv[1].replace("0x",""),16)); return
    data = sys.stdin.read()
    m = re.search(r"LFLP\[\d+\]\s*=\s*0x([0-9a-fA-F]+)", data)
    if m:
        print(f"LFLP = 0x{m.group(1)}"); decode(int(m.group(1),16))
    m2 = re.search(r"LFL2\[\d+\]\s*=\s*0x([0-9a-fA-F]+)", data)
    if m2:
        print(f"LFL2 = 0x{m2.group(1)}"); decode2(int(m2.group(1),16))
    m3 = re.search(r"LSEQ\[\d+\]\s*=\s*0x([0-9a-fA-F]+)", data)
    if m3:
        v=int(m3.group(1),16)
        print(f"LSEQ = 0x{m3.group(1)}")
        print(f"  DATA-FIELD capture (first 4 GCR bytes after D5 AA AD): dcap0={bits(v,31,24):02X} dcap1={bits(v,23,16):02X} dcap2={bits(v,15,8):02X} dcap3={bits(v,7,0):02X}")
        print(f"  valid_byte_cnt={bits(v,47,32)}")
        print(f"  saw_addr(D5AA96)={bits(v,63,63)}  saw_data(D5AAAD)={bits(v,62,62)}  saw_data_epilogue(DEAA)={bits(v,61,61)}  FDIR_ever={bits(v,60,60)}  FDIR={bits(v,59,59)}")
    if not m and not m2 and not m3:
        print("no LFLP/LFL2/LSEQ probe in input"); sys.exit(1)

if __name__ == "__main__": main()
