// ============================================================================
// sony_drive.sv  --  Virtual Apple Sony 3.5" 400K floppy drive + media
//
// Sits at the Lisa FDC's drive-mechanism boundary (the ESFLOPPY signals routed
// out of top.sv / Apple-Lisa.sv). The Lisa's native 6504 floppy controller +
// P6A/LS323 GCR state machine already live in rtl/IO_board.sv; this module is
// the *drive* that a real Sony would be: it answers the addressable drive
// status/control registers, tracks head position, spins a tachometer, and
// streams an on-the-fly 6-and-2 GCR read bitstream from a DiskCopy-4.2 image on
// the SD card.
//
// Ported/adapted from MacPlus_MiSTer/rtl/floppy.v + floppy_track_encoder.v
// (refs/MacPlus_MiSTer). Key differences from the Mac reference:
//   * The Lisa has NO IWM. Its state machine reads a raw SERIAL flux line, so
//     this module SERIALIZES the encoder's byte stream onto one output bit
//     (rda_serial) instead of the Mac byte / newByteReady handshake.
//   * In Sony mode top.sv ties RDA==SNS to this one wire, so rda_serial is a
//     mux: GCR flux when the RDDATA register is addressed, else the addressed
//     sense-register level (floppy.v:218-220, 1-bit serialized).
//
// STATUS: M0 skeleton -- structurally complete, compiles & fits. The items
// tagged "HW TODO" are the on-hardware bring-up milestones (M1-M6 in the plan):
// confirm the PH<->register bit order, sweep BIT_PERIOD/pulse width, add the
// 12 Lisa tag bytes (524-byte data field), DC42 header/tag de-skew in the
// loader, 10-cell self-sync, and TACH cadence.
// ============================================================================

module sony_drive #(
    // ~2 us bit cell: 2us * 81.50016 MHz ~= 163 clk_sys cycles. Tunable on HW.
    parameter [8:0]  BIT_PERIOD = 9'd163,
    parameter [8:0]  PULSE_W    = 9'd4,     // flux pulse width in clk_sys cycles
    // DiskCopy 4.2 layout for a 400K (single-sided Sony) image:
    // 84-byte header, 409600 data bytes, then 9600 tag bytes.
    parameter [31:0] DC42_DATA_BASE = 32'd84,
    parameter [31:0] DC42_TAG_BASE  = 32'd409684
)(
    input  wire        clk_sys,
    input  wire        reset,          // active high

    // ---- Drive-mechanism boundary (from top.sv, Sony/ESFLOPPY side) ----
    input  wire [3:0]  PH,             // PH0=CA0, PH1=CA1, PH2=CA2, PH3=LSTRB
    input  wire        HDS,            // = SEL (register-address bit 3 + side)
    input  wire        MT0,
    input  wire        MT1,
    input  wire        _DR0,           // drive select 0 (active low)
    input  wire        _DR1,           // drive select 1 (active low)
    input  wire        WRD,            // write data   (ignored: read-only phase)
    input  wire        _WRQ,           // write request(ignored: read-only phase)
    output wire        rda_serial,     // -> top.RDA_ESFLOPPY (RDA == SNS)

    // ---- Media / OSD ----
    input  wire        img_mounted,    // slot-1 mount pulse
    input  wire [63:0] img_size,
    input  wire        img_readonly,   // hps_io: mounted read-only (valid at the mount pulse)
    output wire        disk_present,   // status LED / OSD

    // ---- SD/HPS (slot 1) ----
    output reg  [31:0] sd_lba,
    output reg         sd_rd,
    output wire        sd_wr,          // unused (read-only) -> 0
    input  wire        sd_ack,
    input  wire  [7:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,
    output wire [15:0] sd_buff_din,    // unused (read-only)
    input  wire        sd_buff_wr
);

    assign sd_wr       = 1'b0;
    assign sd_buff_din = 16'h0000;

    // ------------------------------------------------------------------
    // Drive select / register addressing (live-tunable via the LFLP JTAG source
    // during bring-up: phmap picks how PH[3:0]/HDS map to the Sony CA/SEL/LSTRB
    // register-select lines -- the #1 unknown vs the real 6504 firmware).
    //   read addr {CA2,CA1,CA0,SEL}; write addr = read[2:0]; write data = read[3].
    // ------------------------------------------------------------------
    wire       sel   = ~_DR0 | ~_DR1;              // HW TODO(M1): confirm which line
    wire [1:0] phmap;                              // from LFLP source (default 0)
    wire       lstrb_is_hds;                       // from LFLP source (default 0)

    wire [3:0] ra0 = {PH[2], PH[1], PH[0], HDS};   // standard (floppy.v:152)
    wire [3:0] ra1 = {PH[0], PH[1], PH[2], HDS};   // PH order reversed
    wire [3:0] ra2 = {HDS,   PH[2], PH[1], PH[0]}; // HDS as MSB
    wire [3:0] ra3 = {PH[3], PH[2], PH[1], PH[0]}; // PH3 as SEL, HDS unused
    wire [3:0] raddr = (phmap==2'd0)?ra0:(phmap==2'd1)?ra1:(phmap==2'd2)?ra2:ra3;
    wire [2:0] waddr = raddr[2:0];                 // write reg addr = read[2:0]
    wire       wca2  = raddr[3];                   // write data bit (CA2)
    wire       lstrb = lstrb_is_hds ? HDS : PH[3];

    // falling edge of LSTRB latches register writes
    reg lstrb_d;
    always @(posedge clk_sys) lstrb_d <= lstrb;
    wire lstrb_edge = (lstrb == 1'b0) && (lstrb_d == 1'b1);

    // drive register file
    reg [15:0] driveRegs;
    reg [6:0]  driveTrack;
    reg        tach_q;      // TACH kept separate (driven by its own always block)
    reg        disk_in = 1'b0;  // disk-in-place latch (survives CPU reset; see below)
    reg        wprot   = 1'b1;  // write-protect latch (default protected until a mount says otherwise)

    localparam DIRTN   = 4'd0;  // R/W step direction (0=toward 79, 1=toward 0)
    localparam CSTIN   = 4'd1;  // R disk-in-place (1 = no disk)
    localparam STEPR   = 4'd2;  // R stepping(1=done)  W 0=step
    localparam WRTPRT  = 4'd3;  // R 0=write protected
    localparam MOTORON = 4'd4;  // R/W 0=motor on
    localparam TK0     = 4'd5;  // R 0=head at track 0
    localparam EJECT   = 4'd6;  // W 1=eject
    localparam TACH    = 4'd7;  // R tachometer
    localparam RDDATA0 = 4'd8;  // R read data, side 0
    localparam RDDATA1 = 4'd9;  // R read data, side 1

    // ------------------------------------------------------------------
    // Sense register read-back vector (floppy.v:100-117), 400K single-sided
    // ------------------------------------------------------------------
    wire [15:0] sense_reg = {
        1'b0,                  // 15 DRVIN     (0 = drive installed)
        1'b0,                  // 14 INSTALLED (0 = present)
        1'b0,                  // 13 READY     (0 = ready)
        1'b0,                  // 12 SIDES     (0 = single-sided 400K)
        1'b0,                  // 11 unused
        1'b0,                  // 10 SUPERDR   (0 = not a superdrive)
        1'b0,                  //  9 RDDATA1   (served by flux mux)
        1'b0,                  //  8 RDDATA0   (served by flux mux)
        tach_q,                //  7 TACH
        1'b0,                  //  6 switched
        ~(driveTrack == 7'd0), //  5 TK0
        driveRegs[MOTORON],    //  4 MOTORON
        ~wprot,                //  3 WRTPRT (0 = protected; from hps_io img_readonly)
        1'b1,                  //  2 STEP complete
        ~disk_present,        //  1 CSTIN disk-in-place (1 = no disk)
        driveRegs[DIRTN]       //  0 DIRTN
    };

    // Disk-in-place is a PHYSICAL property of the drive: it is set when an image
    // is mounted and must SURVIVE the Lisa CPU reset (which pulses sony_drive's
    // `reset` repeatedly during boot). Gating it on `reset` made the drive report
    // "no disk" after the first boot reset. Cleared only by an eject.
    wire eject_wr = sel && lstrb_edge && (waddr == EJECT[2:0]) && wca2;
    // img_mounted pulses for BOTH mount and unmount, but hps_io delivers
    // img_size in a LATER SPI transaction ('h1c mount pulse, then 'h1d size),
    // so img_size is stale during the pulse. Latch the event and evaluate
    // img_size ~0.8ms later, when it is valid.
    reg [16:0] mnt_dly = 17'd0;
    // mount diagnostics for the LFLP probe
    reg        mnt_seen = 1'b0, eject_seen = 1'b0;
    reg [1:0]  mnt_cnt  = 2'd0;
    reg        img_mounted_d = 1'b0;
    wire       img_size_nz = (img_size != 64'd0);
    always @(posedge clk_sys) begin
        img_mounted_d <= img_mounted;
        if (img_mounted && !img_mounted_d) begin mnt_seen <= 1'b1; mnt_cnt <= mnt_cnt + 2'd1; end
        if (eject_wr) eject_seen <= 1'b1;

        if (img_mounted)        mnt_dly <= 17'd1;
        else if (mnt_dly != 0)  mnt_dly <= mnt_dly + 17'd1;
        if (mnt_dly == 17'h1FFFF) begin
            disk_in <= img_size_nz;
            wprot   <= img_readonly;   // stable since the mount pulse
        end else if (eject_wr)    disk_in <= 1'b0;
    end

    // ------------------------------------------------------------------
    // Register writes: DIRTN / STEP / MOTORON / EJECT  (floppy.v)
    // ------------------------------------------------------------------
    always @(posedge clk_sys) begin
        if (reset) begin
            driveRegs[DIRTN]   <= 1'b0;
            driveRegs[MOTORON] <= 1'b1;      // motor off
            driveTrack         <= 7'd0;
        end else begin
            if (sel && lstrb_edge) begin
                case (waddr)
                    DIRTN[2:0]:   driveRegs[DIRTN]   <= wca2;         // ca2 = write data
                    MOTORON[2:0]: driveRegs[MOTORON] <= wca2;
                    STEPR[2:0]: if (wca2 == 1'b0) begin              // step
                        if (driveRegs[DIRTN] == 1'b0 && driveTrack != 7'd79)
                            driveTrack <= driveTrack + 7'd1;
                        if (driveRegs[DIRTN] == 1'b1 && driveTrack != 7'd0)
                            driveTrack <= driveTrack - 7'd1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // force_absent: JTAG-scriptable EJECT (source[16]). The Lisa boot ROM only
    // arms the disk-inserted interrupt when it reaches the STARTUP FROM dialog,
    // so a disk mounted before that is never noticed. Pulsing force_absent
    // 1->0 at the menu generates a fresh insertion event (6504 sees eject then
    // insert) -> FDIR -> the ROM auto-boots the floppy.
    wire   force_absent, force_motor;              // from LFLP source (default 0)
    assign disk_present = disk_in & ~force_absent;
    wire   motor_on     = ~driveRegs[MOTORON] | force_motor;

    // ------------------------------------------------------------------
    // Tachometer  (floppy.v:308-340, periods rescaled 8.125 -> 81.5 MHz, x~10)
    // ------------------------------------------------------------------
    reg  [17:0] tachTimer;
    reg  [17:0] tachPeriod;
    always @(*) begin
        case (driveTrack[6:4])
            3'd0:    tachPeriod = 18'd100260; // tracks  0-15
            3'd1:    tachPeriod = 18'd91494;  // tracks 16-31
            3'd2:    tachPeriod = 18'd83170;  // tracks 32-47
            3'd3:    tachPeriod = 18'd74857;  // tracks 48-63
            default: tachPeriod = 18'd66545;  // tracks 64-79
        endcase
    end
    // TACH period is live-tunable via the LFLP source [31:19] (units of 32
    // clk_sys cycles; 0 = use the per-zone default) so the 6504 speed-lock can
    // be swept on hardware without recompiling.
    wire [8:0]  tach_ovr        = flp_src[31:23];
    wire [3:0]  sync_cells_ovr  = flp_src[22:19];   // self-sync byte cell count override (0=default 10)
    wire [17:0] tach_period_eff = (tach_ovr != 9'd0) ? {tach_ovr, 8'd0} : tachPeriod;
    always @(posedge clk_sys) begin
        if (reset) begin
            tachTimer <= 18'd0;
            tach_q    <= 1'b0;
        end else if (tachTimer >= tach_period_eff) begin
            tachTimer <= 18'd0;
            tach_q    <= ~tach_q;
        end else begin
            tachTimer <= tachTimer + 18'd1;
        end
    end

    // ------------------------------------------------------------------
    // Per-track buffer (M10K).  16-bit WORD memory so one sd_buff_wr stores a
    // full word.  4096 words = 8 KB (~7 M10K), ample for a track (12*512 data
    // bytes; M4 widens to sector*524 with the 12 tag bytes).
    // ------------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [15:0] trackbuf [0:4095];

    // write port (SD loader) and read port (GCR encoder) -> inferred dual-port
    reg  [11:0] load_widx;
    reg         load_we;
    reg  [15:0] load_wdata;
    always @(posedge clk_sys) if (load_we) trackbuf[load_widx] <= load_wdata;

    // Encoder source-byte selectors -> per-track buffer word/byte. A Lisa sector
    // is 524 bytes: src_offset 0..11 = tags (buffer word 3072 + sector*6 + t/2),
    // 12..523 = data (buffer word sector*256 + (off-12)/2). Two register stages
    // preserve the read latency the encoder's prefetch pipeline expects.
    wire [3:0] enc_sector;
    wire [9:0] enc_srcoff;
    wire       enc_istag = (enc_srcoff < 10'd12);
    wire [9:0] enc_doff  = enc_srcoff - 10'd12;
    wire [11:0] enc_word = enc_istag
        ? (12'd3072 + {6'd0, enc_sector, 2'b00} + {7'd0, enc_sector, 1'b0} + {9'd0, enc_srcoff[3:1]})
        : ({enc_sector, 8'd0} + {4'd0, enc_doff[8:1]});
    wire       enc_bytesel = enc_istag ? enc_srcoff[0] : enc_doff[0];

    reg  [11:0] enc_word_r;
    reg         enc_bsel_r;
    reg  [15:0] rd_word;
    reg         rd_sel;
    always @(posedge clk_sys) begin
        enc_word_r <= enc_word;
        enc_bsel_r <= enc_bytesel;
        rd_word    <= trackbuf[enc_word_r];
        rd_sel     <= enc_bsel_r;
    end
    wire [7:0] enc_idata = rd_sel ? rd_word[15:8] : rd_word[7:0];

    // ------------------------------------------------------------------
    // Per-zone running sector total (soff) and sectors-per-track (spt) for the
    // track being loaded. IMPORTANT: these are derived from ld_track (the track
    // LATCHED at load start), NOT the live driveTrack -- otherwise a head step
    // during a load would shift soff under the in-flight fetch and mislabel the
    // buffer. Mirrors the encoder's shift-add math.
    // ------------------------------------------------------------------
    reg  [6:0] ld_track;                     // track latched for the current load
    wire [3:0] spt =
        (ld_track[6:4]==3'd0)?4'd12:(ld_track[6:4]==3'd1)?4'd11:
        (ld_track[6:4]==3'd2)?4'd10:(ld_track[6:4]==3'd3)?4'd9:4'd8;
    wire [6:0] trackm1 = ld_track - 7'd1;
    wire [9:0] tt12 = {ld_track,3'b000} + {1'b0,ld_track,2'b00};
    wire [9:0] tt11 = {ld_track,3'b000} + {2'b00,ld_track,1'b0} + {3'b000,ld_track};
    wire [9:0] tt10 = {ld_track,3'b000} + {2'b00,ld_track,1'b0};
    wire [9:0] tt9  = {ld_track,3'b000} + {3'b000,ld_track};
    wire [9:0] tt8  = {ld_track,3'b000};
    wire [9:0] soff =
        (ld_track==7'd0)?10'd0:
        (trackm1[6:4]==3'd0)?tt12:
        (trackm1[6:4]==3'd1)?(tt11+10'd16):
        (trackm1[6:4]==3'd2)?(tt10+10'd48):
        (trackm1[6:4]==3'd3)?(tt9 +10'd96):
        (tt8+10'd160);

    // ------------------------------------------------------------------
    // SD track-load engine. Two jobs per (re)load: DATA then TAGS. Each job
    // copies `wcount` 16-bit words starting at image word `src_wbase` into the
    // track buffer at word `dst_wbase`, streaming whole SD blocks and skipping
    // the leading partial-block words. Handles the DC42 84-byte header (data at
    // byte 84 = word 42) and the separate tag block (byte 409684 = word 204842),
    // both word-aligned because sector/tag strides are even.
    //   buffer layout (16-bit words): DATA sector s -> [s*256 .. s*256+255];
    //                                 TAGS sector s -> [3072 + s*6 .. +5] (12 B)
    // ------------------------------------------------------------------
    localparam [11:0] TAG_WBASE = 12'd3072;             // tag region base word
    localparam [19:0] DC42_DATA_WORD = 20'd42;          // 84 / 2
    localparam [19:0] DC42_TAG_WORD  = 20'd204842;      // 409684 / 2

    wire [19:0] data_src = DC42_DATA_WORD + {2'd0, soff, 8'd0};              // 42 + soff*256
    wire [19:0] tag_src  = DC42_TAG_WORD  + {6'd0, soff, 2'b00} + {7'd0, soff, 1'b0}; // +soff*6
    wire [11:0] data_cnt = {spt, 8'd0};                            // spt*256 data words
    wire [11:0] tag_cnt  = {6'd0, spt, 2'b00} + {7'd0, spt, 1'b0}; // spt*6 tag words

    localparam LD_IDLE=3'd0, LD_SETUP=3'd1, LD_REQ=3'd2, LD_STREAM=3'd3, LD_BLKDONE=3'd4;
    reg [2:0]  ld_state;
    reg        job;                          // 0 = data, 1 = tags
    reg [15:0] cur_block;
    reg [7:0]  skip_left;
    reg [11:0] words_written;
    reg [11:0] wcount;
    reg [11:0] dst_wbase;
    reg [6:0]  loaded_track = 7'd127;  // invalid at power-up so the first track loads
    reg        sd_ack_d;

    wire [19:0] job_src = (job==1'b0) ? data_src : tag_src;
    wire [11:0] job_cnt = (job==1'b0) ? data_cnt : tag_cnt;
    wire [11:0] job_dst = (job==1'b0) ? 12'd0 : TAG_WBASE;

    // Bulletproof reload: load whenever a disk is present and the buffer does
    // not hold the current track. loaded_track resets to 127 (invalid), so a
    // fresh disk or a post-reset state always triggers a load. Combinational so
    // there is no pulse to miss.
    wire need_load = disk_present && (driveTrack != loaded_track);

    // sticky diagnostics (survive reset) for the LFLP probe
    reg load_ever = 1'b0, sdack_ever = 1'b0;
    always @(posedge clk_sys) begin
        if (ld_state == LD_REQ) load_ever  <= 1'b1;
        if (sd_ack)             sdack_ever <= 1'b1;
    end

    always @(posedge clk_sys) begin
        sd_ack_d <= sd_ack;
        load_we  <= 1'b0;

        if (reset) begin
            ld_state     <= LD_IDLE;
            sd_rd        <= 1'b0;
            sd_lba       <= 32'd0;
            job          <= 1'b0;
            loaded_track <= 7'd127;
        end else begin
            case (ld_state)
                LD_IDLE: begin
                    if (need_load) begin
                        ld_track <= driveTrack;   // latch the track for this load
                        job      <= 1'b0;
                        ld_state <= LD_SETUP;
                    end
                end

                LD_SETUP: begin
                    cur_block     <= job_src[19:8];
                    skip_left     <= job_src[7:0];
                    words_written <= 12'd0;
                    wcount        <= job_cnt;
                    dst_wbase     <= job_dst;
                    ld_state      <= LD_REQ;
                end

                LD_REQ: begin
                    if (!sd_ack) begin
                        sd_lba   <= {16'd0, cur_block};
                        sd_rd    <= 1'b1;
                        ld_state <= LD_STREAM;
                    end
                end

                LD_STREAM: begin
                    if (sd_ack && sd_buff_wr) begin
                        if (skip_left != 8'd0) begin
                            skip_left <= skip_left - 8'd1;
                        end else if (words_written < wcount) begin
                            load_we    <= 1'b1;
                            load_widx  <= dst_wbase + words_written;
                            load_wdata <= sd_buff_dout;
                            words_written <= words_written + 12'd1;
                        end
                    end
                    if (sd_ack_d && !sd_ack) begin
                        sd_rd    <= 1'b0;
                        ld_state <= LD_BLKDONE;
                    end
                end

                LD_BLKDONE: begin
                    if (words_written >= wcount) begin
                        if (job == 1'b0) begin      // data done -> load tags
                            job      <= 1'b1;
                            ld_state <= LD_SETUP;
                        end else begin              // tags done -> finished
                            loaded_track <= ld_track;
                            ld_state     <= LD_IDLE;
                        end
                    end else begin
                        cur_block <= cur_block + 16'd1;
                        ld_state  <= LD_REQ;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // GCR track encoder
    // ------------------------------------------------------------------
    wire [7:0] enc_odata;
    wire       enc_sync;
    reg        enc_ready;               // pulses once per GCR byte (from serializer)

    sony_gcr_encoder enc (
        .clk   (clk_sys),
        .ready (enc_ready),
        .rst   (reset),
        .side  (1'b0),                  // single-sided 400K
        .sides (1'b0),
        .track (driveTrack),
        .o_sector (enc_sector),
        .o_srcoff (enc_srcoff),
        .idata (enc_idata),
        .odata (enc_odata),
        .o_sync (enc_sync)
    );

    // ------------------------------------------------------------------
    // Serializer: shift each GCR byte MSB-first onto flux_bit at the bit rate.
    // HW TODO(M3): 10-cell self-sync for sync bytes; fine timing sweep.
    // ------------------------------------------------------------------
    // The Lisa spins the drive whenever it is SELECTED (it does not use the Sony
    // MOTORON register; the firmware left it off on hardware). force_motor keeps
    // a live override for experiments.
    wire active = sel | force_motor;

    reg [8:0] bit_div;
    reg [3:0] cell_idx;
    reg [7:0] shreg;
    reg       load_next;
    reg       flux;
    reg       cur_sync;   // current byte is a self-sync byte -> 10 cells

    // Self-sync bytes get extra cells (default 10 = 0xFF + 2 zero cells, the gap
    // the FDC sequencer needs to establish byte framing); tunable via source to
    // find the count that locks the frame (watch LSEQ.saw_addr). Normal = 8.
    // Default 11 -> 12-cell self-sync bytes. 10-cell (value 9) is the Sony
    // nominal, but the 6504 firmware deselects RDDATA for ~30 CPU cycles
    // (S13cd re-select) between the address field and the data-mark hunt,
    // costing the sequencer ~1 sync byte of re-framing; at 10 cells the
    // remaining gap was marginal and find_data_header timed out (~half the
    // attempts, err $48). Measured on hw: 12-cell syncs -> $48 = 0.
    wire [3:0] sync_cells_eff = (sync_cells_ovr != 4'd0) ? sync_cells_ovr : 4'd11;
    wire [3:0] cells_last = cur_sync ? sync_cells_eff : 4'd7;

    always @(posedge clk_sys) begin
        enc_ready <= 1'b0;
        flux      <= 1'b0;

        if (reset) begin
            bit_div   <= 9'd0;
            cell_idx  <= 4'd0;
            shreg     <= 8'hFF;
            load_next <= 1'b0;
            cur_sync  <= 1'b0;
        end else begin
            if (load_next) begin
                shreg     <= enc_odata;   // encoder byte is valid now (after ready)
                cur_sync  <= enc_sync;    // latch its sync flag with it
                load_next <= 1'b0;
            end

            if (active) begin
                // flux pulse at start of a bit cell if the current bit is 1.
                // At a BYTE boundary shreg still holds the old byte's bit0 for
                // one clk (load_next latches enc_odata this cycle), so use the
                // incoming byte's bit7 directly: without this, the first pulse
                // after a 0-ending byte started 1 clk late and was only 19 clk
                // wide -- narrower than the FDC sequencer's exactly-20-clk
                // sample grid, so at ~1/20 of cell phases the pulse fell in the
                // blind spot and the byte's leading '1' vanished (a 3-bit slip
                // after absorbing the leading zeros). That was the intermittent
                // track/sector-deterministic address-field corruption on hw.
                if (bit_div < pulse_w_eff && cell_idx <= cells_last &&
                    (load_next ? enc_odata[7] : shreg[7]))
                    flux <= 1'b1;

                if (bit_div >= bit_period_eff - 9'd1) begin
                    bit_div <= 9'd0;
                    if (cell_idx >= cells_last) begin
                        cell_idx  <= 4'd0;
                        enc_ready <= 1'b1;    // advance encoder to next byte
                        load_next <= 1'b1;    // latch its odata next cycle
                    end else begin
                        cell_idx <= cell_idx + 4'd1;
                        shreg    <= {shreg[6:0], 1'b0};
                    end
                end else begin
                    bit_div <= bit_div + 9'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Output mux: one serial line == RDA == SNS in Sony mode.
    // ------------------------------------------------------------------
    // flux_invert (LFLP source[15]): real Apple drives use active-LOW read pulses
    // (idle high, pulse low). Live-tunable so the FDC sequencer's expected
    // polarity can be found on hardware.
    wire flux_out = flux_invert ? ~flux : flux;
    assign rda_serial =
        ~sel                              ? 1'b1 :          // not selected -> idle high
        (raddr == RDDATA0 || raddr == RDDATA1) ? flux_out : // RDDATA -> serial GCR flux
                                            sense_reg[raddr]; // else -> held status level

    // ==================================================================
    // DEBUG (ISSP "LFLP", remove for release): floppy bring-up probe+source.
    // SOURCE (32b): [8:0] bit_period override (0=default 163); [12:9] pulse_w
    //   override (0=default); [14:13] phmap (PH<->register mapping select);
    //   [16] force_absent (eject); [17] lstrb_is_hds; [18] force_motor.
    // PROBE (64b): what the 6504 firmware is doing at the drive boundary.
    // ==================================================================
    wire [31:0] flp_src;
    wire [11:0] buf_src;          // DEBUG (ISSP "LBUF"): trackbuf word select
    wire [8:0]  bit_period_ovr = flp_src[8:0];
    wire [3:0]  pulse_w_ovr    = flp_src[12:9];
    assign      phmap          = flp_src[14:13];
    wire        flux_invert    = flp_src[15];
    assign      force_absent   = flp_src[16];
    assign      lstrb_is_hds   = flp_src[17];
    assign      force_motor    = flp_src[18];
    wire [8:0]  bit_period_eff = (bit_period_ovr != 9'd0) ? bit_period_ovr : BIT_PERIOD;
    // The FDC samples RDA every ~123-250ns and catches flux by rising-edge
    // detection, so the pulse must be held a good fraction of the bit cell.
    // Default = HALF the bit cell; override = pulse_w_ovr*8 clk for sweeping.
    wire [8:0]  pulse_w_eff    = (pulse_w_ovr    != 4'd0) ? {pulse_w_ovr, 3'd0} : 9'd20;

    // activity counters (edge-detected) so a single probe read shows progress
    reg  [4:0] ph_prev;
    reg        rddata_prev, sdrd_prev;
    reg  [6:0] trk_prev;
    reg  [7:0] ph_activity_cnt, rddata_cnt, step_cnt, sd_rd_cnt;
    wire       rddata_now = sel && (raddr == RDDATA0 || raddr == RDDATA1);
    always @(posedge clk_sys) begin
        if (reset) begin
            ph_activity_cnt <= 8'd0; rddata_cnt <= 8'd0; step_cnt <= 8'd0; sd_rd_cnt <= 8'd0;
            ph_prev <= 5'd0; rddata_prev <= 1'b0; sdrd_prev <= 1'b0; trk_prev <= 7'd0;
        end else begin
            ph_prev <= {PH, HDS};
            if ({PH, HDS} != ph_prev)          ph_activity_cnt <= ph_activity_cnt + 8'd1;
            rddata_prev <= rddata_now;
            if (rddata_now && !rddata_prev)    rddata_cnt <= rddata_cnt + 8'd1;
            trk_prev <= driveTrack;
            if (driveTrack != trk_prev)        step_cnt <= step_cnt + 8'd1;
            sdrd_prev <= sd_rd;
            if (sd_rd && !sdrd_prev)           sd_rd_cnt <= sd_rd_cnt + 8'd1;
        end
    end

    wire [63:0] flp_probe = {
        load_ever, sdack_ever, need_load, // [63:61] loader-ever-ran / SD-ever-acked / need_load
        mnt_seen,              // [60] img_mounted[1] pulsed since config (sticky)
        img_size_nz,           // [59] live: img_size != 0
        eject_seen,            // [58] eject_wr fired since config (sticky)
        mnt_cnt,               // [57:56] count of img_mounted pulses
        sd_rd_cnt,             // [55:48]
        step_cnt,              // [47:40]
        rddata_cnt,            // [39:32]
        ph_activity_cnt,       // [31:24]
        sel,                   // [23]
        motor_on,              // [22]
        disk_present,          // [21]
        ld_state,              // [20:18]
        raddr,                 // [17:14]
        loaded_track,          // [13:7]
        driveTrack             // [6:0]
    };

    // LFL2: sticky bitmask of every drive register the FDC has addressed for
    // read (reg_seen) and written (reg_wr_seen). Shows the firmware's full
    // register-access pattern -> whether it ever reaches TACH/RDDATA/MOTORON.
    reg [15:0] reg_seen    = 16'd0;
    reg [15:0] reg_wr_seen = 16'd0;
    reg [3:0]  raddr_hist0=0, raddr_hist1=0, raddr_hist2=0, raddr_hist3=0;
    reg [3:0]  raddr_p=0;
    always @(posedge clk_sys) begin
        if (sel) reg_seen[raddr] <= 1'b1;
        if (sel && lstrb_edge) reg_wr_seen[{1'b0, waddr}] <= 1'b1;
        // history of last 4 DISTINCT addressed registers
        raddr_p <= raddr;
        if (sel && raddr != raddr_p) begin
            raddr_hist3 <= raddr_hist2; raddr_hist2 <= raddr_hist1;
            raddr_hist1 <= raddr_hist0; raddr_hist0 <= raddr;
        end
    end
    // rda_serial is ONE multiplexed line: any excursion of raddr away from
    // RDDATA while the drive streams robs the FDC sequencer of flux for the
    // excursion's duration (the hardware L65B capture shows a ~3-bit-cell hole
    // mid-address-field on track 1 = exactly such a theft). Count them, note
    // the register they went to, and whether the serializer was mid-FIELD
    // (!cur_sync = an address/data byte was being emitted). Also count sel
    // drops (rda_serial forces idle-high when deselected).
    wire raddr_is_rd = (raddr == RDDATA0) || (raddr == RDDATA1);
    reg        raddr_was_rd = 1'b0, sel_p = 1'b0;
    reg [7:0]  exc_cnt = 8'd0;
    reg [3:0]  exc_last = 4'd0;
    reg [1:0]  exc_infield = 2'd0, sel_drop_cnt = 2'd0;
    always @(posedge clk_sys) begin
        sel_p <= sel;
        if (sel) raddr_was_rd <= raddr_is_rd;
        if (sel && raddr_was_rd && !raddr_is_rd) begin
            if (~&exc_cnt) exc_cnt <= exc_cnt + 8'd1;
            exc_last <= raddr;
            if (!cur_sync && ~&exc_infield) exc_infield <= exc_infield + 2'd1;
        end
        if (sel_p && !sel && ~&sel_drop_cnt) sel_drop_cnt <= sel_drop_cnt + 2'd1;
    end
    wire [63:0] flp2_probe = {
        raddr_hist3, raddr_hist2, raddr_hist1, raddr_hist0, // [63:48] last 4 distinct regs
        reg_wr_seen,                                        // [47:32] registers written
        reg_seen,                                           // [31:16] registers read/addressed
        exc_cnt,                                            // [15:8]  RDDATA->other excursions
        exc_last,                                           // [7:4]   register of last excursion
        sel_drop_cnt,                                       // [3:2]   sel fell while streaming
        exc_infield                                         // [1:0]   excursions mid-field (!cur_sync)
    };

    // DEBUG (ISSP "LBUF", remove for release): track-buffer readback. The GCR
    // read path is proven to FRAME correctly on hardware (LSEQ saw_addr/saw_data/
    // saw_depi all 1) yet the OS judges every disk "not in standard LOS format"
    // and the boot-block signature check fails -> the framing is right and the
    // CONTENT is wrong. Sim says the loader is byte-exact, so read the actual
    // buffer back over JTAG and diff it against the image to find where the real
    // HPS SD path diverges. dbg_word_sel selects a word; the read port is
    // separate from the encoder's so it cannot perturb the live read.
    wire [11:0] dbg_word_sel = buf_src[11:0];
    reg  [15:0] dbg_rd_word;
    always @(posedge clk_sys) dbg_rd_word <= trackbuf[dbg_word_sel];

    wire [63:0] buf_probe = {
        14'd0,
        ld_state,          // [49:47]
        loaded_track,      // [46:40]
        driveTrack,        // [39:33]
        disk_present,      // [32]
        dbg_word_sel,      // [31:20]
        4'd0,              // [19:16]
        dbg_rd_word        // [15:0]
    };

`ifndef SIMULATION
    altsource_probe #(
        .instance_id ("LFLP"), .probe_width (64), .source_width (32),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_flp_probe ( .source(flp_src), .probe(flp_probe),
        .source_clk(clk_sys), .source_ena(1'b1) );
    altsource_probe #(
        .instance_id ("LBUF"), .probe_width (64), .source_width (12),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_buf_probe ( .source(buf_src), .probe(buf_probe),
        .source_clk(clk_sys), .source_ena(1'b1) );
    altsource_probe #(
        .instance_id ("LFL2"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_flp2_probe ( .source(), .probe(flp2_probe),
        .source_clk(clk_sys), .source_ena(1'b1) );
`else
    assign flp_src = 32'd0;   // sim: overrides off, defaults apply
    assign buf_src = 12'd0;
`endif

endmodule
