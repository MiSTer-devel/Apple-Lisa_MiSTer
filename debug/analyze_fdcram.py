#!/usr/bin/env python3
# DEBUG (remove for release): analyze an FDC-RAM dump against a DC42 image.
#   quartus_stp -t debug/dump_fdcram.tcl 0 1023 2>/dev/null \
#     | python3 debug/analyze_fdcram.py <img.dc42>
#
# The 6504 firmware (refs/lisaio-master/lisaio-sony.asm) keeps the sector data
# buffer at $01F4..$03FF = 524 bytes: 12 tag bytes at $01F4, then 512 data bytes
# at $0200. The 68000 boot ROM signature-checks the word at data offset 4
# (= $0204), which must be $AAAA.
#
# Verdict logic -- this splits the remaining P6A -> 6504 -> FDC RAM -> 68000 chain:
#   * data matches image sector N exactly  -> the read is PERFECT. If N != the
#     block the machine asked for, it's a logical-block MAPPING bug (which the
#     testbench cannot catch: it checks the track buffer with the same soff math
#     the RTL uses). If N == 0, the read path is fine and the bug is 68000-side.
#   * matches no sector                    -> corruption in PSM_out -> 6504.
import sys, re

img = open(sys.argv[1], 'rb').read()
DATA_BASE, TAG_BASE = 84, 84 + 409600
NSEC = (len(img) - 84 - 9600) // 512

ram = {}
for line in sys.stdin:
    m = re.match(r'^(\d+)\s+([0-9A-Fa-f]{2})\s*$', line)
    if m: ram[int(m.group(1))] = int(m.group(2), 16)
    elif line.startswith('WARN') or line.startswith('ERROR'): print(line.strip())

if not ram:
    print("no bytes read (is the LFDR probe in the loaded .rbf?)"); sys.exit(1)
print(f"{len(ram)} RAM bytes dumped")

def grab(lo, n):
    return bytes(ram[a] for a in range(lo, lo+n) if a in ram)

tags = grab(0x01F4, 12)
data = grab(0x0200, 512)
print(f"\ntags  @$01F4: {tags.hex(' ')}")
print(f"data  @$0200: {data[:16].hex(' ')} ...")
if len(data) >= 6:
    sig = int.from_bytes(data[4:6], 'big')
    print(f"boot signature word @$0204 = {sig:04X}  ({'OK == AAAA' if sig==0xAAAA else 'FAIL -- ROM wants AAAA'})")

# Which image sector does the buffer actually hold?
hit = None
if len(data) == 512:
    for s in range(NSEC):
        if img[DATA_BASE + s*512 : DATA_BASE + s*512 + 512] == data:
            hit = s; break
print()
if hit is not None:
    tag_exp = img[TAG_BASE + hit*12 : TAG_BASE + hit*12 + 12]
    print(f"*** data field matches image sector {hit} EXACTLY (byte-for-byte) ***")
    print(f"    tags got {tags.hex(' ')}")
    print(f"    tags exp {tag_exp.hex(' ')}  -> {'match' if tags==tag_exp else 'MISMATCH'}")
    print("    => the GCR read path is PERFECT. If the machine asked for a")
    print("       different block than %d, this is a logical-block MAPPING bug." % hit)
else:
    # how close is the best match? distinguishes 'wrong block' from 'garbage'
    best, bs = -1, None
    for s in range(NSEC):
        e = img[DATA_BASE + s*512 : DATA_BASE + s*512 + 512]
        m = sum(1 for i in range(min(len(e), len(data))) if e[i] == data[i])
        if m > best: best, bs = m, s
    print(f"data field matches NO image sector exactly.")
    print(f"best partial match: sector {bs} at {best}/512 bytes")
    print("    => corruption between PSM_out and the 6504 (decode/checksum path),")
    print("       or the buffer was mid-read / holds no sector at all.")
