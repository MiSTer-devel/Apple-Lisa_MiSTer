# Apple Lisa Sony 400K Floppy — Debug History (ARCHIVE)

**This is the historical record of the read-path bug hunt, kept for its dead ends.
For the current state of the floppy see FLOPPY_HANDOFF.md.**


**STATUS 2026-07-17: SOLVED — LisaTest 2.2 boots from the emulated floppy at all RTL
defaults.** Three bugs, all in the DRIVE side (the FDC/6504/P6A chain was innocent):
1. `sony_drive.sv` serializer: byte-boundary flux pulse 1 clk late → 19-clk wide →
   intermittently vanished in the sequencer's exact-20-clk sample grid → 3-bit slips
   (the track/sector-deterministic addr-field `$4F` errors). Fixed: pulse uses
   `load_next ? enc_odata[7] : shreg[7]`.
2. `sony_gcr_encoder.sv`: leftover MacPlus STATE_DPRE emitted a spurious all-zero GCR
   quad at the head of every data field (+4-byte payload shift → trailer check landed
   in the csum → `$49` on every sector; the tb's offset-sweeping decoder masked it —
   its own output said "start quad @mark+8", correct is @mark+4). Fixed: nibbler primes
   during DHDR, no DPRE.
3. `sony_drive.sv`: sync_cells default 9→11 (12-cell self-sync) — the firmware's S13cd
   RDDATA re-select between addr and data fields costs ~1 sync byte of re-framing;
   10-cell syncs made find_data_header time out half the time (`$48`).
The P6A PROM swap (§4) is MOOT. §2's per-byte loss numbers were instrumentation
artifacts (fixed: MSB-rise events + 1-tick snapshot). Historical content below.

**Original handoff (superseded):**
**Read §1 and §2 before touching anything. Most of the obvious theories are already dead.**

Branch: `floppy-datafield-debug` (both repos, see §9). Working trees clean.
Supersedes `FLOPPY_BRINGUP.md`, whose §1/§6/§7 are dead theories — do not act on them.

---

## 1. The one-paragraph version

The virtual Sony drive works. It is proven byte-exact from the DC42 image all the
way to the flux line, on real hardware. The Lisa's own floppy controller (6504 CPU
+ P6A sequencer PROM + LS323 shift register, all original LisaFPGA RTL) cannot
reliably read that flux: the 6504 finds address marks, decodes some of them
perfectly, but a large fraction fail their checksum, so it never gets to a data
field. It exhausts its retries, returns `err_cant_read` ($17), and the boot ROM
shows **error 23**. The unexplained fact — the one thing left to chase — is
**why some address fields decode corrupt when clean ones demonstrably exist.**

Nothing in the drive/GCR/image path is suspect any more. The bug is in the FDC
sequencer path in `rtl/IO_board.sv` (lines ~430–520) and/or `rtl/P6A.mem`.

---

## 2. Rules of engagement (things that will waste your time)

**These are settled. Do not re-investigate them without new evidence:**

| Claim | Status | Evidence |
|---|---|---|
| SD loader / DC42 offsets / track buffer | **CORRECT on hardware** | `LBUF` probe dumped track 0: all 12 sectors, data **and** tags, 6288 bytes, zero mismatches vs the image, including `AA AA` at block-0 offset 4 |
| GCR encoder + serializer + flux | **CORRECT** | tb passes 524/524 byte-exact via the **flux** path (test M4d) |
| Framing / drift over the data field | **NOT the bug** | `LSEQ.saw_depi=1`: framing holds through the whole 699-byte field to its `DE AA` epilogue |
| Track numbering / addressing | **CORRECT** | 6504 requested trk2/sect4 while the drive presented trk2/sect4; `$4E` wrong-track = **0** |
| Address-field content/format | **CORRECT** | `hdr_buf` decoded `trk=02 sect=0A side=00 fmt=02 csum=0A`; `2^10^0^2 = 0x0A` → XOR of all five = 0 = valid |
| `bit_period` (flux rate) | **163 = 2.000µs/cell is CORRECT** | 250 was tried live: framing collapsed (`saw_addr` 1→0). Earlier sessions swept 60–500 for nothing. **Do not sweep it again.** |
| Sequencer clock (4MHz, 8 ticks/cell) | **CORRECT, not tunable** | `sim_p6a.py`: 4 and 16 ticks/cell fail to frame at all |
| "Clear the register on CPU read" | **DEAD — reverted (93b6d9d)** | Measured 84%→34% OK on hw. **Also unfaithful to the schematic**: the PROM sees only `{state, RDA, Q7, Q6, SR_MSB}`; there is **no CPU-read strobe in the real hardware**. Do not resurrect. |
| FD_in mux / address decode / `_PHI2` polarity | **CORRECT** | `FD_in` always equals `PSM_out` at the 6504's sampling instant |
| Apple's Lisa source (CHM release) | **Won't help** | It is OS/apps Pascal only — no 6504 IO ROM, no FDC hardware detail. It is in `Lisa_Source/` (gitignored, non-commercial licence — **never commit it**) |

**Two mistakes I made — don't repeat them:**

1. **Wrapped counters.** I compared two 16-bit counters and "found" 10–30% byte
   loss. They wrap independently; a later sample gave a ratio of 1.90 (impossible).
   Any counter you compare must be saturating or gated to one window.
2. **Believing an error-counter reading without checking a read happened.** Boot/read
   timing is **not reproducible** (one run read by +110s, another never did across
   +165s). **Always confirm `L654.bufwr_cnt > 0` first**, or you are reading stale state.

---

## 3. The open question (start here)

**Why do some address fields decode corrupt while others decode perfectly?**

`$4F` (addr-field checksum errors) saturates at 100, yet I captured a byte-perfect
address field. Both are true at once, so corruption is **intermittent**.

My best theory was "the byte-valid window is too short", and **I now believe that
theory is weak** — I'm recording it honestly rather than handing you a wrong lead:

- Measured window (via `sim_p6a.py`): data bytes hold **4.00–4.25µs**, self-sync `FF`
  holds 8.00µs.
- The **search** loop (`lda q7l / bmi / dex / bne` = 11 cyc = **5.5µs** poll) misses
  bytes — but that is **harmless**: it is only hunting for `D5` and will catch the mark
  on a later pass. The Apple II has the same property (11µs poll vs its 8.5µs window).
- The **address-field read** loop (`ldy q7l / bpl` = 7 cyc = **3.5µs** poll) is *shorter*
  than the 4.25µs window, so it should catch every byte; and the CPU then does ~9.5µs of
  work (longer than the window), so it should not double-read either. **This loop should
  be reliable — which the window theory fails to explain.**

So the global L65C figure (84.1% OK / 9.0% missed / 6.8% duplicated) **conflates the
benign search loop with the critical read loop** and cannot settle anything.

### The next step, concretely

**Split L65C's counters per firmware loop, gated on the 6504 PC** (`dbg_pc_6504` is
already probed and maps 1:1 onto the asm listing — 6504 ROM is at `$1000+`):

- SEARCH loop: PC ≈ `$127B–$1285` → misses here are expected/benign
- ADDRESS-FIELD READ: PC ≈ `$12A4–$12B7` → **this is the one that matters**
- DATA-FIELD READ: its own range (find it in the asm)

**Verdict either way:**
- Address-read loop ~100% OK → **window theory is dead.** Look instead at the RDA
  edge-detect and flux pulse width vs the 250ns tick (`IO_board.sv:512`
  `PROM_address[4] = ~(RDA_int1 & ~RDA_int2)`; pulse is ~245ns ≈ one tick — a jittery
  or double-sampled edge would corrupt bits intermittently), or the denib path.
- Address-read loop shows misses/dups → window theory survives; `rtl/P6A.mem` becomes
  prime suspect (see §4).

---

## 4. The P6A/PROM lead (real, but weakened)

`rtl/IO_board.sv:460` claims the sequencer PROM is *"the EXACT SAME PART used in the
Apple ][ disk controller"* and loads `P6A.mem` (from the upstream Xilinx project,
`references/LisaFPGA/.../ROMs/P6A.mem`). But the schematic calls the part
**U4B-341-0172**, while the Disk II's sequencer is **341-0028** — different numbers.

The arithmetic that made this look damning:

| | Apple II | Lisa |
|---|---|---|
| cell → tick | 4µs → 500ns | 2µs → 250ns |
| PROM's 17-tick hold | **8.5µs** | **4.25µs** |
| CPU search poll | 8µs @1MHz | 5.5µs @2MHz |

**But** bigmessowires.com/2015/02/21/apple-lisa-floppy-emulation/ says the Lisa 2/5
and Lisa 1 use a discrete controller *"similar to the original Woz design for the
Apple II"* (only the 2/10 uses an IWM chip). That supports the original author and
weakens this lead. **Do §3 first** — it tells you whether this matters at all.

No genuine 341-0172 dump exists on this box, in LisaEm, or on bitsavers'
`lisa/firmware/`. If you need one: try bitsavers `lisa/hardware/Lisa_2_10_IO_Board/`
.tif sheets, Ray Arachelian/LisaEm upstream, or the LisaList/lisafaq community.
Our dump starts `18 d8 18 08 0a 0a 0a 0a 18 39 18 39 18 3b 18 3b`.

---

## 5. Tools

### `debug/sim_p6a.py` — offline sequencer model (use this first, it's free)
Tick-accurate model of P6A + LS323, wired per the schematic, **verified to reproduce
hardware** (assembles `D5 AA 96` from raw flux, matching `LSEQ.saw_addr=1`).
Test sequencer changes in **1 second** instead of a 10-minute build + a hardware run
that only sometimes performs a read.
```
python3 debug/sim_p6a.py rtl/P6A.mem     # prints framing + byte-valid windows + verdict
```

### JTAG probes (`quartus_stp -t debug/read_probes.tcl`)
| Probe | Contents |
|---|---|
| `L654` | `[63:48]`PC (6504 ROM `$1000+`, maps onto the asm) `[47:32]`q7l reads `[31:16]`**bufwr_cnt** `[15:8]`FD_in@q7l `[7:0]`PSM_out@q7l |
| `L65B` | `[63:48]`distinct MSB bytes the 6504 saw `[47:32]`times **its own stream** showed `D5 AA 96` `[31:0]`last 4 distinct bytes |
| `L65C` | `[63:44]`**MISSED** `[43:24]`**OK** `[23:4]`**DUP** — per-byte accounting, saturating 20-bit, gated to when the CPU is polling |
| `LSEQ` | `[63]`saw_addr `[62]`saw_data `[61]`saw_depi `[60]`fdir_ever `[47:32]`valid_cnt `[31:0]`dcap0..3 (first 4 GCR bytes after the data mark) |
| `LFLP`/`LFL2` | drive state (driveTrack, loaded_track, disk_present, sel, ld_state, counters) / register-access bitmask |
| `LBUF` | track-buffer dump port (source = 12-bit word index) |
| `LFDR` | **FDC RAM dump** (source = 10-bit addr) — the shared 6504↔68000 RAM |

`bufwr_cnt` is your "did a read actually happen" flag. **524 = exactly one
`clr_data_buf`**, so 1048 = two read attempts with **zero data bytes stored**.

### Dump scripts
```
quartus_stp -t debug/dump_trackbuf.tcl 0 3143 | python3 debug/diff_trackbuf.py <img.dc42> <track>
quartus_stp -t debug/dump_fdcram.tcl  0 1023  | python3 debug/analyze_fdcram.py <img.dc42>
quartus_stp -t debug/set_lflp.tcl <phmap> <bit_period> ... # live tuning; echoes src=0x..
```
ISSP gotcha: `get_insystem_source_probe_instance_info` **must** be called before
`start_insystem_source_probe`. `write_source_data` needs `-value <hex> -value_in_hex`.

---

## 6. 6504 firmware reference (`refs/lisaio-master/lisaio-sony.asm`)

**`new_io equ 0` → `hardware_id = $a8` → THIS IS OUR BUILD.** Only read the
`if new_io==0` branches. `iobase = $0400`. 6504 ROM at `$1000+`. Verified live:
FDC RAM `$18` reads `A8`.

**RAM map** (all confirmed against live dumps):
```
$10-$14 zone_spd   $18 hardware_id(=A8)  $19 max_retry
$20 disk_clamped   $21 motor_on  $22 drv_trk  $23 drv_zone  $25 format_type
$26 retry_cnt      $27 recal_cnt
$2C int_mask       $2E int_pend  $2F int_flags
$30-$37 IIOB: $31 fcn  $32 drv  $33 side  $34 sect  $35 trk     <- what was REQUESTED
$38-$3C addr_mark (= D5 AA 96 DE AA, the expected marks)
$48-$4F errcnt_tbl (EIGHT entries — I originally missed the last three!):
   $48 bitslip data hdr   $49 bitslip data trlr  $4A checksum
   $4B bitslip addr hdr   $4C bitslip addr trlr
   $4D WRONG SECTOR       $4E WRONG TRACK        $4F ADDR FIELD CHECKSUM
   (these SATURATE at 100 — you cannot read rates off them)
$50-$54 hdr_buf: $50 csum  $51 vol/fmt  $52 side  $53 sect  $54 trk  <- what was DECODED
$01F4-$01FF 12 tags | $0200-$03FF 512 data   (the 524-byte sector buffer)
   -> boot signature word is at $0204 and must read AAAA
```
`clr_data_buf` writes **exactly 524 bytes** ($0200,y + $0300,y + 12 at $01F4).

**Data register is `q7l` ($040E), NOT q6l** — q6l ($040C) only sets the soft switch.
(I wasted a build probing the wrong address.) Soft switches = LS259 upper latch
`{Q7, Q6, state_machine_clk, _HDS, PH[3:0]}`, verified to match the firmware map.

**Read loop:**
```
find_addr: ... lda q6l
L127b: inc D5c / bne L125f / dec D5c+1 / beq L12ec(TIMEOUT)
L125f: ldx #$00
L1261: lda q7l / bmi L1286 / dex / bne L1261        ; SEARCH  (11 cyc = 5.5us)
L1286: cmp addr_mark / bne L127b
L128c: lda q7l / bpl L128c / cmp addr_mark+1 / bne L1286
L1297: lda q7l / bpl L1297 / cmp addr_mark+2 / bne L1286
       ldx #$04 / lda #$00
L12a4: sta hdr_csum
L12a6: ldy q7l / bpl L12a6 / lda denib_tab,y / sta hdr_buf,x
       eor hdr_csum / dex / bpl L12a4                ; ADDR READ (7 cyc = 3.5us poll,
       tax / bne L12fb                               ;  then ~9.5us of work)
       ... lda iiob_trk / cmp hdr_trk / bne L1300    ; MISMATCH = SILENT, just re-search
```
`denib_tab = $1100` (ROM). **Error codes** (shown in DECIMAL, hence "23"):
```
$01 badcmd $02 baddrive $03 badside $04 badsect $05 badtrack $06 badmask
$07 nodisk $08 drvdis $09 intpend $0a invfmt $0b romerr $0c bad_int
$14 wprot $15 cant_vfy $16 cant_clamp  $17 CANT_READ(=23)  $18 cant_write
$19 cant_uncl $1a cant_cal $1b cant_setspd $1c cant_wrcal $1f wr_underrun
```

**68000 boot ROM (H ROM, `rtl/CPU_*_H.mem`, base `$FE0000`)** — why only 2 attempts:
```
FE1C3E: move.w $4(a1),d0 / cmpi.w #$aaaa,d0 / beq FE1C6C   ; signature OK
FE1C4E: bsr FE1D70   ; read block 0        (bcs -> FE1C9A error)
FE1C58: bsr FE1D70   ; read block 0 again
FE1C5E: move.w $4(a1),d0 / cmpi.w #$aaaa,d0 / beq FE1C6C
FE1C68: moveq #$26,d0 / bra FE1C9A                         ; give up
FE1D70: ... move.b #$81,(a0)   ; cmd $81 RWTS
FE1D9A: move.b $10(a0),d0      ; <- the 6504's error byte ($17 -> "23")
FE1DAE: bne FE1DF2
```

---

## 7. Build / deploy / test

```bash
cd /home/alans/mister/LisaFPGA/Apple-Lisa_MiSTer
# syntax check (~2 min)
/home/alans/intelFPGA_lite/quartus/bin/quartus_map --read_settings_files=on \
  --write_settings_files=off Apple-Lisa -c Apple-Lisa 2>&1 | grep -E "Error|successful"
# full compile (~8-11 min) — run detached
nohup /home/alans/intelFPGA_lite/quartus/bin/quartus_sh --flow compile Apple-Lisa > /tmp/build.log 2>&1 &
until grep -qE "Full Compilation was successful|Error \(" /tmp/build.log; do sleep 30; done
# deploy  (DE10 at 192.168.1.196, root/1)   ~79% ALM with all probes — fits
sshpass -p 1 scp -o StrictHostKeyChecking=no output_files/Apple-Lisa.rbf root@192.168.1.196:/media/fat/Apple-Lisa.rbf
```
**IMPORTANT — keep the two RTL trees in sync.** Quartus builds `Apple-Lisa_MiSTer/rtl/`;
the Verilator sim uses the OUTER `/home/alans/mister/LisaFPGA/rtl/`. After editing:
`cp rtl/IO_board.sv ../rtl/`.

### Getting a real read to happen (the hard part)
**The OS almost never commands a floppy read on demand.** MGL `pf_ldgood.mgl` (ProFile
on S0 + `LisaDrawGood.dc42` on S1 at delay=75, the mount-at-desktop flow) sometimes
works, sometimes never reads across 165s.

**The RELIABLE trigger is the user**: ask them to boot the floppy **by hand** from the
STARTUP menu (needs a real mouse — mrext has no mouse injection). That always drives
`FE1D70` → cmd `$81`. Then read the probes immediately; state survives the error
(`disk_present` goes 0, the drive ejects).

**Every unclean core reset dirties the ProFile image**, after which LOS boots into a
modal *"The startup disk was in use when the Lisa Failed"* dialog needing a mouse, and
never reaches the desktop — a run then looks like a floppy regression when it never
even tried. `*.image` files are pristine masters; `*.img` are working copies:
```bash
sshpass -p 1 ssh root@192.168.1.196 \
  "cd '/media/fat/games/Apple-Lisa/' && cp 'Lisa Office System 3.0.image' los3_test.img"
```
Screenshots **do** work for this core: `POST /api/screenshots`, then
`GET /api/screenshots` (returns a **list**), newest `Apple-Lisa/*.png` last.

### Success criteria for any fix
1. `L65C` → ~100% OK / 0 missed / 0 dup **in the address-read loop**
2. `$4F` (addr-field checksum) stops saturating; `$48–$4C` start moving (it reached a data field)
3. `bufwr_cnt` **> 2×524** — real data bytes stored, not just clears
4. FDC RAM `$0204` reads **AAAA**
5. It boots.

---

## 8. Reference material (all gitignored — never commit)

`docs/schematics/050-4008-L_floppy_pg4.pdf` = **"LISA FLOPPY DISK CONTROLLER"**, the exact
Page 4 our `IO_board.sv` was transcribed from. Read it:
```
pdftoppm -r 600 -png -f 1 -l 1 docs/schematics/050-4008-L_floppy_pg4.pdf out  # 6202x4275
# LS323 + PROM are at ~(0.52..0.80 W, 0.06..0.34 H); crop with PIL
```
**Schematic-verified** (U3B-74LS323 ↔ U4B-341-0172): PROM `D3→CLR`, `D1→S0`, `D0→S1`,
`D2→SL`, LS323 `QA(8)→PROM A1(2)`, `G2(3)←MA0`, PROM `G1/G2` grounded via R17 47Ω.
All match our RTL. Also: `050-4008-K/H` (full I/O board), `Lisa_Lite/050-4043-A` (the
2/5 Sony adapter), `Lisa_Hardware_Manual_Sep82.pdf`.

`refs/lisaio-master/` = Brouhaha's RE'd 6504 firmware (the workhorse reference).
`Lisa_Source/` = Apple/CHM release — **Apple Academic Licence, non-commercial**; this
repo is headed for a public MiSTer-Devel release, so it must never be committed.

---

## 9. Git state

Branch **`floppy-datafield-debug`** in both repos; both trees clean.

Inner (`Apple-Lisa_MiSTer`), newest first:
```
7e277bf  offline sequencer model (debug/sim_p6a.py) + window analysis
1bb9ec1  gitignore third-party reference material
93b6d9d  REVERT of 3efbb2b
3efbb2b  clear-on-read handshake (UNVALIDATED — measured worse, reverted)
368fd2f  L65C per-byte accounting: 84.1% OK / 9.0% miss / 6.8% dup
d6ebb96  6504 q7l stream detector; fixed two wrong conclusions
798a3e0  L654/L65B: 6504 PC, q7l reads, buffer writes
add6be2  LFDR: FDC RAM dump port
180bf46  Sony drive emulation + hardware instrumentation
```
Outer (`LisaFPGA`) mirrors the RTL: `ddb796e` (revert), `c1a57d4`, `e99c2d4`,
`0e1c222`, `11f0d9a`, `2a98334`, `44ec097` (tb + M4d flux verification).

All probes are marked `// DEBUG (... remove for release)`. **Strip them for release;
keep the real fixes** (disk_in latch, combinational need_load, active=sel, ~245ns flux
pulse, 10-cell self-sync, 524-byte tag encoding, loader de-skew, `mnt_dly`).

⚠ **The Quartus evaluation licence expires 2026-07-21.**

---

## 10. If you only do one thing

Build the **per-loop L65C split** from §3. Every previous attempt to reason from the
global 84/9/6.8 number produced a wrong or unfalsifiable conclusion — including two of
mine. That measurement gives a clean verdict and tells you which half of the remaining
search space to delete.
