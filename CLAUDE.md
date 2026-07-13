# CLAUDE.md — Apple Lisa MiSTer Core

Guidance for working on the Apple Lisa FPGA core ported to MiSTer (DE10-Nano /
Cyclone V). Read this first, plus **progress_quartus_handover.md** (detailed
session log of every fix and its root cause) and **todo.md**.

## What this is

A hardware-accurate Apple Lisa (1 / 2/5) implemented in FPGA, originally
`alexthecat123/LisaFPGA` for Xilinx Artix-7 (Vivado), ported here to the
**MiSTer** framework on **Cyclone V** (Quartus). The core simulates the real
Lisa chip-for-chip: fx68k 68000, 6504/COP421 (I/O + keyboard), 6522 VIAs,
z8530 SCC, AM9512 FPU, MMU, and the video state machine.

- Top: `Apple-Lisa.sv` (the MiSTer `emu` wrapper: hps_io, video/audio out, SDRAM,
  keyboard/mouse adapters, ProFile) → `rtl/top.sv` (the Lisa machine) →
  CPU_board / IO_board / mem_board.
- Framework: `sys/` (MiSTer sys_top, hps_io, ascal scaler, video_freak, etc.) —
  generally do NOT edit; `sys/sys_top.sdc` was tweaked (clock groups).
- Build files: `Apple-Lisa.qsf`, `Apple-Lisa.qpf`, `files.qip` (source list).
  (Project/revision renamed Lisa → Apple-Lisa for the MiSTer-Devel release.)

## Architecture notes that bite you

- **Single clock + clock-enables.** The whole core runs on one 81.50016 MHz
  `clk_sys` (one PLL, `rtl/pll.sv`). Every original Lisa clock (DOTCK, C16M,
  C5M, COPCK, SCCCK, usbclk) is a one-cycle **enable strobe** from
  `rtl/clock_divider.v` (`dotck_en`, `c16m_en`, …). Registers gate as
  `@(posedge clk_sys) if (x_en)`. `dotck_en` is the pixel/CPU rate (~20.4 MHz
  at 1x). SCC and FPU currently run on raw clk_sys (serial baud wrong — see
  todo.md).
- **Vivado → Quartus tri-state hazard (BIG ONE).** The Xilinx design used
  internal tri-state buses / open-collector nets everywhere. **Quartus resolves
  an undriven/`z` internal net to a CONSTANT** (active-high `cond?1'b1:1'bz`
  nets → constant 1; open-collector `?1'b0:1'bz` z-nets → constant 0), unlike
  Vivado which builds proper muxes. This silently broke: all I/O-board reads
  (BD_OE), the keyboard line, the ProFile PD bus, the D_SRAM bus. **Any internal
  `inout`/tri-state from the original design is suspect** — convert to explicit
  in/out + OR (open-collector) or mux (point-to-point). Audit:
  `grep -rn "1'b1 : 1'bz" rtl/` (active-high z-drivers are the hazard).
- **SDRAM.** `rtl/sdram_ctrl.sv` = Sorgelig's proven MiSTer controller (3
  req/ack ports, generates SDRAM_CLK via DDIO). `Lisa.sv` bridges the Lisa
  memory cycle → port 0. The old `rtl/sdram.v` (MiST Minimig) is gone.
- **Video.** The Lisa is 720×364 @ ~60 Hz, 22.75 KHz Hsync, ~895 dots/line —
  NON-standard timing that straddles `_HSYNC`. `Lisa.sv` regenerates a clean
  raster (see the big comment block there and the handover doc). Reliable
  signals: `_HSYNC` (1 clean pulse/line), `VA_overflow` (1 rise/fall/frame,
  high=vblank). UNRELIABLE: `_clr_vid_clk` (~1.5 edges/line — do not use for
  line timing). Live-tunable position via the LVID ISSP source.

## Build / deploy / test loop

```bash
# Project/revision is "Apple-Lisa" (top SV file Apple-Lisa.sv, module `emu`).
# Fast syntax check (~1-2 min):
/home/alans/intelFPGA_lite/quartus/bin/quartus_map --read_settings_files=on \
  --write_settings_files=off Apple-Lisa -c Apple-Lisa 2>&1 | grep -E "Error|successful"

# Full compile (~24 min). Run DETACHED so it survives (the other MiSTer session
# on this box sometimes pkills quartus; nohup keeps it alive):
nohup /home/alans/intelFPGA_lite/quartus/bin/quartus_sh --flow compile Apple-Lisa \
  > /tmp/build.log 2>&1 &
# Watch: until grep -qE "Full Compilation was" /tmp/build.log; do sleep 30; done
# ALWAYS run from the repo root (/home/alans/mister/LisaFPGA). Running from another
# cwd gives "Top-level design entity ... is undefined". If you get a stale
# "entity undefined", `rm -rf db incremental_db` and rebuild.
#
# ROUTING CAPACITY: the design is ~90% ALMs with the debug probes. Adding a probe
# can make it fail to ROUTE (not place) — and the fitter may thrash for HOURS
# before giving up. If you need a new probe, FOLD it into an existing probe's
# spare bits rather than adding a new altsource_probe instance, and/or drop a
# probe you no longer need. Apple-Lisa.qsf has FITTER_AGGRESSIVE_ROUTABILITY_-
# OPTIMIZATION ALWAYS to help. Do a quick `quartus_map` syntax check (~2 min)
# before committing to a full compile.

# Deploy + launch on the DE10-Nano (<DE10_IP>, SSH root/1):
sshpass -p <DE10_PW> scp -o StrictHostKeyChecking=no output_files/Apple-Lisa.rbf \
  root@<DE10_IP>:/media/fat/Apple-Lisa.rbf
curl -s -X POST http://<DE10_IP>:8182/api/launch \
  -H "Content-Type: application/json" -d '{"path":"/media/fat/Apple-Lisa.rbf"}'
```

### Launch with a ProFile disk auto-mounted (MGL — no user needed)

MGL files let you launch the core AND mount a disk yourself. `/media/fat/lisa_profile.mgl`:
```xml
<mistergamedescription>
	<rbf>Lisa</rbf>
	<file delay="2" type="s" index="0" path="games/LISA/Lisa Office System 3.0.img"/>
</mistergamedescription>
```
`type="s"` = mount (into S0 slot), `index="0"` = slot 0. Launch it via the API
`{"path":"/media/fat/lisa_profile.mgl"}`. ProFile images live in
`/media/fat/games/LISA/` and are **532-byte-per-block** raw format (e.g.
`profile.img` = 9728×532 = 5,175,296 bytes); `rtl/profile.sv` does the 532↔512
translation to SD sectors.

### RAM size / speed config without the OSD

The OSD status word defaults RAM to **512 KB**, which CAS-inhibits all video
fetches and wedges the CPU. Write a config file directly (16-byte LE status
word; `0x18` = status[4:3]=11 = 2 MB):
```bash
sshpass -p <DE10_PW> ssh root@<DE10_IP> \
  "printf '\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > /media/fat/config/LISA.CFG"
```

### Screenshots

```bash
curl -s -X POST http://<DE10_IP>:8182/api/screenshots     # take one
# newest is under LISA/ in the list:
curl -s http://<DE10_IP>:8182/api/screenshots
curl -s "http://<DE10_IP>:8182/api/screenshots/LISA/<file>.png" -o shot.png
```
The screenshot renders CLEAN only when video detection is correct; if timing is
off it returns a color-noise thumbnail. The OSD "Video" info line
(width×height) is the authoritative resolution the scaler detected.

**CAVEAT:** `POST /api/screenshots` returns empty for the **LISA core** — MiSTer
framebuffer screenshots only work from the MENU core. So you cannot autonomously
capture the Lisa's screen; rely on the JTAG probes for ground truth (or ask the
user for a photo). The `/api/screenshots` list is sorted oldest-first.

### Autonomous keyboard injection (mrext websocket)

The MiSTer Remote (mrext, port 8182) exposes a **raw websocket** at
`ws://<DE10_IP>:8182/api/ws` that injects keys by **Linux uinput code**:
`kbd:<name>`, `kbdRaw:<code>`, `kbdRawDown:<code>`, `kbdRawUp:<code>`. Helper:
`python3 debug/ws_send.py "kbdRawDown:56" "kbdRawDown:4" "kbdRawUp:4" "kbdRawUp:56"`.
Codes: Alt=56, '1'=2 '2'=3 '3'=4, Enter=28, Esc=1, F12=88 (OSD). **Our adapter
maps host Alt → the Lisa Apple/Command key** (ps2_to_usb_hid), so `Apple+3` =
hold 56, tap 4. Injection is confirmed reaching the CPU (LCOP `so_cnt` climbs).
mrext has **no mouse** injection — keyboard only.

## Debugging on real hardware (JTAG ISSP probes)

The core is instrumented with **In-System Sources & Probes** (`altsource_probe`)
read over the USB-Blaster JTAG ("DE-SoC", device @2) with `quartus_stp`. This is
how essentially every bug this project was found. Scripts live in **debug/**:

- `debug/read_probes.tcl` — dump every ISSP instance (hex).
  `quartus_stp -t debug/read_probes.tcl`
- `debug/decode_probes.py` — pretty-print all probe fields; pipe stp output in:
  `quartus_stp -t debug/read_probes.tcl 2>/dev/null | python3 debug/decode_probes.py`
- `debug/set_vid.tcl <origin_src> <h_de_start>` — live video position trim +
  prints first_w. `debug/set_de_delay.tcl <h_de_start>` — h_de_start only.
- `debug/decode_lpro.py` — decode the ProFile ("LPRO") probe.
- `debug/ws_send.py` — mrext keyboard injection (see below).

**ISSP API gotcha:** `get_insystem_source_probe_instance_info` MUST be called
BEFORE `start_insystem_source_probe` (see the scripts).

### The probes and what they tell you (all instance_id "L…")

| Probe | Module | Reports |
|-------|--------|---------|
| LDBG | debug_issp.sv | pll_locked, ON, reset, frame counters; source can force speed/on |
| LVID | Lisa.sv | video raster: first_w (want 720), n_lines (364), first_de_pos; source = live video position trim (LVI2 was removed to free routing) |
| LCPU | CPU_board.sv | last program-fetch PC, bus-error count, halt/reset, the HDER/SFER/NMI/IPL error chain |
| LIO | IO_board.sv | **repurposed for ProFile-enable diagnosis** (was kbd-VIA error-50): `[63:48]`pen_fall_cnt `[47:32]`cmdu_edge_cnt `[31:24]`kv_wr `[23:16]`kv_rd `[15:8]`pp_io_nz `[7]`_ProFile_EN `[6]`_CMD_ungated `[5]`_CMD `[4]`_PSTRB `[3:0]`cmd_while_en |
| LCOP | IO_board.sv | COP↔CPU handshake; **`[63:32]` = first 4 boot keycodes kc0..kc3** (latched at DATA_QUEUED — kc0 should be 0x80 RSTCODE; a fresh boot currently shows 0x85,0x87 = the keyboard-misdecode bug), `[31:24]`so_cnt `[23:16]`kbdin_cnt |
| LKBD / LMOU | Lisa.sv | keyboard/mouse adapter line + event counters (LKBD kbdsig_edges climbs on injection; LMOU pkt_cnt=0 ⇒ no mouse activity at boot) |
| LRAM | Lisa.sv | SDRAM self-test (want st_rd0=A5C3, st_rd1=5A3C) |
| LPRO | profile.sv | ProFile FSM state + furthest state, command, block#, _CMD/_PSTRB edge counts, SD read-acks, img_mounted, _PRES; `[1:0]` = rst_at_cmd/pres_at_cmd (reset-source latch) |

**Workflow:** reproduce the failure on hardware, read the relevant probe,
compare against the boot ROM listing (below) to locate the exact instruction /
state where it breaks. When a probe reads wrong, add a more targeted probe and
rebuild — don't guess. Measure raw signals with a signal-INDEPENDENT window
before building logic on them (the video saga is the cautionary tale).

### Boot ROM disassembly (find where the CPU is stuck)

The CPU ROMs are in `rtl/CPU_{LOW,HIGH}_{3A,H}.mem` (byte-split, high/low). To
map a PC from the LCPU probe to an instruction:
```python
import capstone
hi=[int(l,16) for l in open('rtl/CPU_HIGH_3A.mem') if l.strip()]
lo=[int(l,16) for l in open('rtl/CPU_LOW_3A.mem') if l.strip()]
rom=bytearray(); [rom.extend((h,l)) for h,l in zip(hi,lo)]
md=capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
for i in md.disasm(bytes(rom[0x4A0:0x520]), 0xFE04A0): print(f"{i.address:06X}: {i.mnemonic} {i.op_str}")
```
The full annotated boot ROM listing is at
`bitsavers.org/pdf/apple/lisa/firmware/Lisa_Boot_ROM_Asm_Listing.TEXT`
(matches our 3A ROM). Error codes: 50 = COPS VIA (EVIA1), 75 = general boot
fail. Lisa source (OS/apps) unpacked under `lisa-source/`.

### Simulation (fx68k etc.)

System Verilator is 4.204 (too old for the fx68k structs). A working Verilator
5.024 is built at `scratchpad/verilator-src/` (use
`VERILATOR_ROOT=…/verilator-src` and flags `--binary --timing -Wno-fatal
-Wno-BLKANDNBLK`). `Date.now`-free. The fx68k VPA testbench that exonerated the
CPU is in the session scratchpad `fxsim/`.

## Status (2026-07-12)

**Boots Lisa Office System to the desktop.** Clean stable 720×364 video (small
left-margin residual); keyboard + mouse work; ProFile hard-disk emulation works;
SDRAM, error-50, tri-state bugs fixed. 1×/2×/3× CPU speeds. Preparing a
MiSTer-Devel release (project renamed **Apple-Lisa**; release repo
`Apple-Lisa_MiSTer/`).

Fixed since the last handover:
- **SDRAM refresh flicker** — was dropping accesses when interrupt-driven cadence
  changes defeated the refresh predictor. Fix: slot-boundary-phase refresh +
  access latch in `sdram_lisa.sv`.
- **4× speed removed** (unstable — memory cycle 1 clk short); menu + hardware clamp.
- **F11 = soft power on/off** (`Apple-Lisa.sv` power logic → `_PWRSW`); clean
  shutdown parks the ProFile.
- **RTC clock seeds from the host** — the COP SetClock sequence
  (`0x2C`/`0x1n`/`0x25`) is driven into the COP by an IO_board sequencer WHILE THE
  MACHINE IS HELD IN RESET (`top.sv` gates reset release on `rtc_seed_done`), so
  the COP bus is idle and the bytes aren't eaten by boot-ROM/OS COP traffic — that
  contention was why every earlier attempt failed. Direct-drives `L_COP_out`
  (extended-DDRA path is `_RESET`-gated during the hold). Clock shows UTC / year
  1994 for 2026 (16-year Lisa epoch). Converter: `rtl/rtc_lisa.sv`.
- **Caps Lock LED** → host USB keyboard via `hps_io.ps2_kbd_led_status`.

**Open (see todo.md):** COP keyboard misdecode #10 (boot codes `0x85,0x87`
vs `0x80`+`0xBF` — latent, boots fine); SCC/FPU clock-enable/baud conversion;
final video centering; strip remaining JTAG probes for release; timing closure;
RTC UTC→local offset.

## Conventions

- Debug instrumentation is prefixed `// DEBUG (… ISSP "L…", remove for release)`.
  Strip all of it (probes + threaded ports) for a clean release build; KEEP the
  real fixes (pixel_ce, DE reconstruction, auto power-on, SDRAM, tri-state
  conversions, input fixes).
- Commit only when asked. Working tree is intentionally dirty beyond `bfd2755`.
