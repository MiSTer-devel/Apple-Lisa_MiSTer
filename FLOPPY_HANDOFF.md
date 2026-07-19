# Apple Lisa Sony 400K Floppy — Handoff

**Status (2026-07-18): READ and WRITE both work on real hardware.**
LisaTest 2.2 boots from the emulated floppy, and sectors the Lisa writes persist
into the DiskCopy-4.2 image on the SD card.

Branch `floppy-datafield-debug` in both repos, pushed:
`Apple-Lisa_MiSTer` → `8723cf1`, `LisaFPGA` (outer) → `a39e2aa`.

The blow-by-blow of the six-week read-path hunt — including every dead end, so you
don't re-run them — is in **FLOPPY_DEBUG_HISTORY.md**. This document is the
current state and what to do next.

⚠ **The Quartus evaluation licence expires 2026-07-21.** After that there are no
more hardware builds on this box until it is renewed.

---

## 1. What works

| | State | Evidence |
|---|---|---|
| Read: address fields | ✅ | all error counters (`$48`–`$4F`) zero through a full boot |
| Read: data fields | ✅ | LisaTest 2.2 boots to its UI from floppy |
| Write: decode + buffer | ✅ | tb M6 byte-exact; hw commit of LisaTest's boot scratch write |
| Write: persistence to image | ✅ | `lt22_wr.dsk` md5 changed after that write (`52e5d0c3`→`4afb7b07`) |
| Write-protect | ✅ | follows the mount's `img_readonly` |
| Format / Initialize | ❌ **untested, expected to fail** | see §4 |

## 2. The three read bugs that were fixed (all drive-side)

The Lisa's own FDC (6504 + P6A sequencer + LS323) turned out to be innocent; every
bug was in our emulated drive. Recorded because each has a general lesson.

1. **Serializer byte-boundary pulse, 1 clk late** (`sony_drive.sv`). At a byte
   boundary `shreg` still held the previous byte's bit0 while `load_next` latched
   `enc_odata`, so after any 0-ending GCR byte the next byte's first flux pulse was
   **19 clk wide — narrower than the sequencer's exactly-20-clk sample grid** and at
   ~1/20 of cell phases it fell entirely between samples. The sequencer then absorbed
   the byte's leading `1 0 0` = a 3-bit slip. Cell phase precesses deterministically
   (163 mod 20), which is why track 0 never failed and half of track 1 always did.
   Fix: `load_next ? enc_odata[7] : shreg[7]`.
2. **A spurious zero quad at the head of every data field** (`sony_gcr_encoder.sv`).
   The MacPlus `STATE_DPRE` emitted 4 pipeline-priming bytes that were only valid on
   the Mac because they carried the tail of its zero-tag region. With real Lisa tags
   in the payload they became an all-zero GCR quad, shifting the 699-byte field by
   +4: the 6504 read everything perfectly, then its trailer check landed in the
   checksum bytes → `$49` on every sector → `err_cant_read` → boot error 23.
   Fix: prime the nibbler during `DHDR`'s 4 bytes, `DHDR`→`DATA` directly.
3. **Sync gap too tight** (`sony_drive.sv`). The firmware's `S13cd` deselects RDDATA
   for ~30 CPU cycles between address field and data-mark hunt; the mux steals that
   flux, and re-framing on 10-cell self-syncs failed `find_data_header` about half the
   time (`$48`). Fix: default `sync_cells` 10 → 12.

**Lesson worth keeping:** the testbench masked bug 2 for weeks because its data-field
decoder *sweeps start offsets* — its own output printed `start quad @mark+8` (correct
is `@mark+4`) the entire time. A test that searches for the right answer cannot fail.
The M4d "start quad" print is now the regression check.

## 3. Write path (W1–W4), how it works

`rtl/sony_drive.sv`, all of it below the `WRITE PATH` banner.

- **Decode.** While `_WRQ` is low, WRD edges are quantized against **160-clk write
  cells** (the write clock is 8 sequencer ticks — *not* the drive's 163-clk read
  cell), with a <100 clk debounce so both toggle- and pulse-style encodings decode.
  Byte framing is leading-1, identical to the read sequencer; a byte can complete on
  one of the *zeros*, in which case that edge's 1 seeds the next byte.
- **Parse.** Hunt `D5 AA AD`, take the sector byte, then run the exact inverse of the
  encoder's 6&2 whitening chain (c1/c2/c3) over the 699 GCR bytes. The final partial
  group (699 = 174·4 + 3) carries the last two payload bytes.
- **Commit.** 524 payload bytes are written pairwise into the track buffer's sector
  slot through a loader-wins port mux, gated on `loaded_track == driveTrack`. Per-
  sector `wr_dirty` flags feed the flush.
- **Flush (W4).** ~10 ms after write activity stops (`wr_settle`) and the loader is
  idle, each dirty sector is flushed as up to 4 **read-modify-write** block jobs:
  data block `s_abs` (bytes 84..511 = data 0..427), spill block `s_abs+1`
  (bytes 0..83 = data 428..511), and the 12 tag bytes at `409684 + s_abs*12`
  (1 or 2 blocks). RMW is necessary because DC42's 84-byte header makes sector data
  non-block-aligned. Gated on `disk_in && !wprot`.

**Fitter landmine (cost a full compile):** adding a **4th** `trackbuf` read port for
the flush broke M10K inference — the 8 KB buffer flattened into ~110k combinational
nodes against an 83k device. The flush engine therefore **shares the LBUF debug dump
port** (`dbg_word_sel = FB_PATCH ? fb_raddr : buf_src`). Keep it at three ports.

## 4. Why Initialize/format will not work yet

**The drive synthesizes address fields; it never stores them.** A real format writes
the whole track surface — sync runs, then per sector an address field
(trk/sect/side/format/checksum) *and* a data field. We only persist 524-byte
payloads; address fields are generated on the fly by `sony_gcr_encoder` from
`driveTrack`, the standard interleave and a fixed format byte (`$02`).

Consequences, in the order they will bite:

1. **Data-field writes during a format already work** — they decode and flush like any
   other write. This half of formatting is functional today.
2. **Address-field writes (`D5 AA 96`) are discarded** by the parser. For a *standard*
   format that is harmless redundancy (the firmware writes exactly what we synthesize).
   But anything nonstandard — a different format/volume byte, a different interleave —
   has nowhere to live, so the format's **read-back verify** sees our synthesized
   fields instead, and any difference fails the format.
3. **Write-calibration (`wrcal`) is untested.** The format path writes a test pattern
   and reads it back before formatting. If that pattern is not a normal `D5 AA AD`
   data field but a raw sync/nibble pattern, our parse-only decoder ignores it and the
   read-back returns stale buffer content → `err_cant_wrcal` ($1B → "27").

**Do this first, before writing any code:** drive an Initialize from LOS or LisaTest
with a real mouse and watch `debug/errwatch.tcl` plus `LFL2`. That says which of the
three actually bites; guessing here is exactly the trap §2's history documents.

**Then, if needed:** (a) parse written address fields and keep the per-track
format/volume byte as state feeding the encoder instead of the constant; (b) read
what `wrcal` writes in `refs/lisaio-master/lisaio-sony.asm` and, if it is a raw
pattern, add a read-back echo of the last raw bytes written at that track position.
Both are small next to what is already built.

## 5. Test and debug workflow

```bash
# offline (1 second, catches most regressions) -- OUTER repo
cd /home/alans/mister/LisaFPGA/verilator/tb_sony
./obj_dir/Vtb_sony /path/to/LisaTest22.dsk     # M1-M6 + M6-W4
# rebuild it:
export VERILATOR_ROOT=/home/alans/mister/verilator5
$VERILATOR_ROOT/bin/verilator --cc --exe --build -j 4 -O3 -Wno-fatal -Wno-WIDTH \
  -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -DSIMULATION \
  --top-module tb_sony_top -I../../rtl tb_sony_top.sv ../../rtl/sony_drive.sv \
  ../../rtl/sony_gcr_encoder.sv tb_sony_main.cpp -o Vtb_sony

# build (ALWAYS from Apple-Lisa_MiSTer/; a stale db gives "entity undefined" ->
# rm -rf db incremental_db). ~10 min.
nohup /home/alans/intelFPGA_lite/quartus/bin/quartus_sh --flow compile Apple-Lisa \
  > /tmp/build.log 2>&1 &
sshpass -p 1 scp output_files/Apple-Lisa.rbf root@192.168.1.196:/media/fat/Apple-Lisa.rbf
```

**Keep the two RTL trees in sync** — Quartus builds `Apple-Lisa_MiSTer/rtl/`, the
Verilator sim uses the OUTER `/home/alans/mister/LisaFPGA/rtl/`. `cp` after editing.

### Autonomous floppy-boot repro (no mouse, no user)

```bash
curl -s -X POST http://192.168.1.196:8182/api/launch -H "Content-Type: application/json" \
  -d '{"path":"/media/fat/lisa_floppy_only.mgl"}'     # or lisa_wr_test.mgl (scratch image)
sleep 32
export DE10_IP=192.168.1.196
python3 debug/ws_send.py "kbdRawDown:56" "kbdRawDown:4" "kbdRawUp:4" "kbdRawUp:56"  # Apple+3 = STARTUP FROM
sleep 4
python3 debug/ws_send.py "kbdRawDown:56" "kbdRawDown:3" "kbdRawUp:3" "kbdRawUp:56"  # Apple+2 = boot floppy
```
An MGL launch **resets the LFLP source**, so set any live overrides after launch and
before the trigger. The disk ejects after a failure, so relaunch between runs.
Screenshots work: `POST /api/screenshots`, then `GET` (a list, newest last).

**For write tests use a scratch copy**, never a master:
`cp LisaTest22.dsk lt22_wr.dsk` on the MiSTer (`lisa_wr_test.mgl` points at it).
`*.image` files are pristine masters; `*.img`/`*.dsk` working copies. Every unclean
core reset also dirties the ProFile image, after which LOS boots into a modal dialog
that needs a mouse — refresh `los3_test.img` from `Lisa Office System 3.0.image`
before ProFile runs.

### Probes (`quartus_stp -t debug/read_probes.tcl`)

| Probe | Contents |
|---|---|
| `LFLP` | drive state: driveTrack, loaded_track, disk_present, sel, ld_state, counters; **source** = live tuning (bit_period, pulse_w, phmap, sync_cells, …) via `debug/set_lflp.tcl` |
| `LFL2` | **write path**: `[63:56]`wrq_falls `[55:48]`commits `[47:32]`wrd_edges `[31:16]`gcr_total `[15:8]`fb_flushed `[7:4]`sector `[3]`denib_err `[2]`dirty `[1:0]`wps |
| `LSEQ` | sequencer byte stream: saw_addr / saw_data / saw_depi, valid_cnt, first 4 data-field GCR bytes |
| `L65C` | per-firmware-loop byte accounting (addr loop / data loop, MISS/OK/DUP) |
| `L654` | 6504 PC, q7l reads, `bufwr_cnt`, FD_in vs PSM_out |
| `LBUF` | track-buffer dump (`debug/dump_trackbuf.tcl` + `diff_trackbuf.py`) |
| `LFDR` | FDC RAM dump (`debug/dump_fdcram.tcl` + `analyze_fdcram.py`) |

**`debug/errwatch.tcl <iters> <ms>`** samples the 6504 error counters repeatedly in
one JTAG session. Use it for anything error-related: the counters are re-initialized
per command and wiped by the boot ROM's cleanup command, so **post-mortem dumps of
`$48`–`$4F` always read zero and always mislead**.

ISSP gotcha: `get_insystem_source_probe_instance_info` must be called *before*
`start_insystem_source_probe`; `write_source_data` needs `-value <hex> -value_in_hex`.

## 6. Firmware reference

`refs/lisaio-master/lisaio-sony.asm` — Brouhaha's RE'd 6504 firmware.
**`new_io equ 0` → `hardware_id = $a8` → that is our build; read only the
`if new_io==0` branches.** `iobase = $0400`, ROM at `$1000+`, so a PC from `L654`
maps 1:1 onto the labels. Data register is **`q7l` ($040E)**, not q6l.

Key RAM: `$08` errstat (68000 reads it at offset `$10`), `$18` hardware_id (=A8),
`$26` retry_cnt, `$30-$37` IIOB (what was requested), `$48-$4F` errcnt_tbl,
`$50-$54` hdr_buf (what was decoded), `$01F4-$03FF` the 524-byte sector buffer
(boot signature at `$0204`, must read `AAAA`).

Error codes are shown in decimal: `$17` cant_read → "23", `$14` wprot → "20",
`$1B` cant_setspd → "27", `$15` cant_vfy → "21".

## 7. Before a MiSTer-devel release

1. **Strip the debug instrumentation** — everything marked
   `// DEBUG (… ISSP "L…", remove for release)` plus the threaded ports: `LFLP`,
   `LFL2`, `LSEQ`, `LBUF`, `LFDR`, `L654`, `L65B`, `L65C`, `LDBG`, `LVID`, `LCPU`,
   `LIO`, `LCOP`, `LKBD`, `LMOU`, `LRAM`, `LPRO`. **Keep the real fixes** (the three
   read fixes, the write path, disk_in latch, combinational need_load, `active=sel`,
   `mnt_dly`, write-protect, plus the older non-floppy work: pixel_ce, DE
   reconstruction, SDRAM, tri-state conversions, input fixes).
2. Rebuild, re-verify: ProFile boot to desktop **and** floppy boot of LisaTest.
3. Timing closure is still not met (worst setup −9.28 ns, all inside `rtc_lisa`,
   which settles during reset-hold; the floppy paths meet timing). Worth cleaning up
   but it is not what breaks anything today.
4. Then merge to `main` and publish the rbf under `releases/`.

## 8. Open items, roughly in priority order

- **Format/Initialize** (§4) — the one known-broken floppy feature.
- **LOS write workloads** — saving a document to floppy from the desktop is untested;
  the machinery is generic, but nobody has driven it.
- **Eject/unmount flush** — a dirty sector written <10 ms before an eject may not
  flush. Flushing on `eject_wr` / unmount would close that window.
- **Multi-track write sessions** — the commit is gated on
  `loaded_track == driveTrack`; a head step mid-write drops the sector. Never observed
  (the firmware settles the head first), but it is an unproven assumption.
- Strip probes / release (§7), timing closure, and the older non-floppy items in
  `todo.md` (SCC + FPU clock-enable conversion, RTC UTC→local, COP keyboard
  misdecode #10).
