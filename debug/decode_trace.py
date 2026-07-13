#!/usr/bin/env python3
"""Decode LTRC trace dump (read_trace.tcl output on stdin) into a waveform table.
Sample bits: [15]=E [14]=_AS [13]=_VPA [12]=_VMA [11]=READ [10]=_CDACK [9]=_BERR [8]=CPUC1 [7:0]=UD
The buffer is a ring: write pointer in the status word marks the oldest sample."""
import sys, re

status = None
samples = {}
for line in sys.stdin:
    m = re.match(r'status:\s*0x([0-9A-Fa-f]+)', line)
    if m: status = int(m.group(1), 16)
    m = re.match(r'S(\d+):\s*0x([0-9A-Fa-f]+)', line)
    if m: samples[int(m.group(1))] = int(m.group(2), 16) & 0xFFFF

if status is not None:
    done = (status >> 24) & 1
    wr = (status >> 17) & 0x7F
    print(f"triggered/done={done} wrptr={wr}")
else:
    wr = 0

order = [(i + wr) % 128 for i in range(128)]
print(f"{'idx':>4} {'E':>2} {'_AS':>3} {'_VPA':>4} {'_VMA':>4} {'RD':>2} {'_CDK':>4} {'_BER':>4} {'CPUC1':>5} {'UD':>4}")
prev = None
for n, i in enumerate(order):
    if i not in samples: continue
    v = samples[i]
    row = (v >> 15 & 1, v >> 14 & 1, v >> 13 & 1, v >> 12 & 1, v >> 11 & 1, v >> 10 & 1, v >> 9 & 1, v >> 8 & 1, v & 0xFF)
    tag = ''
    if row != prev:
        print(f"{n:>4} {row[0]:>2} {row[1]:>3} {row[2]:>4} {row[3]:>4} {row[4]:>2} {row[5]:>4} {row[6]:>4} {row[7]:>5} {row[8]:#04x}")
    prev = row
