#!/usr/bin/env python3
"""Tick-accurate offline model of the FDC GCR sequencer (P6A PROM + LS323).

    python3 debug/sim_p6a.py [rtl/P6A.mem]

Why this exists
---------------
The 6504 mishandles ~16% of the bytes the sequencer assembles on hardware
(measured by probe L65C: 84.1% read exactly once, 9.0% missed, 6.8% read
twice). A 5-byte address field then decodes only 0.84^5 = ~42% of the time,
and a 699-byte data field never completes -- which is the floppy bug: the
6504 reports err_cant_read ($17), the boot ROM shows error 23.

This model reproduces the sequencer exactly (it assembles D5 AA 96 from raw
flux, matching LSEQ.saw_addr=1 on hardware), so sequencer fixes can be tried
here in a second instead of via a 10-minute Quartus build + hardware run.

Wiring is per the schematic (docs/schematics/050-4008-L_floppy_pg4.pdf,
U3B-74LS323 <-> U4B-341-0172), which matches rtl/IO_board.sv:
    PROM D3->LS323 CLR, D1->S0, D0->S1, D2->SL, LS323 QA->PROM A1, G2<-MA0.
    PROM address: [7],[6],[5],[0] = state latched from data[7],[6],[4],[5]
                  [4] = ~(RDA rising edge), [3] = Q7, [2] = Q6, [1] = QA.
Note the real hardware has NO CPU-read strobe into the sequencer -- the PROM
sees only {state, RDA, Q7, Q6, SR_MSB}. Do not "fix" this by clearing the
register on a CPU read; that was tried (commit 3efbb2b), measured worse
(84%->34% OK), and is unfaithful to the schematic. It is reverted.

What it found
-------------
1 tick = one state_machine_clk_enable. Framing REQUIRES 8 ticks per bit cell
(4 and 16 both fail to frame), so the 4MHz sequencer clock is correct for the
Lisa's 2us cells and cannot be retuned.

The byte-valid window is then inherently 17 ticks:
    Apple II: 4us cells -> 500ns tick -> 17 ticks = 8.5us vs its 1MHz CPU's
              8us poll  -> 8.5 > 8    -> works
    Lisa:     2us cells -> 250ns tick -> 17 ticks = 4.25us vs the 2MHz 6504's
              5.5us find_addr search poll -> 4.25 < 5.5 -> MISSES BYTES

So the same PROM that is correct on an Apple II is structurally too short on a
Lisa. rtl/IO_board.sv:460 assumes the Lisa's sequencer PROM is "the EXACT SAME
PART used in the Apple ][ disk controller", but the schematic calls it
341-0172 while the Disk II's is 341-0028. The real 341-0172 should hold ~24+
ticks (>5.5us). Getting a genuine 341-0172 dump is very likely the fix.
"""
import sys

TICK_NS = 250          # state_machine_clk = 4MHz (state_machine_clk_int ^ FDC_counter[1])
TICKS_PER_CELL = 8     # 2us Sony bit cell
# 6504 @2MHz: the find_addr wait loop (lda q7l / bpl) is ~3.5us; the search
# loop (lda q7l / bmi / dex / bne = 11 cycles) is ~5.5us. After taking a byte
# the firmware does ~9.5us of work. So the window must be >5.5us and <9.5us.
POLL_US_WAIT, POLL_US_SEARCH, WORK_US = 3.5, 5.5, 9.5


class Seq:
    """PROM + LS323, one tick per call."""

    def __init__(self, rom):
        self.rom = rom
        self.st = [0, 0, 0, 0]      # PROM_address [7],[6],[5],[0]
        self.sr = 0                 # LS323 Q_int
        self.i1 = self.i2 = 1       # RDA_int1 / RDA_int2

    def tick(self, rda, q7=0, q6=0):
        a4 = 0 if (self.i1 == 1 and self.i2 == 0) else 1   # ~(RDA_int1 & ~RDA_int2)
        qa = (self.sr >> 7) & 1
        d = self.rom[(self.st[0] << 7) | (self.st[1] << 6) | (self.st[2] << 5) |
                     (a4 << 4) | (q7 << 3) | (q6 << 2) | (qa << 1) | self.st[3]]
        S1, S0, SL, CLRn = (d >> 0) & 1, (d >> 1) & 1, (d >> 2) & 1, (d >> 3) & 1
        if not CLRn:
            self.sr = 0
        else:
            mode = (S1 << 1) | S0
            if mode == 1:      # shift right: serial (SNS/RDA) into the MSB
                self.sr = ((rda & 1) << 7) | (self.sr >> 1)
            elif mode == 2:    # shift left
                self.sr = ((self.sr << 1) | SL) & 0xFF
        self.st = [(d >> 7) & 1, (d >> 6) & 1, (d >> 4) & 1, (d >> 5) & 1]
        self.i2, self.i1 = self.i1, rda
        return self.sr


def flux(bits, ticks_per_cell=TICKS_PER_CELL):
    """One flux pulse at the start of each '1' cell (~245ns on hardware)."""
    out = []
    for b in bits:
        out += [1 if (b and t == 0) else 0 for t in range(ticks_per_cell)]
    return out


def gcr_stream(sync=4, payload=(0xD5, 0xAA, 0x96, 0xFF, 0xFF)):
    bits = []
    for _ in range(sync):
        bits += [1] * 8 + [0, 0]          # 10-cell self-sync
    for b in payload:
        bits += [(b >> i) & 1 for i in range(7, -1, -1)]
    return bits


def windows(rom, ticks_per_cell=TICKS_PER_CELL, tick_ns=TICK_NS):
    """Return [(byte, hold_us)] for every value the sequencer presents with MSB set."""
    s = Seq(rom)
    hist = [s.tick(r) for r in flux(gcr_stream(), ticks_per_cell)]
    runs, cur, n = [], None, 0
    for sr in hist:
        v = sr if sr & 0x80 else None
        if v == cur:
            n += 1
        else:
            if cur is not None:
                runs.append((cur, n * tick_ns / 1000.0))
            cur, n = v, 1
    if cur is not None:
        runs.append((cur, n * tick_ns / 1000.0))
    return runs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'rtl/P6A.mem'
    rom = [int(l, 16) for l in open(path) if l.strip()]
    if len(rom) != 256:
        print(f"warning: expected 256 entries, got {len(rom)}")

    w = windows(rom)
    got = [f"{v:02X}" for v, _ in w]
    frames = all(m in got for m in ("D5", "AA", "96"))
    print(f"{path}: {len(rom)} entries")
    print(f"frames D5 AA 96 from flux: {'YES' if frames else 'NO'}   presented: {got[:8]}")
    print("\nbyte-valid windows:")
    for v, us in w[:10]:
        print(f"   {v:02X}  held {us:5.2f} us")

    data = [us for v, us in w if v != 0xFF]
    if data:
        lo, hi = min(data), max(data)
        print(f"\ndata-byte window: {lo:.2f}-{hi:.2f} us")
        print(f"6504 needs > {POLL_US_SEARCH} us (search-loop poll) and < {WORK_US} us "
              f"(work after taking a byte)")
        ok = lo > POLL_US_SEARCH and hi < WORK_US
        print("VERDICT:", "OK" if ok else
              f"*** TOO SHORT -- the search loop polls every {POLL_US_SEARCH}us and will "
              f"miss bytes (this is the bug) ***")


if __name__ == '__main__':
    main()
