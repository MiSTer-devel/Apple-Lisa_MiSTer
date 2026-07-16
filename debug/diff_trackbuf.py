#!/usr/bin/env python3
# DEBUG (remove for release): diff a hardware trackbuf dump against a DC42 image.
#   quartus_stp -t debug/dump_trackbuf.tcl 0 3143 2>/dev/null \
#     | python3 debug/diff_trackbuf.py <img.dc42> <loaded_track>
#
# Buffer layout (16-bit little-endian words), per rtl/sony_drive.sv:
#   DATA sector s -> words s*256 .. s*256+255      (= 512 bytes)
#   TAGS sector s -> words 3072 + s*6 .. +5        (= 12 bytes)
# Image (DC42): 84-byte header, 409600 data bytes, then 9600 tag bytes.
# Buffer sector s holds LOGICAL sector soff(track)+s.
import sys, re

def soff(track):
    if track == 0: return 0
    tm1 = track - 1
    z = (tm1 >> 4) & 7
    return {0: track*12, 1: track*11+16, 2: track*10+48, 3: track*9+96}.get(z, track*8+160)

def spt(track):
    return {0:12, 1:11, 2:10, 3:9}.get((track >> 4) & 7, 8)

img_path = sys.argv[1]
track    = int(sys.argv[2])
img      = open(img_path, 'rb').read()
DATA_BASE, TAG_BASE = 84, 84 + 409600

words = {}
for line in sys.stdin:
    m = re.match(r'^(\d+)\s+([0-9A-Fa-f]{4})\s*$', line)
    if m: words[int(m.group(1))] = int(m.group(2), 16)
    elif line.startswith('STATE'): print(line.strip())

if not words:
    print("no words read (is the LBUF probe in the loaded .rbf?)"); sys.exit(1)

def buf_byte(w, hi):
    v = words.get(w)
    return None if v is None else ((v >> 8) & 0xFF if hi else v & 0xFF)

base, n = soff(track), spt(track)
print(f"track {track}: soff={base} spt={n}  ({len(words)} words dumped)")
total_bad = 0
for s in range(n):
    lsec = base + s
    # ---- data: 512 bytes ----
    bad, first = 0, None
    for i in range(512):
        got = buf_byte(s*256 + i//2, i & 1)
        if got is None: continue
        exp = img[DATA_BASE + lsec*512 + i]
        if got != exp:
            bad += 1
            if first is None: first = (i, got, exp)
    # ---- tags: 12 bytes ----
    tbad, tfirst = 0, None
    for i in range(12):
        got = buf_byte(3072 + s*6 + i//2, i & 1)
        if got is None: continue
        exp = img[TAG_BASE + lsec*12 + i]
        if got != exp:
            tbad += 1
            if tfirst is None: tfirst = (i, got, exp)
    total_bad += bad + tbad
    flag = "OK " if (bad == 0 and tbad == 0) else "BAD"
    msg = f"  {flag} sector {s:2d} (logical {lsec:3d}): data_mism={bad:3d}/512 tag_mism={tbad:2d}/12"
    if first:  msg += f"  data[{first[0]}] got={first[1]:02X} exp={first[2]:02X}"
    if tfirst: msg += f"  tag[{tfirst[0]}] got={tfirst[1]:02X} exp={tfirst[2]:02X}"
    print(msg)

print(f"\n== {'PASS: buffer matches image' if total_bad==0 else f'FAIL: {total_bad} mismatched bytes'} ==")

# First bytes of sector 0 -- the boot block the ROM signature-checks.
got0 = bytes(b for b in (buf_byte(i//2, i & 1) for i in range(16)) if b is not None)
print(f"buf sector0 data[0:16]: {got0.hex(' ')}")
print(f"img sector0 data[0:16]: {img[DATA_BASE+base*512 : DATA_BASE+base*512+16].hex(' ')}")
