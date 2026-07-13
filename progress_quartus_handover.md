# Lisa MiSTer Core - Bring-Up Notes

Target: Cyclone V, DE10-Nano `5CSEBA6U23I7`, Quartus 17.0.2.

## Current Status - 2026-07-09

- **Video is solved** in the simulator and previous hardware bring-up notes. The
  earlier black/white-line and horizontal alignment issues are historical.
- **Simulator RAM is set to 2MB** so Lisa Office System can load. The earlier
  `10727` Lisa OS loader error was memory exhaustion with the smaller simulated
  RAM configuration.
- **The original Xilinx LisaFPGA board did not include a Verilog ProFile disk
  emulator.** It muxed the Lisa parallel-port signals to either a real external
  ProFile connector or the onboard ESP32-based ESProFile emulator.
- **The MiSTer port now has an internal Verilog ProFile emulator**
  (`rtl/profile.sv`). It uses MiSTer/HPS block-device signals on hardware and
  `verilator/sim/sim_blkdevice.cpp` as the Verilator stand-in.
- **Current active issue:** finish Lisa Office System booting from a mounted
  ProFile image through the internal emulator. The loader now runs past the
  former debugger/reboot failure; the captured screen still shows the hourglass
  at frame 626, so the next hardware test should confirm that it also remains
  alive past the old frame-410 reset.
- **The debugger/reboot root cause was an MMU address-latch race.** On `_MALE`'s
  rising edge, `B_L` had already selected the SLR, so A12:A9 captured the SLR
  adder result instead of the SOR result. The OS MMU utility was consequently
  copied to physical `0x001600` while segment 84 mapped it at `0x000800`.
  `rtl/CPU_board.sv` now captures A12:A9 while the SOR phase is active.
- **The fixed Verilator build passes the former crash point.** The MMU utility
  is installed at physical `0x000800`, and runs completed without reset, halt,
  or invalid PC through 850,000,000 cycles/frame 626. At exit the CPU was still
  executing OS code at `0x520850`, with ProFile activity advanced to block
  `0x0C90`.

## Current Verification Loop

```bash
cd verilator
make
./obj_dir/Vemu --headless --boot-profile --skip-ram-test --crash-trace \
  --profile "Lisa Office System 3.0 and Workshop 3.0.image" \
  --cycles 850000000 \
  --status-interval 0 \
  --screenshot /tmp/lisa.ppm
```

Interpretation:

- `PRO{state=1b}` is `profile.sv` waiting in `ST_HPS_READ`.
- `sd_rd=001` should cause the Verilator backend to stream one 512-byte sector
  and assert `sd_ack[0]`.
- If `rdack` advances, the HPS/block-device handoff worked and the next suspect
  is ProFile command/status/data behavior.
- `stat0`/`hdr0` in the headless status line capture the first status bytes and
  first eight block-0 header bytes delivered by the emulator. The LOS 3.0 image
  should begin `hdr0=00000022aaaa8200`; current traces do.
- The LOS 3.0 image is already in physical ProFile interleave order. `LDPROF`'s
  9:1 software interleave maps logical boot blocks to valid checksummed physical
  blocks.
- LisaEm's ProFile emulator is a useful protocol cross-check, but its media
  path is DC42-normalized: it applies `deinterleave5()` before reading the image.
  Do not copy that mapping into the RTL for these raw `.image` files unless the
  simulator gains an explicit DC42/normalized-image mode.

The notes below are historical bring-up details. They are useful for root-cause
context, but the section headings that mention old "current" states should be
read as snapshots from those sessions.

---

## 1. Architecture: single clock + clock enables (committed as `bfd2755`)

The core was converted from six gated/muxed/divided clocks on **3 PLLs** (which
overflowed the Cyclone V PLL budget and would not route) to **one 81.50016 MHz
master `clk_sys`** off a single PLL, with every former clock replaced by a
one-cycle **clock-enable strobe** (`@(posedge clk_sys) if (x_en)`).
- `rtl/pll.sv`: single PLL → `clk_sys` + phase-shifted SDRAM `clk_mem`.
- `rtl/clock_divider.v`: enable generator (`dotck_en`, `c16m_en`, `c5m_en`,
  `copck2x_en`, `sccck2x_en`, `usbclk_en`); DOTCK speed select folded in.
- Converted: top, CPU_board (fx68k `enPhi1/2` gated by `dotck_en`), IO_board,
  mem_board_2mb/512k, usb_*_interface, Lite_Adapter.
- `z8530_scc` (SCC) and `AM9512_FPU` run on raw `clk_sys` (serial/FPU rate
  deferred — non-critical for bring-up). See `todo.md`.

## 2. Historical Hardware Bring-Up Fixes

Found via JTAG instrumentation on the real board. All were pre-existing latent
bugs exposed on the first hardware boot (the core had only ever been simulated).

1. **Never powered on.** `Lisa.sv` tied `_PWRSW` to `1'b1`; the COP only powers
   the machine on when it sees a power-button *falling edge*. Added an auto
   power-on: hold `_PWRSW` high ~0.4 s after config, then pulse it low. → `ON=1`.
2. **Video 4× too fast (80 MHz DOTCK).** The DOTCK speed-select mapping was
   inverted vs. the OSD "CPU Speed 1x/2x/3x/4x" menu (default `00`→80 MHz instead
   of 20 MHz). Fixed the `speed_sel` decode in `rtl/clock_divider.v`
   (`00`→20 MHz … `11`→80 MHz). → 60 fps.
3. **`CE_PIXEL` tied to 1.** With `CLK_VIDEO=clk_sys` (81.5 MHz), the scaler
   sampled pixels 4× too fast → framework saw 1×1. Exposed the DOTCK pixel-enable
   (`dotck_en`) from top as `pixel_ce` and drove `CE_PIXEL` from it (`Lisa.sv`).
4. **Broken DE (data-enable) reconstruction.** The old `Lisa.sv` hack rebuilt DE
   from sync with hardcoded windows (120/840/20/384) that never matched the real
   timing (VGA_DE never asserted). Replaced with a clean **720-wide** window:
   vertical active = `~VA_overflow`; horizontal active armed by `_HSYNC` rising
   and started on the first `_clr_vid_clk` fall each line, held 720 px. Verified
   on hardware: `de_hmax=720`, `de_total≈261590` (720×363). → OSD shows 720×364.
5. **`sys/sys_top.sdc`** clock-group filter fixed (`*|pll|pll_inst|` →
   `*|main_pll|`) so core/framework clocks are declared async (killed false
   timing violations; −39.7 ns → −0.6 ns).

## 3. How to build / deploy / test (the working loop)

```bash
# Build (~24 min)
/home/alans/intelFPGA_lite/quartus/bin/quartus_sh --flow compile Lisa
# Fast syntax check only (~1 min): quartus_map --read_settings_files=on --write_settings_files=off Lisa -c Lisa

# Deploy the .rbf to the MiSTer and launch it via the Remote API
sshpass -p <DE10_PW> scp -o StrictHostKeyChecking=no output_files/Lisa.rbf root@<DE10_IP>:/media/fat/Lisa.rbf
curl -s -X POST http://<DE10_IP>:8182/api/launch -H "Content-Type: application/json" -d '{"path":"/media/fat/Lisa.rbf"}'

# Screenshot: POST to take one, then GET it (the API downscales; OSD resolution is authoritative)
curl -s -X POST http://<DE10_IP>:8182/api/screenshots
curl -s http://<DE10_IP>:8182/api/screenshots        # list; newest path is under LISA/
curl -s "http://<DE10_IP>:8182/api/screenshots/LISA/<file>.png" -o shot.png
```

You can also JTAG-program the `.sof` directly with
`quartus_pgm -c DE-SoC -m jtag -o "p;output_files/Lisa.sof@2"` (device @2 is the
5CSEBA6), but launching the `.rbf` via the API is cleaner (proper HPS/hps_io init).

## 4. Historical Debug Instrumentation

Added for bring-up; read/controlled over JTAG with `quartus_stp`. Some probes
have since moved or been removed during later cleanup. Treat this section as a
map of what existed during the hardware bring-up sessions, not a guaranteed list
of what is compiled into the current tree.

- `rtl/debug_issp.sv` — ISSP instance **"LDBG"**: probe reports pll_locked / ON /
  reset / frame-rate; source can override speed-select and force the core on.
  Referenced from `top.sv` (`u_debug_issp`, ports `pll_locked`, `dbg_speed_*`,
  `dbg_force_on`); listed in `files.qip`.
- `Lisa.sv` ISSP instance **"LVID"** (`u_vid_probe`) — measures DE active area
  (`de_hmax`, `de_total`, `de_ever`).
- Extra ports threaded top↔Lisa for debug: `pll_locked`, `pixel_ce`, `dbg_va`,
  `dbg_clr`.

For a release build, audit the current tree for `debug_issp`, ISSP instances,
and public debug-only ports. Keep the real fixes: `pixel_ce`/`CE_PIXEL`, DE
reconstruction, auto power-on, speed-map fix, SDC fix, explicit bus muxes, and
other Quartus tri-state-resolution fixes.

Reading a probe (needs `package require ::quartus::insystem_source_probe`, and
`get_insystem_source_probe_instance_info` must be called BEFORE
`start_insystem_source_probe`):
```
quartus_stp -t read_video.tcl   # prints LDBG status + LVID de_hmax/de_total/de_ever
```

## 5. Timing

Essentially closed after the SDC fix: worst setup ≈ −0.6 ns, hold ≈ −0.6 ns, on
the `clk_sys` domain (a few paths, likely the SCC/FPU on raw clk_sys). Close with
`set_multicycle_path`/`set_false_path` on those blocks or the deferred SCC/FPU
enable conversion. Details in `todo.md`.

## 6. Current Next Steps

1. Finish ProFile boot validation in Verilator using the 2MB RAM configuration
   and a mounted Lisa Office System ProFile image.
2. If the simulator reaches a Lisa boot error, capture the screenshot and decode
   the exact on-screen error before changing RTL.
3. Once the simulator shows a useful result, test the same ProFile path on FPGA.
4. Audit and remove/gate debug-only probes for a clean release build.
5. Close remaining timing warnings and do the deferred SCC/FPU enable conversion
   described in `todo.md`.

---

## 7. Session 2026-07-06: SDRAM path root-caused and replaced

(Corrected symptom: the screen is **white with one vertical dashed black bar**,
not black-with-white-line. NOTE `top.sv` inverts INVID, so CPU_board runs with
INVID=1 → **VID is inverted**: white = framebuffer bits 0 (uninit SDRAM), and
the black bar is the shift register draining INVID=1 past the last word of each
line. The video path is fine; the boot image is simply never painted.)

Findings/changes this session (all uncommitted, on top of the earlier dirty tree):

1. **Replaced the SDRAM controller.** The old `rtl/sdram.v` was the 2015 MiST
   Minimig controller run out of spec (designed 64 MHz + phase-locked 8 MHz;
   driven at 81.5 MHz + 10.19 MHz with a guessed PLL phase). Now
   `rtl/sdram_ctrl.sv` = Sorgelig's proven MiSTer controller (Genesis_MiSTer),
   3 req/ack ports, generates SDRAM_CLK itself via DDIO (180° from clk_sys) —
   `clk_mem`/PLL phase no longer used. Refresh retuned (600 cyc = 7.36 µs).
   `Lisa.sv` has a new cycle→req/ack bridge: reads issue when RAS+CAS assert;
   writes wait for the 68k byte strobes (UDS/LDS can lag CAS on writes).
2. **SDRAM self-test passes on hardware** (ISSP probe **"LRAM"**, controller
   port 1): writes/reads/retention verified live. LRAM layout (64-bit):
   `{st_rd1[16], st_rd0[16], st_loops[4], st_state[4], lisa_wr_cnt[12], lisa_rd_cnt[12]}`;
   expect st_rd1=0x5A3C st_rd0=0xA5C3.
3. **RAM_SEL trap found:** OSD default status=0 → `RAM Size = 512KB` →
   `mem_board_2mb` silently drops (CAS-inhibits) every access with A19|A20 set —
   including **all video fetches** (video page sits at top of RAM) and the ROM's
   sized stack. Result: CPU ran ~512 writes then wedged; rd/wr counters frozen.
   Board config is written directly (no OSD nav needed):
   `printf '\x18\x00...' > /media/fat/config/LISA.CFG` (16-byte little-endian
   status word; 0x18 = status[4:3]=11 = 2MB), then relaunch the core.
   With 2MB set, video reads + CPU writes run continuously.
4. **CPU hang root-caused via PC probe + boot ROM listing.** ISSP probe
   **"LCPU"** (CPU_board.sv) captures the last program-space fetch address; it
   showed the CPU parked at ROM 0xFE04B2-B6. The bitsavers boot ROM listing
   (`Lisa_Boot_ROM_Asm_Listing.TEXT`, matches our 3A ROM byte-for-byte here)
   identifies that loop as the **"no memory found" dead-end** after memory
   sizing (`MEMSIZ`/`CHKMEM` at 0x446/0x508) finds no RAM at any 128K boundary.
   CHKMEM is a plain write/read-back compare (no parity tricks). Sizing math
   confirmed the old freeze: 4 in-range boundaries x 32 retries x 4 writes =
   the exactly-512 writes seen with RAM_SEL=512KB.
5. **THE ROOT CAUSE (fixed in this working tree): `D_SRAM` was never
   connected in Lisa.sv.** `top` exchanges all RAM data over its tri-state
   `D_SRAM` inout (drives write data when SRAM_BUS_DIR=0, samples read data
   otherwise — top.sv:1141-1146). Lisa.sv passed a bare undriven `D_SRAM` wire
   to top and hooked the SDRAM controller's din/dout to two dangling local
   wires (`DOUT_SRAM`/`DIN_SRAM`). So RAM writes stored a constant and RAM
   reads returned an undriven bus — CHKMEM saw "all bits in error" everywhere
   -> "no memory" -> park loop. This predates the controller swap (the old
   MiST sdram.v hookup had the same dead wiring), so it was **the** video-bug
   root cause all along. Fix: `assign D_SRAM = _OE_SRAM ? 16'bZ : DIN_SRAM;`
   (drive controller read data during reads) and bridge write data sampled
   from `D_SRAM` (top drives it during writes).
6. Diagnostic probes now in: **"LBUS"** (Lisa.sv) — port-level write->read-back
   checker (match/mismatch counters + first mismatch capture); **"LCPU"**
   (CPU_board.sv) — PC + bus-error count + the whole HDER/SFER/NMI/IPL chain
   with sticky flags. NOTE: before the D_SRAM fix, LBUS "passed" vacuously
   (it compared the same dead wires on both sides).
7. Probe scripts in scratchpad: `read_probes.tcl` (dumps all ISSP instances),
   `decode_probes.py` (pretty-prints all fields; pipe stp output into it).
8. If reads turn out flaky after the D_SRAM fix (SDRAM round-trip is ~120-200ns
   after CAS vs ~60-70ns for the original 55ns SRAM), the follow-up fix is to
   gate CDACK_core (CPU_board.sv:1089) for CPU RAM *reads* on the bridge's
   read-data-returned signal, inserting 68k wait states. Not applied yet —
   one variable at a time.

### After the D_SRAM fix (2026-07-06 later): BIG progress

- **The machine boots into ROM diagnostics and DRAWS THE SCREEN**: gray dithered
  desktop + alert + a crossed-out icon with error code **50**. Memory sizing
  passes, RAM read-back verified (LBUS all-match), CPU runs the full test chain.
- **Error 50 = `EVIA1` = COPS VIA (keyboard VIA1) error** — the ROM's VIA1
  timer-latch read/write test (`VIATST`/`VIARW`, listing 0x7B8/0x7D0, looped
  from `VIA1CHK` 0x8B0) fails. Structural lead: the parallel VIA (VIA2, same
  via6522 model) PASSES its identical test, but VIA2 is an async/DTACK device
  while **VIA1 is accessed via the 68k's 6800-style VPA/_VMA/E-clock cycle**
  (IO_board.sv:1142 asserts VPA for kbd-VIA/disk/SCC; CS_KBD_VIA =
  ~_CS_KBD_VIA & ~_VMA). So suspect the fx68k VPA->VMA/E path under the
  single-clock conversion. New ISSP probe **"LIO"** (IO_board.sv) counts
  VPA requests / VMA responses / kbd-VIA reads+writes and captures last
  read/write data + reg address — read it to see which stage is dead.
- **Video formatting fix**: the picture content was correct but horizontally
  rotated (DE window opened on the WRONG _clr_vid_clk edge — the old hack used
  its first FALL after HSYNC, which is the END of active). New DE = _clr_vid_clk
  (high exactly for the 45-word active region) delayed through a dot-rate pipe;
  delay defaults to 18 dots and is **trimmable live over JTAG** via the LVID
  ISSP *source* (5 bits, 0 = use default 18) to center the picture without
  rebuilds.
- MiSTer screenshots decimate 720->230 horizontally (the dithered desktop
  aliases into stripes); judge the picture on the real monitor or fix up the
  scaler config.
- **VIA1 failure narrowed to the write-data path**: LIO probe shows the whole
  VPA->VMA->CS->E chain running (all counters spin), reads return the actual
  T1 latch contents — but the latch holds 0x00 and every captured write shows
  data 0x00. The 0x00 clear-writes land; pattern writes (0xFF..) arrive as
  0x00. I.e. **the CPU write data reaches the kbd VIA as constant zero** via
  BD -> IO_board `IO_D = (A[12] & ~_INTIO & ~READ) ? BD_in[7:0]` (IO_board.sv
  ~1430). LIO now also captures BD_in[7:0] at the exact via6522 write-strobe
  moment (wen & E_neg_phase): zero BD = CPU/top-mux side dead for 6800-style
  cycles; nonzero BD with zero IO_D = the IO_D driver condition.
- **Write-data hunt status (latest)**: at the E-fall strobe of VPA writes,
  CPU_board sees `_DBON=0 (driver on), _SPIO=1, _AS=0` — but `UD_CPU_out[7:0]
  == 0`, i.e. **fx68k's own oEdb carries zero**; and the sticky `bd_nz`
  (any nonzero BD during a kbd-VIA CS write window, over minutes of looping
  0xFF test writes) stays ZERO. Verified: rtl/fx68k.sv + microrom/nanorom are
  byte-identical to upstream alexthecat123/LisaFPGA (which boots on Xilinx),
  and the MiSTer port's IO_board.sv was identical to upstream pre-conversion;
  enPhi/E-strobe conversion is semantically equivalent.
- **fx68k EXONERATED by simulation**: scratchpad/fxsim has a Verilator
  testbench (needs the locally built Verilator 5.024 at
  scratchpad/verilator-src/bin, flags `--binary --timing -Wno-fatal
  -Wno-BLKANDNBLK`; system verilator 4.2 MIS-SIMULATES the Nanod struct!).
  It runs fx68k with Lisa-style enPhi (1-in-4) + combinational VPA decode and
  the exact failing sequence (MOVE.B #0,(A0) then MOVE.B D3,(A0), A0=FCDD8D):
  BOTH writes assert VMA and deliver correct data (00 then FF) at the E fall.
  So the bug is in the Lisa-side wrappers under Quartus. NOTE: the TB also
  found fx68k halts if reset releases so enPhi1 comes first (BeI zero-init
  glitch) — TB releases reset aligned to enPhi2; not our hardware issue.
- Rogue-ack detectors (probe LCPU[4:2]): CDACK_flop / CDACK_core /
  DTACK_latch NEVER assert during VPA cycles — those paths are clean. The
  remaining early-ack path is `_CDACK = ~(CDACK_flop | ~_SPIO)`: **a glitch
  low on _SPIO instantly acks the cycle** (combinationally into fx68k DTACKn)
  and would end the 6800 cycle before its E data phase — matching "0xFF
  writes complete but never coincide with a CS window". Detectors for this
  (LCPU[1:0]: SPIO_low-in-VPA-cycle, earlyack=_CDACK-while-VMA-idle) are in
  that build. If confirmed, chase the _SPIO decode (MMU/MALE latch
  timing, possibly Quartus-vs-Vivado tri-state resolution of the muxed A bus)
  and consider gating the _SPIO ack term with registered/latched decode.
- Housekeeping: two "Top-level design entity Lisa is undefined" build
  failures were caused by running quartus_sh from the scratchpad cwd (chained
  `cd` in the same Bash call). Always launch builds from the repo root.
- **Trace buffer (ISSP "LTRC", CPU_board.sv)**: 128-sample dot-rate ring, JTAG
  re-arm (source bit7 rising), trigger = VPA read-cycle start (source bit6=1
  switches to write trigger), readout source[6:0]=addr. Scripts:
  scratchpad/read_trace.tcl + decode_trace.py. First capture of a VPA WRITE
  showed a TEXTBOOK cycle (AS->VPA(+6dots)->VMA->E->data 0x00 held thru E-fall)
  — and 0x00 is CORRECT: those writes are CLR.B! So writes were never broken;
  the ROM's first compare (read-back of the cleared latch vs 0) fails =>
  **the kbd-VIA READ path to the CPU is the broken direction**. Current build
  traces UD_CPU_in (what the 68k reads) around VPA reads.
- **Config audit vs upstream (README appendix + XDC)**: RAM/SPEED/GPIO(spoof_88
  off)/KBD_SEL/MOUSE_SEL(0=our USB adapters via native lines)/HDD_SRC all
  correct. CPU_ROM_SEL=0 selects **H** (recommended), IO_ROM_SEL=0 selects
  **A8** (recommended) — OSD labels were backwards, now fixed ("H ROM,3A ROM"
  / "A8 ROM,40 ROM"). **INVID was wrong**: upstream REG jumper = pin high,
  we tied 0 -> inverted video. Fixed to `.INVID(1'b1)` in Lisa.sv (boot
  screen is now black-at-poweron; alert boxes white like a real Lisa).

### ERROR-50 ROOT CAUSE FOUND AND FIXED (Quartus 'z-as-1 tri-state resolution)

The LTRC trace at the top-level BD mux showed **BD_OE_CPU and BD_OE_IO stuck
at constant 1**. Cause: `BD_OE_int` in both CPU_board and IO_board was a
`tri0` net with multiple `cond ? 1'b1 : 1'bz` drivers. **Quartus resolves
internal 'z as '1'** (Vivado, the original target, builds priority muxes
instead), so these OE nets synthesized to constant 1: top's BD mux always
selected the CPU board's internal bus (which idles at 0xFF under the same
resolution) and the 68k could NEVER read the I/O board — VIA reads returned
0xFF, the boot ROM's VIA test first compare failed, error 50. VIA *writes*
were always fine (verified by trace). Note the active-LOW z-driver nets
(_VPA/_IAK/_SFER wired-OR) work CORRECTLY under 'z-as-1 (open-collector
semantics), which is why only the read path broke. FIX: replaced all six
BD_OE z-drivers with explicit ORs (CPU_board.sv near MREAD; IO_board.sv
~line 386). Grep pattern to audit any future ports:
`grep -rn "1'b1 : 1'bz" rtl/` (active-high z-drivers are the hazard).

All JTAG debug scripts now live in **debug/** in the repo (read_probes.tcl,
read_trace.tcl + decode_probes.py / decode_trace.py, set_de_delay.tcl) so
they survive session scratchpads.
- **DE reconstruction v2**: raw `_clr_vid_clk`-as-DE made the framework
  mis-detect width (36px screenshots) even though the monitor looked right.
  Reverted to the HSYNC-referenced window (framework-friendly) but opening on
  the first _clr_vid_clk RISING edge (start of active; the old code used the
  falling edge = end of active, which rotated the picture) + JTAG-trimmable
  pipeline delay (LVID source, 0=default 18 dots;
  scratchpad/set_de_delay.tcl <n> sets it live).

### Post-fix status (build 14+): error 50 GONE, boot reaches COPS init

- Confirmed on hardware: BD mux arbitration now correct (LTRC trace shows
  OEIO/OECPU proper, VIA IFR data delivered to the 68k through the whole VMA
  window). The ROM passes memory sizing, RAM test, VIA tests, parity/bus-error
  diagnostics (HDER path exercised with masking), plays boot tones, and parks
  in **ReadCOPS** (listing 0x2DBE): polling VIA1 IFR bit 1 (CA1) for the COP
  keyboard controller's startup byte, which never arrives.
- Next chapter: COP (t420) -> VIA1 handshake. New ISSP probe **"LCOP"**
  (IO_board.sv): SO/ACK edge counters, last L-bus bytes both directions,
  KBD-line activity counters, live {DQ, ACK, _READY, ON, muxsel, kbdrst}.
  The COP definitely RUNS (it handled soft power-on: ON=1), so suspects are
  its SO/L-bus output path, the CA1 edge/PCR config, or the COP firmware
  stuck polling the keyboard line (our usb_keyboard_interface emulates the
  keyboard on the KBD serial line).
- INVID fix + OSD label fixes deployed with the same build.

### Keyboard line root cause (same tri-state disease, opposite polarity)

LKBD/LCOP probes proved NOBODY was driving the keyboard serial line low
(adapter kbd_out_sig=1, IO-side KBD_out=1, VIA PB0 released) yet the shared
net read 0: the internal z-net (Lisa.sv `kbd_serial_wire` + top's `inout KBD`)
resolves to constant 0 under Quartus (no pull-up on internal nets). The COP
saw a permanently jammed keyboard. Meanwhile LCOP shows the COP now queues
its proper 0xFF reset code to the 68k. FIX (build 17): top's `inout KBD`
split into `KBD_line_in`/`KBD_line_out`; Lisa.sv computes the open-collector
wired-AND explicitly (`kbd_serial_wire = kbd_line_out_top & kbd_out_sig`).
NOTE for future ports: ANY internal inout/z-net from the Xilinx design is
suspect on Quartus; convert to explicit in/out + AND (open-collector) or
mux (point-to-point). Audit candidates: ESProFile PD bus, D_SRAM (already
handled), the internal A/BD/MD/IO_D buses (work by accident of one-hot
driver + resolution; watch for weirdness).

### Build 18: ProFile mount + mouse fixes (user-reported)

- **ProFile mount was wired to the wrong MiSTer mechanism**: CONF_STR had
  `F,IMG` (ioctl file download) but profile.sv uses the SD block API
  (sd_lba/sd_rd/sd_wr/sd_buff). Changed to **`S0,IMGVHD,Mount Hard Disk`**
  so the selected image is mounted as a block device. (Future nicety:
  profile.sv has no img_mounted input — it answers the Lisa even with no
  image; gate readiness on img_mounted eventually.)
- **Mouse bytes were mis-mapped**: hps_io ps2_mouse = {[24] toggle,
  [23:16] Y delta (PS/2 Y+ = up), [15:8] X delta, [7:0] flags/buttons
  (bit0=L)}. Old wiring fed the FLAGS byte (negated) as Y and Y-delta bits
  as buttons. Fixed: dx=[15:8], dy=-[23:16], buttons={[2],[1],[0]}.
- Video alignment: still slightly off per user; use debug/set_de_delay.tcl
  N (1..31, 0=default18) live while watching the monitor to center it, then
  bake the winning value into Lisa.sv as the new default.

### Video timing FULLY SOLVED (session 2026-07-06, builds 20-32)

The core boots to the "STARTUP FROM" screen and the video is now a clean,
stable, correctly-detected 720x364 that fills the screen. The long road there,
and the final architecture, in Lisa.sv:

**Root facts (measured on hardware via the LVI2 raw-edge probe, per frame):**
- `_HSYNC` = ~380 edges = exactly ONE clean pulse per line (active AND blank).
  THIS is the only reliable per-line reference.
- `VA_overflow` = 1 rise + 1 fall per frame = clean frame boundary (high during
  vertical blank).
- `_clr_vid_clk` = ~575 edges/frame = NOT one-per-line (toggles ~1.5x/line).
  Do NOT use it for line timing — that was the original bug (it chopped DE into
  extra pulses; earlier reconstructions gave 11/443/517/529-line garbage).
- The Lisa's active video STRADDLES the raw `_HSYNC` pulse (content lives at
  ~[370..lineend)+[0..194) in the _HSYNC-referenced line), so `_HSYNC` cannot be
  used as VGA_HS directly and the DE window truncated past h_de_start~176.

**Final raster generation (all in the pixel_ce / dotck_en domain):**
- Line marker = raw `_HSYNC` rising. A per-line dot counter `hcnt` is reset
  `origin_delay` (=144) dots after `_HSYNC` — i.e. in the blanking GAP between
  the two wrapped content halves — so the 720 active dots become contiguous.
- `VGA_HS` = REGENERATED clean pulse at that origin (hcnt < HS_WIDTH=64), in the
  blank. (Raw _HSYNC as VGA_HS put the sync inside active video.)
- `VGA_DE` horizontal = `hcnt in [h_de_start, h_de_start+720)`, h_de_start=20.
- `VGA_DE` vertical = a FIXED 364-line counter (`vcnt`) clocked by `_HSYNC`,
  anchored to `VA_overflow`'s falling edge (`!dbg_va && va_line`, where
  `va_line` latches dbg_va of the previous line). Using VA_overflow's raw extent
  gave 379-443 lines; the fixed counter guarantees exactly 364.
- `VGA_VS` = regenerated: on `VA_overflow` rising, arm; assert on the NEXT
  `_HSYNC` (a line boundary in the blank), hold 3 lines. (Raw _VSYNC and
  VA_overflow both rise MID-line, which made video_freak/ascal — which reset
  their line counter on the VS edge and measure the first line as the picture
  width — read a partial line, e.g. 1/36/77 px wide.)
- `origin_delay` (source[15:11] x16, def 144) and `h_de_start` (source[10:0],
  def 20) are LIVE-tunable via the LVID ISSP source. Scripts:
  debug/set_vid.tcl <origin_src> <h_de_start> (also prints first_w),
  debug/set_de_delay.tcl <h_de_start>.

**Why the OSD/screenshot kept disagreeing with my probes:** MiSTer's
`video_freak` measures picture width from the FIRST active line after VS only
(`if(!vcpt) hsize<=hcpt`). Any partial/glitch DE line right after VS (from
VA_overflow dropping mid-line, or the free-running hcnt wrapping in the blank
with a stuck v_active) got measured as the width. The fixes above eliminate all
blank-region and partial DE. Verify with LVID `first_w` (want 720) and
`n_lines` (want 364); the API screenshot only renders cleanly once detection is
right (garbage color-noise thumbnail otherwise).

**Also fixed this session:** SDRAM controller swap, D_SRAM bus connection, the
tri-state-resolution disease (BD_OE / keyboard line / ProFile PD bus — Quartus
resolves internal `cond?1:z` nets to constant 1, unlike Vivado; converted all to
explicit OR/mux), error-50 (COPS VIA read path), keyboard + mouse event pulsing
(MiSTer ps2_mouse[24] is a TOGGLE not a strobe), ProFile mount (F,IMG -> S0),
INVID polarity, OSD ROM labels. See git diff. Remaining: strip debug probes
(LVID/LVI2/LCPU/LIO/LCOP/LKBD/LMOU/LRAM/LDBG) for release; close timing; SCC/FPU
enable conversion; confirm ProFile actually boots an OS.

### Historical ProFile boot debugging (session 2026-07-06 late)

Instrumented profile.sv with ISSP probe **"LPRO"** (FSM state / max_state,
command, block#, _CMD/_PSTRB edge counts, SD rd_acks, img_mounted, _PRES) and
drove tests with an **MGL** (`/media/fat/lisa_profile.mgl`, `type="s" index="0"`
mounts the image into S0 — launch via the API, no user needed). Findings:

1. **The ProFile parallel protocol WORKS.** The Lisa's presence check succeeds
   (the ProFile icon appears on the STARTUP FROM screen; LPRO shows one _CMD
   edge). The emulator is healthy.
2. **The Lisa never auto-boots the ProFile — it sits in the STARTUP FROM menu**
   (CPU parked in ReadCOPS at 0xFE2DCA polling for a boot-device selection;
   LPRO max_state stays IDLE, rd_acks=0 — no disk read is ever issued). So the
   disk-read path is currently UNTESTED (the Lisa doesn't try).
3. **Why the menu appears (root cause):** boot ROM logic (Lisa_Boot_ROM listing)
   — `RSTSCAN` (0x9C2) resets the keyboard (RSTKBD 0xAAA pulses VIA1 PB0) then
   immediately polls to consume the keyboard **reset code RSTCODE=0x80** (then
   the ID byte, ≤0xDF, saved as KEYID). If it finds nothing it exits ("may be
   old keyboard"). THEN `KEYSCAN` (0x1214) reads key codes and sets **BTMENU**
   (→ menu) for ANY downstroke key except alpha-lock(0xFD)/mouse-button(0x86).
   The COP presents 0x80 to the Lisa AFTER RSTSCAN gives up, so KEYSCAN reads
   0x80 as a downstroke → BTMENU → menu → no auto-boot. It's a **timing race**
   between the COP's keyboard-reset report and RSTSCAN's poll window.
4. **The keyboard adapter is CORRECT** (verified against the ROM): 0x80=RSTCODE,
   0xBF=US-keyboard ID is exactly the protocol; ps2_key decode
   ([10]toggle/[9]pressed/[8]ext/[7:0]scancode) is right. **The 0x80 originates
   in the COP** (t420), not the adapter: muting the adapter output (kbd_mute,
   LKBD source bit0) leaves the COP still presenting l_out=0x80 and the menu
   still pops. So the fix is NOT in usb_keyboard_interface.
5. **Likely fix direction:** the COP (t420) runs on copck2x_en clock-enables
   (single-clock conversion). Its keyboard-reset-report timing races the ROM's
   RSTSCAN. Either tune the COP enable timing / keyboard-reset response so 0x80
   lands inside RSTSCAN's window, or (workaround) suppress the reset-code path
   during the initial boot scan at the COP/VIA1 level (NOT at the adapter — that
   was tried and does not work). To verify the disk-read path independently,
   select the ProFile from the menu (click the icon, or Apple+3 = boot ProFile,
   0xF2 is the '3' boot key) and watch LPRO max_state / rd_acks advance.

---

## Session update (2026-07-06): injection tooling + ProFile-gate diagnosis

### mrext keyboard injection (autonomous input, no user needed)
The MiSTer Remote (mrext, http://<DE10_IP>:8182) exposes a **raw websocket**
at `ws://…:8182/api/ws` that injects keys via Linux **uinput codes**:
`kbd:<name>`, `kbdRaw:<code>`, `kbdRawDown:<code>`, `kbdRawUp:<code>`.
Helper: `debug/ws_send.py "kbdRawDown:56" "kbdRawDown:4" "kbdRawUp:4" "kbdRawUp:56"`.
Key uinput codes: Alt=56, '1'=2 '2'=3 '3'=4, Enter=28, Esc=1, F12=88(OSD).
**Our adapter maps host Alt → Lisa Apple/Command key** (ps2_to_usb_hid: "Left/
Right Alt → Apple key"), so `Apple+3` = hold 56, tap 4. Verified reaching the
adapter: LKBD `kbdsig_edges` climbs on injection. NOTE: mrext has **no mouse**
injection — keyboard only. The LISA core does **not** support MiSTer framebuffer
screenshots (POST /api/screenshots returns empty; only the MENU core captures),
so Lisa-screen verification still needs the user — but the JTAG probes give
autonomous ground truth.

### Refined root cause: the emulator is NEVER commanded, because `_ProFile_EN` is never asserted
LPRO over a whole boot shows `cmd_edges=1` (that one edge is a power-on-reset
glitch: it hit while the FSM was in ST_RESET, so `max_state` never left IDLE) and
`strb_edges=1`, `rd_acks=0`. The Lisa issues **zero** real ProFile transactions.
Found the gate in IO_board.sv:1024-1027 —
`_CMD = (~_ProFile_EN) ? _CMD_E_sampled : 1'b1;` (same for _PSTRB/DR_W). The
command lines to the emulator are **gated by `_ProFile_EN` = PB2 of the parallel
VIA**. So the emulator sees nothing unless the boot ROM sets PB2 low to enable
ProFile comms. Two possibilities, now under test:
  (a) the STARTUP-FROM menu (0x80/BTMENU, above) blocks the ROM from ever
      running the ProFile boot/scan → PB2 never asserted; OR
  (b) PB2/VIA output path is broken so `_ProFile_EN` never reaches the mux.
Confirmed via ROM listing (WebFetch of Lisa_Boot_ROM_Asm_Listing): BTMENU =
"any key hit other than caps-lock/mouse", and the ProFile boot happens AFTER the
menu decision — so if the menu pops, the ProFile is never tried. CPU is parked in
a cursor/menu-draw loop (~0xFE2DC7-0xFE2DD1, `mulu #$4c` screen-stride calc), i.e.
the interactive STARTUP-FROM dialog. Injected Apple+2/Apple+3 did NOT change
`so_cnt` (COP→CPU keycode count frozen at 180) or the CPU PC — the COP isn't
relaying new keys in this state, so menu navigation via injection is unreliable.

### Added probe LPEN (build in progress) to disambiguate (a) vs (b)
IO_board.sv after the _CMD gate: counts `_ProFile_EN` falling edges
(`pen_fall_cnt`) and raw VIA PB4/`_CMD_ungated` toggles (`cmdu_edge_cnt`), plus
live `_ProFile_EN/_CMD_ungated/_CMD/_PSTRB` levels. Read with the standard
`debug/read_probes.tcl`. Decode: probe[35:20]=pen_fall_cnt, [19:4]=cmdu_edge_cnt,
[3]=_ProFile_EN [2]=_CMD_ungated [1]=_CMD [0]=_PSTRB.
**Interpretation:** pen_fall_cnt==0 ⇒ case (a), fix the 0x80/menu (the Lisa never
even tries the ProFile). pen_fall_cnt>0 but emulator still idle ⇒ case (b),
gating/wiring bug. This is verifiable over JTAG without the screen.

---

## Session update (2026-07-07): ProFile blocker fully root-caused to COP keyboard misdecode

Extensive JTAG-probe bisection (LIO/LPRO/LCOP + mrext keyboard injection) proved:

1. **The Lisa NEVER accesses the ProFile.** LIO's pen_fall_cnt / cmd_edges /
   cmd_while_en are all the SAME single power-on VIA-reset glitch (port_b_out
   defaults to 0 at VIA reset → _ProFile_EN & _CMD momentarily low). After the
   VIA is configured, _ProFile_EN stays high forever — the boot ROM never runs
   the ProFile boot code. So every earlier "the Lisa tried once" reading was a
   reset artifact. (The reset-race and _CMD E-sample-skew theories were both red
   herrings from this glitch; the raw-signal datapath change was reverted.)

2. **Why: the Lisa is stuck in the STARTUP-FROM menu**, which the ROM reaches
   BEFORE the ProFile boot. CPU parked in the menu/cursor-draw loop (~0xFE2DCA).

3. **Why the menu: the COP sends the WRONG keyboard power-up bytes.** LCOP now
   captures the first 4 COP→CPU keycodes (kc0..kc3, latched at DATA_QUEUED
   rising). A fresh boot shows exactly TWO bytes: **kc0=0x85, kc1=0x87** — and
   NO 0x80. RSTSCAN (0xFE09F0) scans COP bytes for RSTCODE **0x80** to init the
   keyboard (0xFE0A1A reads the ID byte after it). It also special-cases 0x87
   and ignores 0x85. Because 0x80 never arrives, RSTSCAN never recognizes the
   reset; the leftover 0x85/0x87 (downstrokes, not alpha-lock 0xFD or mouse
   0x86) reach KEYSCAN (0xFE1214) → sets BTMENU → STARTUP-FROM menu → ProFile
   never booted.

4. **Not the mouse** (LMOU pkt_cnt=0 at boot) and **not the adapter logic** (it
   sends the correct 0x80+0xBF serial reset sequence, verified against RSTSCAN).
   The COP (t420) is MIS-DECODING the adapter's serial keyboard bits: 0x80→0x85,
   0xBF→0x87. This is a **keyboard↔COP serial bit-timing mismatch** introduced by
   the single-clock/clock-enable conversion (COP runs on copck2x_en ~3.9MHz →
   COPCK ~1.95MHz, ÷16 internally; the adapter drives bits at ~21.5µs tuned for
   12MHz usbclk). If the COP samples the (correctly-timed) adapter bits at a
   shifted rate it decodes extra/missing bits.

**Autonomous verification for any fix:** watch LCOP kc0/kc1. Correct = kc0=0x80,
kc1=0xBF → RSTSCAN succeeds → no menu → the Lisa proceeds to boot the ProFile
(then LPRO cmd_edges/max_state/rd_acks will finally advance). No screen needed.

**New reusable tooling (this session):**
- `debug/ws_send.py` — mrext websocket key injection (uinput codes; Alt=Apple).
  Confirmed reaching the CPU (LCOP so_cnt climbs). mrext has NO mouse injection;
  LISA core can't do MiSTer screenshots (only MENU core), so Lisa-screen checks
  still need the user, but JTAG probes give autonomous ground truth.
- LCOP repurposed to capture the first 4 boot keycodes (kc0..kc3).
- LIO repurposed for ProFile-enable diagnosis (pen_fall_cnt/cmdu_edge_cnt/
  cmd_while_en). LVI2 video probe removed (video solved) to relieve routing;
  QSF now has FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS (design ~90% ALM).

**Next fix (needs build-iterations):** tune the keyboard↔COP serial bit timing so
the COP decodes 0x80/0xBF. Candidates: (a) adjust the adapter's bit period in
usb_keyboard_interface.sv to match the COP's sampling, or (b) verify/adjust the
COP copck enable rate. Verify each attempt via LCOP kc0 → 0x80.

## Session update (2026-07-10): ProFile read corruption FIXED; COP misdecode re-diagnosed

### 1. ProFile intermittent read corruption — FIXED (commit 8641607)
The byte-by-byte ProFile parallel-port READ path intermittently delivered a bad
byte → error 10726 ("cant read boot device") or a Line-1111/bus-error crash
mid-read (as early as rd_acks≈15). **Root cause:** the Lisa→drive control signals
`_PSTRB`, `_CMD`, `DR_W` were E-sampled before reaching the ProFile emulator
(`rtl/IO_board.sv`), adding up to ~0.5µs latency. The emulator (clk_sys 81.5MHz)
must put the next data byte on the bus within the host's strobe→next-read window;
when that window occasionally dipped below the E-sampling latency, the Lisa
latched a stale/mid-transition byte. **Fix:** feed the emulator the RAW
(un-E-sampled) `_PSTRB_ungated`/`_CMD_ungated`/`PR_W_ungated`. The reverse-
direction `_BSY`/parity into the Lisa's E-clocked VIA stay E-sampled (they need
it). Matches the ESProFile author's note ("drive must respond to STRB fast —
timings tight at 75MHz"). **Verified on hardware:** two fresh boots read 49 and
151 ProFile sectors cleanly with NO fatal crash (was crashing mid-read before).
Full end-to-end (desktop) proof is gated on the COP menu issue below.

### 2. COP keyboard misdecode — RE-DIAGNOSED (supersedes the 2026-07-07 analysis)
The 906e543 COP-clock fix (copck2x_en doubled to 7.8MHz → COP ck_en 3.9MHz ÷16 =
4.1µs/instruction) **changed the picture**. LCOP kc0..kc3 now reads
**0x85, 0x87, 0x80, 0xBF** — i.e. the correct **0x80 (RSTCODE) and 0xBF (kbd ID)
DO now arrive** (kc2/kc3). So the old "0x80→0x85 / 0xBF→0x87 misdecode, 0x80 never
arrives" hypothesis is WRONG now. New facts:
- `dbg_kbdout_cnt=18` ⇒ the adapter transmitted exactly **2 bytes** (0x80, 0xBF)
  on the serial line. But the COP delivered **4+** bytes to the CPU. So **0x85 and
  0x87 are COP-*generated*, not serial-line misdecodes.**
- Boot-ROM equates (Lisa_Boot_ROM_Asm_Listing): `RSTCODE=$80`, `MSPLG=$87`
  (mouse plugged in), `MSUNPLG=$07`, `MOUSDWN=$86`, `KUNPLG=$FD`. The 0x81–0x89
  range (incl. `$85`=CLRSTAT) are **disk-controller commands, NOT COPS codes** —
  so **0x85 is a genuinely spurious COPS code** (and since keycodes use bit7=1 for
  key-down, 0x85 ≡ "key $05 down"). `0x87` is legit (mouse-plugged).
- **The COP+adapter timing both MATCH the original Vivado design** (COP: ck_en
  3.9MHz ÷16; adapter: usbclk 12MHz, bit widths 188/369 cycles unchanged). So this
  is NOT a gross clock regression.
- RSTSCAN trace of 0x85,0x87,0x80,0xBF gives d4=1 (0x87 "mouse connect, ignore")
  and d3=2 (0xBF stored as ID) → **should NOT set BTMENU** (menu needs d4≥2 via a
  0x87+0x07 pair, or d3=0). So the real menu trigger is in the codes **after kc3**,
  which kc0..kc3 didn't capture.
- **Action:** LCOP extended to capture **8** codes (kc0..kc7); read raw LCOP hex
  = kc0[63:56]…kc7[7:0].

### 3. Menu trigger FOUND (2026-07-10, 8-code LCOP): COP reports keyboard-COPS-RAM error
Full 8-code sequence on hardware: **0x85, 0x87, 0x80, 0xBF, 0x80, 0xEF, 0xFF, 0xFF**.
The boot-ROM STARTUP-menu decision is `MOVE d7,d0; ANDI.L #$183000,d0; BNE $FE1246`.
**$183000 = bits 12,13,19,20** (NOT 23/24 — earlier notes were wrong). In RSTSCAN's
code-handler:
- `CMPI #$FF (KCERR) → BSET #$D` (**bit 13**, IN mask) @0xFE0A3C
- `CMPI #$FE (ICERR) → BSET #$C` (**bit 12**, IN mask) @0xFE0A46
- d3==0 → BSET #$17 (bit 23, NOT in mask); d4≥2 → BSET #$18 (bit 24, NOT in mask)
  ⇒ **the mouse-connect (0x87) and keyboard-ID (0xBF) state do NOT raise the menu.**

So the trigger is **kc6 = 0xFF = KCERR (keyboard COPS RAM error)**: RSTSCAN reads it
during the post-reset code scan → sets bit 13 → BTMENU → STARTUP-FROM menu →
ProFile never booted. (kc0=0x85 "key $05 down" may also hit KEYSCAN, secondary.)

**Refined root cause:** the COP (t420/COP421 firmware) is emitting a **keyboard-
COPS-RAM error (0xFF)** at power-up. `dbg_kbdout_cnt=18` ⇒ the adapter sent only
the 2-byte 0x80/0xBF serial reset; the 0x85/0xEF/0xFF codes are **COP-generated**.
This points at the **keyboard↔COP self-test / RAM-verify handshake** not being
satisfied by `usb_keyboard_interface.sv` (which emulates key *transport* but not
the keyboard unit's power-up self-test that the I/O COP421 firmware expects). This
is a deeper issue than raw bit-timing (COP+adapter timing both match the original
Vivado design). NOT yet fixed — needs understanding the two-COP keyboard self-test
handshake (I/O COP421 ↔ keyboard-unit COP), or a way to make the COP's keyboard-
RAM test pass. **The 8-code LCOP probe is committed for this work.**

**Verification for any COP fix:** LCOP should show **no 0xFF/0xFE** and kc0=0x80;
then the Lisa skips the menu and boots the ProFile (LPRO/LPR2 rd_acks climb into
the hundreds — which also gives the 8641607 ProFile-corruption fix its full
end-to-end stress test).

### 4. COP model RULED OUT as the KCERR cause (2026-07-10, exhaustive audit)
The keyboard misdecode was believed to be a COP serial-timing regression from the
single-clock conversion. **It is NOT in the COP model.** Full audit of every
clocked process in t400_core/clkgen/sio/io_g/io_in/io_l/io_d/alu/decoder/skip/
stack/timer/dmem/pmem + t420_notri wrapper:
- **Every** flop clocks on ck_i but gates on `ck_en_i` (or a derived single-tick
  strobe icyc_en/in_en/out_en). The model is fully clock-enable gated and behaves
  **bit-identically** whether ck_i is 7.8MHz (original) or 81.5MHz (now).
- t400_clkgen counts `ck_en_i` pulses (not ck_i edges) for its ÷16; frequency-
  independent. `ck_en_i = COPCK_clk_enable & copck2x_en` resolves to a correct
  **3.90 MHz single-cycle strobe** — matching the original design's rate.
- The **only** ungated ck_i register is `t400_por` (power-on-reset counter,
  t400_por.vhd:90) — POR pulse shrank 640ns→61ns after the conversion. **Fixed**
  (t420_notri.vhd generic delay_g 4→63, cnt_width_g 3→6, ~773ns) as a correctness
  regression, **but hardware-tested and it did NOT change the COPS sequence** —
  still 85,87,80,BF,80,EF,FF,FF. So the POR is not the KCERR cause either.

**Therefore the KCERR (0xFF) regression is NOT inside the COP** — it is in the
COP's reset-time ENVIRONMENT/INPUTS: the keyboard/mouse serial-line VALUE at the
io_g pins during the COP's power-up self-test, the KBD_mouse mux/reset sequencing,
or the reset-time handshake between usb_keyboard_interface.sv and the COP. (ck_en
jitter is unlikely: it averages out over the 16 ck_en/instruction.) `dbg_kbdout_cnt=18`
(adapter sent only the 2-byte 0x80/0xBF) rules the adapter's *transmit* out; the
next probes should capture the **io_g keyboard/mouse line value + KBD_mouse_mux_sel
timing during the COP's power-up window**, and the COP's keyboard-reset (SK) →
adapter handshake, to see what the COP mis-samples that makes its firmware conclude
"keyboard COPS RAM error".

### 5. KCERR root cause FOUND via original-Vivado diff (2026-07-10): COP RAM inference
The user dropped the original working Vivado tree into `references/LisaFPGA/`.
Exhaustive diff of the keyboard/mouse/COP datapath (top.sv, IO_board.sv, all
t400_*/t420_* COP files, usb_keyboard/mouse_interface) vs current: **the logic is
byte-for-byte identical** (only diffs are clock→enable conversions, commented-out
sim taps `tb_pc_s`/`tb_sa_s`, debug probes, and the ProFile raw-signal change).
The COP firmware (t420_rom.vhd), core, RAM model (generic_ram_ena.vhd), and dmem
ctrl are IDENTICAL. Keyboard bytes 0x80/0xBF **decode correctly** in the COP
output, and muting the adapter still shows the menu — so it is NOT a serial-link
or keyboard-line issue; the COP fails an INTERNAL power-up self-test.

**Root cause = a Quartus-vs-Vivado RAM synthesis difference.** The COP data RAM
(`generic_ram_ena`, 64x4) is `d_o <= mem_q(a_i)` with the write to the SAME a_i in
one clocked process → RTL/Vivado semantics are **read-OLD-data**. The Quartus map
report (Lisa.map.rpt line ~999) shows Quartus inferred it as an **ALTSYNCRAM
"Simple Dual Port"** block RAM with **read-during-write mode "None"** — which can
return NEW/undefined data on a same-address read-during-write. That mismatch fails
the COP firmware's power-up RAM check → it emits **KCERR (0xFF)** → RSTSCAN sets
d7 bit 13 → BTMENU. **Candidate fix:** `attribute ramstyle of mem_q : signal is
"logic";` in generic_ram_ena.vhd forces logic/register implementation with
deterministic read-old-data (matching Vivado). Verified uninferred from block RAM
("RAM logic ... is uninferred due to 'logic' ramstyle", Info 276006).

**Hardware result (ramstyle alone, on b2dbf11):** LCOP STILL showed 85,87,80,BF,
80,EF,FF,FF (the KCERR codes did NOT disappear) — so the "RAM inference causes the
COP self-test to emit KCERR" theory is NOT confirmed as stated. BUT the CPU got
**past the STARTUP menu into OS code** (PC 0x52xxxx, rd_acks=75) for the first
time, then stuck in an OS loop. So ramstyle changed behavior for the better even
though it didn't clear the LCOP codes (mechanism still not fully understood —
possibly the codes are stale-latched, or the RAM change shifted COP timing enough
that RSTSCAN consumes them differently).

### 6. sim vs FPGA divergence + combined fix (2026-07-10)
User confirmed: with `ad80279` ("Fix LOS boot through ProFile write completion")
the **simulator boots LOS**, but the **FPGA does not**. Root of the divergence:
the sim uses the `` `ifdef SIMULATION `` **fake COP shim** (hardcodes 0x80/0xBF,
no self-test) so it never hits KCERR/menu; the FPGA uses the real t420 COP and
IS blocked at the menu. So the two known blockers are SEQUENTIAL and each tool
only sees one:
  1. **COP KCERR → STARTUP menu** (FPGA-only; ramstyle got past it in the b2dbf11
     test). Sim can't reproduce (fake COP).
  2. **Incomplete ProFile WRITE handshake → LOS spins in OS loop** (ad80279's
     ST_WRITE_STATUS_0/1 fix). This is the OS loop the ramstyle test got stuck in.
**Combined build under test: `ad80279` + ramstyle** — hypothesis is ramstyle
clears blocker 1 and ad80279 clears blocker 2, so together the FPGA boots LOS.
Verify: FPGA PC leaves the menu loop AND doesn't stall in the OS write-wait loop.

### 7. BREAKTHROUGH (2026-07-11): generated COP Verilog `t420_notri.v` was missing the ck_en_s driver
Per the user's steer, brought up the Verilator sim to use as a fast debug loop
for the COP. Got it building (4 sim-only fixes: ps2_kbd unpacked-array init,
"Verilator"-prefixed comments read as magic directives, defc.h→missing iwm.h
replaced by `typedef uint32_t word32`, and 3 stale public-signal taps broken by
the MMU-fix RTL). The sim BOOTS with the fake COP (reads ProFile, runs OS code)
and shows kc0=0x80 — confirming the difference from the FPGA is the fake vs real
COP (`ifdef SIMULATION` swaps a behavioral shim for the real t420).

Wired the REAL COP into the sim via a new `SIM_REAL_COP` define (off by default;
IO_board.sv `ifdef SIM_REAL_COP` instantiates t420_notri.v with the .v's port
list — no params, resolve the bidirectional L bus `L_COP_in=(l_o&l_en)|~l_en`).
Also fixed a real sim bug: sim.v pressed the power button at 2^20 (~12ms) vs the
FPGA's 2^25 (~0.41s) — too early for a real COP (fake shim forced ON regardless).

**Root cause the real COP never ran in sim (and why the fake shim exists):** the
VHDL→Verilog translation DROPPED a driver. `rtl/t400_core.vhd:161` has
`ck_en_s <= ck_en_i = '1';` — ck_en_s is the core-wide clock enable fanned out to
all 13 sub-modules' ck_en_i. In `rtl/t420_notri.v`, `wire ck_en_s;` was declared
but never assigned → it floated to 0 → the ENTIRE COP core was frozen (never
executed) under Verilator. Proved via probes: POR releases (por_s 1→0), copck2x_en
pulses, my ck_en_i to the COP pulses (cken_i=119636), but the core's ck_en_s
accumulator stayed 0 and b_s never changed. **Fix:** add `assign ck_en_s = ck_en_i;`
in t420_notri.v after the wire decl (sim-only; the FPGA uses the correct .vhd).
After the fix the COP EXECUTES: b_s churns, ON asserts, CPU runs the boot ROM.

**Still open (next):** with the real COP running, the COP↔CPU handshake isn't yet
delivering codes (so=00, kc=00) — the CPU reaches the boot-ROM screen-draw loop
(pc~0xFE314x) without RSTSCAN receiving COP codes. Need to debug the SO(DATA_QUEUED)
/ SI(READ_ACK) / L-bus handshake between the real COP and VIA1 in sim (candidates:
the L-bus resolution, SO/SK enable handling, or E-sampling/sync). Once the sim
faithfully delivers the boot codes, it can reproduce and debug the FPGA's kc0=0x85
KCERR in the fast loop. All SIM_REAL_COP changes are behind the define / sim-only;
the FPGA build is unaffected. Debug taps (dbg_copck2x_cnt etc. + RCOP print) are
temporary — strip before committing.

## Session update (2026-07-11 cont.): single-source COP, MMU crash, KCERR narrowed

Major progress (all pushed to origin/mister):
- **478fddd — single-source Verilog COP.** The FPGA now compiles the GHDL-generated
  `rtl/t420_notri.v` (with the ck_en_s/io_g_s driver fixes) instead of the ~24 VHDL
  COP files, so FPGA + Verilator sim share ONE COP model. Verified on HW: FPGA-with-
  Verilog-COP delivers the same COPS codes (85,87,80,BF, so_cnt=133) and boots
  identically to the VHDL. `files.qip` comments out the COP VHDL, adds the .v;
  IO_board instantiates t420_notri WITHOUT params (the .v bakes generics in).
- **2781c3a — illegal-address crash FIXED.** The ed1ad06 MMU SOR-phase latch fix was
  only applied to latched_MMU_address[12:9]; the HIGH bits [20:13] kept the old
  level-sensitive latch and could latch the SLR (garbage) adder output -> high
  illegal addresses (0xCC../0xFA.. = 0xFCxxxx I/O addrs with corrupted top bits) ->
  bus-error storm during OS load (FPGA-only; Verilator dodged it). Fixed by capturing
  [20:13] the same edge-triggered SOR-phase way as [12:9] (CPU_board.sv). On HW:
  berr stable at 4, LPOL addr clean 0xFCDD9A, boot reaches the STARTUP menu.

**Reframe:** with the MMU crash fixed, the boot cleanly reaches the STARTUP menu and
WAITS there (the earlier "auto-proceed into OS at 0x52xxxx" was garbage execution
from the MMU corruption). So the STARTUP menu (COP KCERR) is the genuine last boot
blocker, and the keyboard is non-functional (injected keys reach the adapter but the
COP doesn't forward them). Ruled OUT for the KCERR: serial bit-timing (COP receives
0x80/0xBF correctly), the keyboard adapter (matches upstream/main; the RebeccaRGB
change is keymap-only), VHDL-vs-Verilog, MMU, COP RAM inference, the COP<->VIA
handshake (it delivers 133 bytes fine). => The KCERR is the COP421 firmware's
keyboard SELF-TEST emitting 0xFF, a single-clock-conversion regression.

**Tool status / sim SO artifact:** the sim can't yet reproduce the KCERR because the
sim's real COP never asserts SO/SK (delivers 0 bytes vs the FPGA's 133) — a Verilator
issue. Localized precisely: converted the COP SIO to clean SystemVerilog
(`rtl/t400_sio.sv`, faithful translation of t400_sio.vhd, module named t400_sio_0_0
to replace the one removed from t420_notri.v) — the SIO itself is CORRECT (phi1
toggles, sk toggles), but SK/SO stay dead because **en0/en3 (the COP core EN register)
are stuck at 0** in the sim (never written), while on the FPGA en3 IS set (SO works).
So the sim SO fix needs the clean-SV COP conversion to CONTINUE from the SIO to the
core's EN-register logic (t400_io_l / t400_core). The SIO SV is uncommitted (builds
in sim; NOT yet FPGA-validated — it's on the COP critical path, so validate before
committing). `DATA_QUEUED_COP` was marked public_flat_rd in IO_board.sv (Verilator
inlined it once the SIO changed).

**Next:** continue the clean-SV COP conversion to the EN-register module so the sim's
real COP delivers codes (reproduces the KCERR) -> then debug the KCERR fast in sim.
Or attack the KCERR self-test directly on FPGA. The clean-SV COP conversion also
serves the single-source-maintainability goal (retire the GHDL .v eventually).

### Update: SV SIO FPGA-validated — boot now reaches the HOURGLASS
The clean-SV COP SIO (rtl/t400_sio.sv) was FPGA-validated: COP codes identical to
the .v (LCOP 85,87,80,BF, so_cnt=133) AND the boot now gets PAST the STARTUP menu
into the OS load — the screen shows the boot HOURGLASS (furthest ever; the .v-SIO
build had stayed at the menu). So the SV SIO is a net improvement, committed.
CORRECTION to the earlier same-session note: the 0x52xxxx execution with garbage-
looking addresses is NOT a crash — those are the OS's high LOGICAL addresses (the
Lisa physical space is only 21 bits; 0xFC.. I/O is a logical addr routed via the
_IO segment bit, not high phys bits). rd_acks is frozen and the PC loops, so the
new blocker is an OS-LOAD HANG at the hourglass (waiting on something — likely a
ProFile/disk read that doesn't complete), NOT the illegal-address crash and NOT an
MMU high-bit issue. Next: trace what the OS is waiting on at the hourglass.
