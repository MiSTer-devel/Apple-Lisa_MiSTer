# Apple Lisa for MiSTer — TODO

Task list for the MiSTer port. See `progress_quartus_handover.md` for the
detailed engineering log and `CLAUDE.md` for architecture/build notes.

## Done (MiSTer port)

- [x] Port LisaFPGA (Xilinx/Vivado) to MiSTer (Cyclone V / Quartus).
- [x] Single-clock + clock-enable architecture (one PLL, strobed enables).
- [x] Fix Vivado→Quartus tri-state hazards (BD_OE, keyboard, ProFile PD, D_SRAM).
- [x] SDRAM: deterministic Lisa-cycle-locked controller (`sdram_lisa.sv`),
      1×/2×/3× CPU speeds.
- [x] Video raster reconstruction: clean, stable 720×364 (fixed the left white bar).
- [x] Keyboard: USB→Lisa adapter with an event FIFO (fixed dropped keys).
- [x] Mouse working.
- [x] ProFile hard-disk emulation over MiSTer HPS block device (`profile.sv`).
- [x] Boots Lisa Office System to the desktop.
- [x] **SDRAM refresh flicker fixed** — slot-boundary refresh + access latch
      (was dropping accesses on interrupt-driven cadence changes).
- [x] **Removed unstable 4× speed** (menu + hardware clamp).
- [x] **F11 = soft power on/off**; clean shutdown parks the ProFile (no disk
      corruption on quit).
- [x] **RTC clock seeding** from the host at boot (COP SetClock driven while the
      CPU is held in reset, so no boot-traffic contention). Year shows 1994 for
      2026 (inherent 16-year Lisa clock epoch).
- [x] **Caps Lock LED** on the host USB keyboard tracks the Lisa's state.
- [x] MiSTer README (credits alexthecat123); F11 power-off warning documented.
- [x] Stripped the clock-debug scaffolding (COP-RAM debug port + freeze, LCRM
      probe, 0x02 read-back, SDRAM ref_mode/collide A-B).
- [x] Renamed project/top/OSD to **Apple-Lisa**.

## Open / next

### Release prep (in progress)
- [ ] Verify the stripped + renamed `Apple-Lisa` build boots cleanly on hardware
      (clock, keyboard, mouse, ProFile, F11, caps lock all still work).
- [x] Populate `Apple-Lisa_MiSTer/` release repo (source + `sys/` + `releases/`
      rbf named `Apple-Lisa_YYYYMMDD.rbf`).
- [ ] Decide whether to ship `verilator/` (351M with disk images) and
      `references/` (574M) — currently excluded from the release copy.
- No LICENSE by design (upstream LisaFPGA has none either).

### Cleanup / polish
- [ ] Strip the remaining JTAG bring-up probes for a lean release build:
      LDBG, LVID, LCPU, LIO, LCOP, LKBD, LMOU, LRAM, LPRO (and their threaded
      ports). Keep all the real fixes. This frees routing/ALMs.
- [ ] Timing closure review (currently relies on the SDC clock-group tweaks).

### Functional bugs / features
- [ ] **Video interference at higher CPU speeds (2×/3×)** — visible screen
      interference/artifacts when overclocked; likely SDRAM refresh/timing margin
      shrinking as the memory cycle shortens. Fine at 1×.
- [ ] **Left video line** — one stray white column at the very left edge (DE
      window / scaler edge artifact, not the line-buffer content). Cosmetic.
- [ ] **COP keyboard misdecode (#10)** — boot COP codes read `0x85,0x87` instead
      of `0x80`(RSTCODE)+`0xBF`(ID). It boots fine now, but this is a latent
      keyboard↔COP serial bit-timing issue from the single-clock conversion.
- [ ] **SCC / FPU clock-enable conversion** — both still run on raw `clk_sys`;
      SCC serial baud rate is therefore wrong. Convert to proper clock-enables.
- [ ] **RTC timezone** — host RTC is seeded in UTC; the Lisa clock therefore
      shows UTC. Optional: apply a configurable local-time offset.
- [ ] Twiggy / floppy support (upstream board feature; not ported).
- [ ] MacWorks / other OS images validation on MiSTer.

## Notes
- Config file: OSD name changed to `Apple-Lisa`, so MiSTer now uses
  `Apple-Lisa.cfg` (default status word still boots at 512 KB — set RAM to 2 MB
  in the OSD, or the video fetches are CAS-inhibited).
- Build: `quartus_sh --flow compile Apple-Lisa` from the repo root.
