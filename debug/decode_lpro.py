#!/usr/bin/env python3
import sys, re
def bits(v,hi,lo=None):
    if lo is None: lo=hi
    return (v>>lo)&((1<<(hi-lo+1))-1)
STATES=["RESET","IDLE","HS0","HS1","CMDRECV0","CMDRECV1","CMDDECODE","RDCONF0","RDCONF1",
"RDCACHEA","RDCACHEB","RDDATA0","RDDATA1","RDDATA2","WRCONF0","WRCONF1","WRCACHEA","WRCACHEB",
"WRDATA0","WRDATA1","WRFLUSHA","WRFLUSHB","WRDONE0","WRDONE1","HPSREAD","HPSWRITE","BADCMD"]
for line in sys.stdin:
    m=re.match(r'\s*LPRO\[\d+\]\s*=\s*0x([0-9A-Fa-f]+)',line)
    if not m: continue
    v=int(m.group(1),16)
    st=bits(v,63,59); mx=bits(v,58,54)
    def nm(s): return STATES[s] if s<len(STATES) else f"?{s}"
    print(f"== LPRO")
    print(f"  state={nm(st)} max_state={nm(mx)} cmd0=0x{bits(v,53,46):02X} blk=0x{bits(v,45,34):03X}")
    print(f"  cmd_edges={bits(v,33,26)} strb_edges={bits(v,25,18)} rd_acks={bits(v,17,10)}")
    print(f"  img_mounted={bits(v,9)} _PRES={bits(v,8)} _CMD={bits(v,7)} _PSTRB={bits(v,6)} _BSY={bits(v,5)} R_W={bits(v,4)} sd_rd={bits(v,3)} sd_wr={bits(v,2)}")
