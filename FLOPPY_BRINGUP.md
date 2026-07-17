# Apple Lisa Floppy (Sony 400K) — Bring-up Continuation Doc

> # ⛔ SUPERSEDED — read `FLOPPY_HANDOFF.md` instead.
>
> This file is kept for history only. Its §1, §6 and §7 are **dead theories** (boot-flow
> event ordering, TACH speed-lock, framing drift, sync-cell tuning) and the "READ THIS
> FIRST" block below is itself out of date — it points at the P6A→6504→FDC RAM chain,
> which has since been narrowed much further.
>
> **`FLOPPY_HANDOFF.md` is the current, authoritative doc:** what is proven correct, the
> dead ends not to repeat, the one open question, and the exact next step.
>
> Still accurate here: §2 (how the emulation is built), §3 (the standalone testbench),
> §5 (the first five hardware bugs and their fixes).

> ## ⚠ Status as of 2026-07-16 (superseded — see FLOPPY_HANDOFF.md)
>
> The boot-flow / TACH / drift / sync theories in §1, §6 and §7 are all **dead**. The floppy
> boots mechanically (head steps, insert IRQ fires, address marks frame). **The emulated drive
> is now proven correct end-to-end; the remaining bug is DOWNSTREAM, in the
> P6A sequencer → 6504 → FDC RAM → 68000 chain** — original Lisa RTL never exercised before
> this project, since the core had no floppy.
>
> Proven this session (all with hard evidence — see the project memory for detail):
> - **Loader is byte-exact ON HARDWARE.** New `LBUF` probe + `debug/dump_trackbuf.tcl` +
>   `debug/diff_trackbuf.py`: track 0 = all 12 sectors, data **and** tags, 6288 bytes, zero
>   mismatches vs the image — including the `AA AA` boot signature at block-0 offset 4.
> - **Framing drift ruled out.** `LSEQ.saw_depi=1`: framing holds through the whole 699-byte
>   data field to its `DE AA` epilogue.
> - **Serializer/flux path verified 524/524** by the new sim test **M4d** (M4c only ever
>   decoded the encoder's `odata`, skipping the serializer; the old "1999/2000" flux mismatch
>   was a tb artifact — its recon desynced on 10-cell sync bytes; fixed).
> - **Not the test image:** the pristine LisaDraw (md5 `89040f41`, staged as
>   `LisaDrawGood.dc42`) is rejected by the OS exactly like the box's damaged copy.
>
> **Next step: instrument the 6504, not the drive.** Probe what the 6504 writes into FDC RAM for
> block 0 (must contain `4E FA 00 0E AA AA`) and/or its RWTS state/checksum result, mirroring the
> `LCPU`/`LPOL` approach on the Arlet core `cpu FDC_6504` (`rtl/IO_board.sv:161`). If FDC RAM
> holds good data the bug is 6504→68000 (FCC0xx shared RAM); if garbage, it's PSM_out→6504.
>
> **⚠ Test-harness gotcha that will waste your time:** every unclean core reset leaves the
> ProFile image dirty, so LOS boots into a modal *"The startup disk was in use when the Lisa
> Failed"* dialog that needs a **mouse** and never reaches the desktop — a run then looks like a
> floppy regression (`saw_addr=0`) when it simply never tried to read. The `*.image` files are
> pristine masters; `*.img` are dirty working copies. **Copy a fresh one before every run:**
> `cp 'Lisa Office System 3.0.image' los3_test.img`. Use `/media/fat/pf_ldgood.mgl`
> (ProFile + floppy on S1 at delay=75) — the mount-at-desktop flow needs no mouse.

Status as of this handoff: **~98% working. Fully verified in simulation; on real
hardware the whole drive emulation works (sense, stepping, recalibrate, loader, flux).
The machine never READ the floppy because of a boot-flow event-ordering trap (see §1):
the ROM only notices a disk INSERTED WHILE the STARTUP dialog is on screen.** Fixes are
in the final compiles; the eject→insert-at-menu test is the remaining validation.

Scope: read-only, Sony 3.5" 400K (Lisa 2/5, `IOROM_A8`), one drive. Write-back and
Twiggy are future phases.

---

## 1. TL;DR — what to do next (UPDATED after firmware analysis)

**The floppy hardware emulation is fine. The machine never tried to read it.**
The 68000 "stuck" at `0xFE2DC6` is the boot ROM's STARTUP FROM dialog waiting for
a keypress/mouse (the sim's `CpuAtStartupFromMenu()` is literally this PC range).
Root cause chain (verified against `refs/lisaio-master/lisaio-sony.asm`, our exact
$A8 firmware, and H-ROM disassembly):

1. The ROM arms the 6504's disk-inserted interrupt mask ONLY when it enters the
   STARTUP dialog (`FE2E2A`: cmd `$86` arg `$88` → `int_mask`).
2. The 6504 only raises the DSKIN flag if mask bit7 is armed at insertion time
   (`S1722` gate in `S14e5`).
3. Our MGL mounted the floppy at +2s — before the dialog — so the insertion event
   was permanently lost. On a real Lisa you insert the disk AT the dialog → FDIR
   interrupt → auto-boot. There is no "always-already-inserted" boot path.

Note: this firmware variant has NO TACH speed-lock (open-loop PWM via Lisa Lite);
the earlier TACH theory was wrong. `step_cnt=8` = a SUCCESSFUL recalibrate
(4 in + 4 out on TK0) — sense path and phmap=0 are proven good.

**Fixes in flight (last compiles of this session):**
- `force_absent` JTAG eject (LFLP source[16]): pulse 1→0 at the menu = fresh
  insertion → should FDIR → auto-boot. Test script: `/tmp/menu_boot_test.sh`.
- hps_io ordering bug fixed: `img_mounted` pulses BEFORE `img_size` is written
  ('h1c then 'h1d transactions), so `disk_in` now latches `img_size!=0` ~0.8ms
  after the pulse (`mnt_dly`). Without this the disk never registers at all.
- OSD unmount now clears `disk_in` (unmount pulse has img_size==0).
- `lisa_floppy_boot.mgl` (delay="35") mounts AFTER the menu appears — the clean
  user-facing flow, mimicking a real insertion at the dialog.

**Success metrics:** `LSEQ.FDIR_ever=1` (interrupt fired), `LSEQ.saw_addr=1`
(sequencer framed D5 AA 96 = real RWTS read), 68000 PC leaves FE2DC0-DF, boots.

### 1a. Latest hardware findings (end of this session)

With the mount + eject fixes flashed, the eject→insert now **re-triggers the 6504's
recalibrate** on hardware (`step_cnt` 8→16) — so the disk-insertion path (`S14e5` →
`S1d54`) definitely runs on insert. BUT `FDIR_ever` stays **0**: the disk-inserted
INTERRUPT to the 68000 never fires. Firmware chain:
`S14e5` raises the DSKIN flag only if `S1722` passes, i.e. `int_mask` bit 7 is armed;
the 6504 asserts the 68000 IRQ by writing `int_68k_ena` ($041f) only when
`int_flags & int_mask != 0`. The 68000 arms `int_mask` bit 7 via cmd `$86` arg `$88`
(ROM `FE2E2A`, reached from `FE2DDE`) — a path taken only on a specific keypress at the
STARTUP dialog. So **the last gate is: get the 68000 to arm the disk-inserted interrupt.**

Next concrete steps (in order):
1. Add a probe reading the 6504 FDC-RAM `int_mask`/`int_flags` bytes (find their zero-page
   addresses by assembling `refs/lisaio-master/lisaio-sony.asm` for hardware_id=$A8, or
   trace `sta int_mask` at asm line 1597/1607 → the store addr). Confirm whether the ROM
   ever arms bit 7. Read FDC RAM via the existing 6504/FDC-RAM path in IO_board.sv.
2. If it never arms: find the keyboard input at the STARTUP dialog that reaches `FE2DDE`
   (disassemble the key handler `FE2D38`/`FE2EA2` and the `d7` bit-17 test at `FE2DD8`).
   Inject it via mrext (`debug/ws_send.py`, host key → COP). The menu is otherwise
   MOUSE-driven and mrext has no mouse.
3. Alternative: patch/short-circuit so a mounted disk auto-arms the interrupt, or so the
   drive raises FDIR on insert regardless of `int_mask` (test-only). This is the fast way
   to PROVE the read path end-to-end (then `saw_addr` should go 1 and it boots).

### 1b. Bugs fixed THIS session (beyond the earlier 5)
- **hps_io mount-ordering bug (`mnt_dly`)**: `img_mounted[1]` pulses in an earlier SPI
  transaction ('h1c) than `img_size` ('h1d), so sampling `img_size` at the pulse always
  read 0 and the disk never registered. Fixed: latch `disk_in <= (img_size!=0)` ~0.8ms
  after the pulse. (Was a regression that also broke OSD mounting.)
- **OSD unmount** now clears `disk_in` (unmount pulse carries `img_size==0`).
- **`force_absent`** JTAG eject added (LFLP source[16], replaces old force_present).
- **LSEQ** extended: [62]=FDIR live, [61]=FDIR_ever sticky; LFLP echo now shows mount
  diagnostics (mnt_seen/img_size_nz/eject_seen/mnt_cnt).

### 1c. Gotchas learned this session
- **MGL `path` must be a BARE filename** (e.g. `path="LisaTest22.dsk"`), NOT
  `games/Apple-Lisa/...` — the latter silently fails to mount (img_size stays 0). MiSTer
  resolves it relative to the core's games dir. Working MGL: `/media/fat/lisa_floppy_only.mgl`.
- Do NOT `killall MiSTer` / manually restart it over ssh — it left the box needing a
  physical power-cycle at the end of this session.
- The 68000 boot ROM has NO TACH speed-lock for the $A8 board (open-loop PWM). Earlier
  TACH/bit_period/pulse/sync sweeps were chasing a non-issue; leave those at defaults.

---

## 2. How the floppy emulation is built

A real Lisa's floppy *controller* (6504 CPU + `IOROM_A8` firmware + P6A GCR state machine
+ LS323 shift register + LS259 latches) already exists and runs inside `rtl/IO_board.sv`.
What was missing is the *drive + media*. We added a virtual Sony drive that sits at the
drive-mechanism boundary (the `*_ESFLOPPY` signals routed through `rtl/top.sv`) and turns
a DiskCopy-4.2 image into the serial GCR read stream (`RDA`).

### New / changed RTL
- **`rtl/sony_drive.sv`** (NEW) — the virtual Sony 400K drive:
  - Drive registers addressed by `{PH2,PH1,PH0,HDS}` (read) / `{PH1,PH0,HDS}`+LSTRB=PH3
    (write); step/direction/motor/eject; `driveTrack`; 5-zone TACH; sense read-back.
  - `disk_in` latch (survives CPU reset). `active = sel | force_motor` (drive spins
    when selected — the Lisa does NOT use the Sony MOTORON register).
  - M10K per-track buffer + SD load engine (2 jobs: data then tags, with DC42 84-byte
    header de-skew and per-zone `soff`). `need_load` is combinational.
  - Byte→serial `RDA` serializer: shifts each GCR byte MSB-first, ~245ns flux pulse per
    `1` bit, 8 cells/byte (10 for self-sync bytes). TACH-gated register mux drives the
    single `rda_serial` line (= RDA = SNS in Sony mode).
  - `LFLP` + `LFL2` JTAG probes and a 32-bit source of live-tunable knobs (see §4).
- **`rtl/sony_gcr_encoder.sv`** (NEW, adapted from `refs/MacPlus_MiSTer/rtl/floppy_track_encoder.v`)
  — on-the-fly 6-and-2 GCR: sync → address field → **524-byte** data field (12 tags +
  512 data, checksum over all 524) → trailer → gap. Outputs `o_sector`/`o_srcoff` (source
  addressing lives in sony_drive), `o_sync` (self-sync byte flag).
- **`Apple-Lisa.sv`** — `S1,...,Mount Floppy` in CONF_STR; `hps_io VDNUM=2`; `sd_*`
  widened to 2 slots (0=ProFile, 1=floppy); floppy ports un-stubbed and `sony_drive`
  instantiated (sibling to `top`/`profile`).
- **`rtl/IO_board.sv`** — added the `LSEQ` probe on `PSM_out` (the byte the P6A sequencer
  assembles from RDA) — see §4.
- **`files.qip`** — added `rtl/sony_drive.sv`, `rtl/sony_gcr_encoder.sv`.

### DC42 image facts
419,284-byte file = 84-byte DC42 header + 409,600 data (800×512) + 9,600 tags (800×12).
The **Lisa requires the 12 tag bytes**; they are 6-and-2 encoded into the data field.
On-disk sector = 12 tags + 512 data = 524 bytes.

### ⚠ Two RTL trees (keep in sync!)
- `Apple-Lisa_MiSTer/rtl/` — used by the **Quartus** build.
- `/home/alans/mister/LisaFPGA/rtl/` (outer) — used by the **Verilator full-system sim**
  (`verilator/sim.v`). When you edit an rtl file, `cp` it to the other tree.

---

## 3. Simulation (fast, fully verifies the data path)

Standalone drive testbench, ~1s/run, no hardware:
```
cd /home/alans/mister/LisaFPGA/verilator/tb_sony
/home/alans/mister/verilator5/bin/verilator --cc --exe --build -j 4 -O3 -Wno-fatal \
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -DSIMULATION \
  --top-module tb_sony_top -I../../rtl tb_sony_top.sv ../../rtl/sony_drive.sv \
  ../../rtl/sony_gcr_encoder.sv tb_sony_main.cpp -o Vtb_sony
./obj_dir/Vtb_sony ../rescue/selector.3.5inch.dc42
```
Verifies (all PASS, 524/524): sense registers, head stepping, TACH, the loader
(data+tags byte-exact vs image across all 5 zones), the GCR address field, an
**inverse-nibbler decode of the data field back to the exact image tags+data**, and the
flux serializer. NOTE: system Verilator is 4.204 (too old for fx68k); the working
**Verilator 5.024 is at `/home/alans/mister/verilator5`** (built from source this session).

The sim cannot reproduce the hardware blocker — it does not model the real 6504
firmware's drive-ready sequence. That is fundamentally a hardware/firmware issue.

---

## 4. Hardware instrumentation (JTAG ISSP)

MiSTer at **<DE10_IP>** (ssh root / pw `<DE10_PW>`), USB-JTAG (DE-SoC, Cyclone V 5CSEBA6 @2).

### Read the probes
```
cd /home/alans/mister/LisaFPGA/Apple-Lisa_MiSTer
/home/alans/intelFPGA_lite/quartus/bin/quartus_stp -t debug/read_probes.tcl 2>/dev/null \
  | python3 debug/decode_lflp.py       # decodes LFLP + LFL2 + LSEQ
```

### Probes
- **LFLP** (in sony_drive): `driveTrack`, `loaded_track`, `raddr` (register the 6504 is
  addressing), `ld_state`, `disk_present`, `motor_on`, `sel`, and counters
  `ph_activity`/`rddata_cnt`/`step_cnt`/`sd_rd_cnt`, plus `load_ever`/`sdack_ever`/`need_load`.
- **LFL2** (in sony_drive): bitmask of every drive register addressed (`reg_seen`) and
  written (`reg_wr_seen`), plus a 4-deep history of recent registers.
- **LSEQ** (in IO_board, on `PSM_out`): the GCR bytes the P6A sequencer decodes from RDA
  (`seq_h0..h3`, newest first), `valid_byte_cnt`, and **`saw_addr`** = did it ever frame
  `D5 AA 96`. **`saw_addr` is the key success metric.**

### Live-tunable source (no recompile) — `debug/set_lflp.tcl`
```
quartus_stp -t debug/set_lflp.tcl <phmap> <bit_period> <force_present> <lstrb_is_hds> \
                                  <force_motor> <pulse_w> <tach_ovr> <flux_invert> <sync_cells>
```
All args optional (0 = RTL default). LFLP source 32-bit layout:
`[8:0]bit_period(0=163) [12:9]pulse_w(x8,0=~245ns) [14:13]phmap [15]flux_invert
[16]force_present [17]lstrb_is_hds [18]force_motor [22:19]sync_cells(0=10) [31:23]tach_ovr(x256,0=zone default)`.
IMPORTANT: `write_source_data` must use `-value <hex> -value_in_hex` (a bare large decimal
is mis-parsed) — already fixed in the script.

### Deploy + launch
```
sshpass -p <DE10_PW> scp -o StrictHostKeyChecking=no output_files/Apple-Lisa.rbf root@<DE10_IP>:/media/fat/Apple-Lisa.rbf
curl -s -X POST http://<DE10_IP>:8182/api/launch -H "Content-Type: application/json" \
  -d '{"path":"/media/fat/lisa_floppy_only.mgl"}'
```
- `lisa_floppy_only.mgl` — floppy on S1 only (forces the floppy boot path; use this).
- `lisa_floppy_test.mgl` — ProFile boot + floppy on S1.
- Floppy image: `/media/fat/games/Apple-Lisa/Lisa Test 2.2.dc42` (a self-booting diag).
- **RAM config must be 0x18 (2MB)** in both `/media/fat/config/LISA.CFG` and
  `Apple-Lisa.cfg`, or the CPU wedges. (Already set.)
- Screenshots don't work for the LISA core — rely on probes (or ask for a photo).

### Build loop
- Syntax check (~2 min): `quartus_map --read_settings_files=on --write_settings_files=off Apple-Lisa -c Apple-Lisa`.
- Full compile (~24 min, detached): `nohup quartus_sh --flow compile Apple-Lisa > /tmp/build.log 2>&1 &`
  then wait for `Full Compilation was successful`. Run from the repo root. If a probe is
  added, confirm it still fits (currently ~77% ALM — comfortable).
- If `build_id.v` is missing during a standalone `quartus_map`, create it:
  `` `define BUILD_DATE "260714" `` (the full compile regenerates it).

---

## 5. The 5 hardware bugs already fixed (context)

All were invisible to sim and found via the probes:
1. **disk-in-place reset-gated** — cleared on `img_mounted` but re-asserted by the Lisa's
   boot reset → drive reported "no disk". Fix: reset-independent `disk_in` latch.
2. **loader never triggered** — `need_load` depended on a pulse/`loaded_track` init that
   didn't hold on hardware. Fix: combinational `need_load = disk_present && track != loaded_track`.
3. **drive never spun** — the Lisa spins the drive when *selected*, not via the Sony
   MOTORON register (firmware left it off). Fix: `active = sel`.
4. **flux pulse too narrow** — ~50ns vs the FDC's ~123–250ns RDA sample interval
   (`IO_board.sv:497` rising-edge detect at `state_machine_clk_enable & c16m_en`). Fix: ~245ns.
5. **no 10-cell self-sync bytes** — added (was an M0 TODO); `o_sync` from the encoder,
   `cells_last` 10 for sync bytes.

Confirmed working after these: phmap=0 correct; 6504 reads all 16 registers; steps &
recalibrates; loader + HPS slot-1 SD path (`sd_rd_cnt`, `sdack_ever=1`); drive spins;
sequencer reads flux (`LSEQ.valid_byte_cnt` → 2400+).

---

## 6. The remaining blocker — full diagnosis

- 68000 (H ROM, status[7]=0) spins at **`0xFE2DC6`**: `move.b $1a(a0),d0 / btst #1,d0 /
  beq $fe2dc6` with `a0=0xfcdd81` → polling VIA bit `0xFCDD9B` bit 1, waiting for the 6504
  to signal floppy-command-complete. (Found via `LPOL` probe = polled addr 0xFCDD9A val 0,
  then capstone disasm of `rtl/CPU_*_H.mem` at base 0xFE0000.)
- The 6504 never signals complete. `LFL2` shows it addresses all 16 drive registers and
  writes DIRTN/STEP/MOTORON; recent sequence cycles through drive-status regs
  (CSTIN/TK0/TACH/WRTPRT/READY/DRVIN/SIDES). It is in the **drive-ready** phase, not a read.
- `LSEQ` shows the sequencer free-running: it decodes only sync-region patterns
  (`FF FE FC F8`, `80…`) and **never** `D5 AA 96` (`saw_addr=0`), across every parameter.
  I.e. the 6504 has not driven the FDC into a byte-framed read — consistent with it being
  stuck at drive-ready, so the sequencer just shifts sync bits.
- Per `brouhaha/lisaio-sony.asm` (fetched this session): the 6504 turns the motor on,
  waits ~80ms, monitors TACH for pulse transitions (~100 iterations), then does a
  **speed-lock calibration comparing measured vs expected zone speed**; only then reads.
  My TACH rate (rescaled from the Mac, tunable) is evidently not accepted.

Exhaustively swept live and NONE satisfied the 6504: `bit_period` 60–500, `pulse_w`
1–15(×8), `tach_ovr` full range, `phmap` 0–3, `flux_invert` 0/1, `sync_cells` 8–13.

---

## 7. Next step in detail — disassemble the 6504 firmware

The blocker is a *firmware* condition, so read the firmware. `rtl/IOROM_A8.mem` is the
Sony I/O ROM (6502/6504 code, 12KB). Disassemble it as 6502 (capstone `CS_ARCH_M68K` is
for the 68000 — use a 6502 disassembler, e.g. `py65`, `capstone` CS_ARCH_... does not do
6502; use `da65`/`disasm6` or python `6502` libs).

What to find and trace:
1. The drive spin-up / speed-lock routine (lisaio labels S1d54 / S1331 / S1e7f / S1d7e).
   Determine exactly how it measures TACH (counts of what clock between which edges) and
   what value/range it compares against for zone 0 (track 0). Then set the TACH period in
   `rtl/sony_drive.sv` (`tachPeriod` table, or via the `tach_ovr` source) to that value.
   Watch `LSEQ.saw_addr`.
2. Whether it also requires the motor-on register or a specific status bit to be set in a
   particular order (it reads/writes MOTORON). Confirm the sense values in
   `rtl/sony_drive.sv sense_reg` match what it expects.
3. Cross-reference the annotated Lisa firmware and the boot-ROM path
   (`bitsavers.org/pdf/apple/lisa/firmware/`). `references/lisaem/src/lisa/floppy/` has the
   command-level interface (FCC0xx shared RAM) but not the low-level 6504 sequencer.

Alternative if the firmware trace is ambiguous: add a probe on the 6504's internal state
(PC or the RWTS state variable in the FDC RAM) so you can see exactly where it loops —
mirror the existing `LCPU`/`LPOL` approach but for the 6504 side (it runs the Arlet 6502
core `cpu FDC_6504` in `IO_board.sv:161`).

Once the 6504 proceeds to read: the sequencer will be driven, sync will frame (the sim
already proves the GCR bytes decode 524/524), `LSEQ.saw_addr` → 1, `rddata_cnt` will climb
into the thousands (full track), and the 68000 should leave `0xFE2DC6` and boot.

---

## 8. Key references
- Plan / progress log: `/home/alans/.claude/plans/can-you-create-a-squishy-bumblebee.md`
- Project memory: `~/.claude/projects/.../memory/floppy-hw-bringup.md`
- Reference cores: `refs/MacPlus_MiSTer/rtl/floppy.v` + `floppy_track_encoder.v` (Sony
  drive + GCR); `refs/Apple-IIgs_MiSTer/rtl/iwm_*.v` (flux-level, secondary).
- 6504 firmware RE: `github.com/brouhaha/lisaio` (`lisaio-sony.asm`).
- FDC internals: `rtl/IO_board.sv` "Page 4" (~lines 143–817); RDA sampling at :497;
  sequencer PROM `rtl/P6A.mem`, shift reg `rtl/LS323_shiftreg.sv`.
- Debug scripts: `debug/read_probes.tcl`, `debug/decode_lflp.py`, `debug/set_lflp.tcl`,
  `debug/decode_probes.py` (LCPU/LPOL/LIO/LCOP).

## 9. Before release (cleanup)
Strip all `LFLP`/`LFL2`/`LSEQ` probes + the `flp_src` source and its tunables; keep the
real fixes (disk_in, combinational need_load, active=sel, ~245ns pulse, 10-cell sync,
524-byte tag encoding, loader de-skew). The DE10 IP / password are placeholders in
`CLAUDE.md` (`<DE10_IP>`, `<DE10_PW>`) — keep them out of committed code.
