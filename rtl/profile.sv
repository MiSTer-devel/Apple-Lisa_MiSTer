// profile.sv
// Apple ProFile Parallel Port Hard Disk Drive Emulator for MiSTer FPGA
//
// Translates 532-byte ProFile blocks to/from 512-byte SD card sectors using a 3-sector cache.
// Handles ProFile parallel protocol handshaking with command decoding and status bytes.

`timescale 1 ps / 1 ps

module profile (
    input  wire        clk,             // System clock (81.5 MHz)
    input  wire        reset,           // Core reset

    // ProFile Parallel Interface (from/to Lisa)
    input  wire        _PRES,           // Reset from Lisa (active low)
    input  wire        _CMD,            // Command line from Lisa (active low)
    input  wire        _PSTRB,          // Strobe line from Lisa (active low)
    input  wire        R_W,             // Read/Write select from Lisa (1 = Read, 0 = Write)
    output reg         _BSY,            // Busy line to Lisa (active low)
    output reg         _PARITY,         // Parity bit to Lisa
    // Was `inout [7:0] PD` (internal tri-state; unreliable under Quartus).
    // Split into explicit in/out + output-enable; the bus mux lives in Lisa.sv.
    input  wire [7:0]  PD_i,            // Combined data bus state
    output wire [7:0]  PD_o,            // Our drive value
    output wire        PD_oe_o,         // 1 = we are driving the bus

    // MiSTer HPS SD Card Interface
    output reg  [31:0] sd_lba,          // LBA sector address
    output reg         sd_rd,           // Sector read request
    output reg         sd_wr,           // Sector write request
    input  wire        sd_ack,          // Sector transfer acknowledge
    input  wire  [7:0] sd_buff_addr,    // Sector buffer word address (0-255)
    input  wire [15:0] sd_buff_dout,    // Data from HPS to FPGA
    output wire [15:0] sd_buff_din,     // Data from FPGA to HPS
    input  wire        sd_buff_wr,      // Buffer write enable from HPS
    input  wire        img_mounted,     // Disk image mounted
    input  wire [63:0] img_size         // Mounted disk image size in bytes
);

    // Tri-state buffer control for parallel data bus
    reg  [7:0] pd_out;
    reg        pd_oe;
    assign PD_o = pd_out;
    assign PD_oe_o = pd_oe;
    wire [7:0] pd_in = PD_i;

    // Odd parity generation: XOR sum of driven data bits
    always_comb begin
        _PARITY = ^pd_out;
    end

    // 3-sector cache. A 532-byte ProFile block can span three 512-byte host sectors.
    // Split into even/odd byte lanes (word address = byte_addr[10:1], lane =
    // byte_addr[0]) so BOTH the byte-addressed ProFile side and the 16-bit HPS
    // side map to on-chip BRAM. A single byte array with an ASYNC 16-bit read
    // (the old sd_buff_din) cannot infer as RAM and was synthesized as ~16K
    // registers, blowing the design past the device's ALM capacity.
    // Cache storage lives in two explicit MLAB LUT-RAM instances (lutram_1w1r,
    // instantiated below). A plain byte array with the ProFile async read + the
    // 16-bit HPS read would not infer as RAM and synthesized to ~16K registers,
    // blowing the design past the device's ALM capacity. Even/odd byte lanes:
    // word address = byte_addr[10:1], lane = byte_addr[0].
    reg [31:0] cache_sec0_tag, cache_sec1_tag, cache_sec2_tag;
    reg        cache_sec0_valid, cache_sec1_valid, cache_sec2_valid;
    reg        cache_sec0_dirty, cache_sec1_dirty, cache_sec2_dirty;

    // FPGA -> HPS data (sd_buff_din) is driven from the single shared read port
    // defined below (see cache_rd_word / even_q / odd_q).
    reg [1:0] active_slot;

    // Buffer writes from HPS to Cache BRAM
    // (Moved to the main always_ff block below to prevent multiple constant drivers)

    // Command decoding and buffering
    reg [7:0] commandBuffer[6];
    reg [2:0] cmd_idx;
    reg [23:0] block_num;
    reg [31:0] byte_addr;
    reg [31:0] sec_A, sec_B, sec_C;
    reg [8:0]  block_offset;
    reg [10:0] block_end_offset;

    // Shift-and-add multiplication: block_num * 532
    always_comb begin
        byte_addr = (block_num << 9) + (block_num << 4) + (block_num << 2);
        sec_A = byte_addr >> 9;
        sec_B = (byte_addr >> 9) + 32'd1;
        sec_C = (byte_addr >> 9) + 32'd2;
        block_offset = byte_addr & 9'h1FF;
        block_end_offset = {2'b00, byte_addr[8:0]} + 11'd531;
    end

    // Edges detection for handshaking signals
    reg pstrb_last;
    reg cmd_last;
    always_ff @(posedge clk) begin
        pstrb_last <= _PSTRB;
        cmd_last <= _CMD;
    end
    wire pstrb_falling = (_PSTRB == 0 && pstrb_last == 1);
    wire pstrb_rising  = (_PSTRB == 1 && pstrb_last == 0);
    wire cmd_falling   = (_CMD == 0 && cmd_last == 1);
    wire host_ack_value = (R_W == 0 && pd_in == 8'h55);
    wire host_ack       = (_CMD == 0 && host_ack_value);
    wire cmd_rising    = (_CMD == 1 && cmd_last == 0);

    // Main Emulator FSM States
    typedef enum reg [4:0] {
        ST_RESET,
        ST_IDLE,
        ST_HANDSHAKE_0,
        ST_HANDSHAKE_1,
        ST_CMD_RECV_0,
        ST_CMD_RECV_1,
        ST_CMD_DECODE,
        ST_READ_CONFIRM_0,
        ST_READ_CONFIRM_1,
        ST_READ_CACHE_A,
        ST_READ_CACHE_B,
        ST_READ_CACHE_C,
        ST_READ_DATA_0,
        ST_READ_DATA_1,
        ST_READ_DATA_2,
        ST_WRITE_CONFIRM_0,
        ST_WRITE_CONFIRM_1,
        ST_WRITE_CACHE_A,
        ST_WRITE_CACHE_B,
        ST_WRITE_CACHE_C,
        ST_WRITE_DATA_0,
        ST_WRITE_DATA_1,
        ST_WRITE_FLUSH_A,
        ST_WRITE_FLUSH_B,
        ST_WRITE_FLUSH_C,
        ST_WRITE_DONE_0,
        ST_WRITE_DONE_1,
        ST_WRITE_STATUS_0,
        ST_WRITE_STATUS_1,
        ST_HPS_READ,
        ST_HPS_WRITE,
        ST_BAD_CMD
    } state_t;

    state_t state, return_state;

    // Spare table content (48 bytes + FF padding)
    localparam logic [7:0] spareTable[48] = '{
        8'h50, 8'h52, 8'h4F, 8'h46, 8'h49, 8'h4C, 8'h45, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h00, 8'h00, 8'h00,
        8'h03, 8'h98, 8'h00, 8'h26, 8'h00, 8'h02, 8'h14, 8'h20, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF,
        8'h43, 8'h61, 8'h6D, 8'h65, 8'h6F, 8'h2F, 8'h41, 8'h70, 8'h68, 8'h69, 8'h64, 8'h20, 8'h30, 8'h30, 8'h30, 8'h31
    };

    wire img_is_10mb_profile = (img_size == 64'd10350592);

    function automatic [7:0] spare_table_byte(input [5:0] index);
        begin
            unique case (index)
                6'd8:  spare_table_byte = img_is_10mb_profile ? 8'h31 : spareTable[index];
                6'd9:  spare_table_byte = img_is_10mb_profile ? 8'h30 : spareTable[index];
                6'd10: spare_table_byte = img_is_10mb_profile ? 8'h4D : spareTable[index];
                6'd15: spare_table_byte = img_is_10mb_profile ? 8'h10 : spareTable[index];
                6'd16: spare_table_byte = img_is_10mb_profile ? 8'h04 : spareTable[index];
                6'd17: spare_table_byte = img_is_10mb_profile ? 8'h04 : spareTable[index];
                6'd19: spare_table_byte = img_is_10mb_profile ? 8'h4C : spareTable[index];
                default: spare_table_byte = spareTable[index];
            endcase
        end
    endfunction

    reg [9:0] data_idx; // up to 536 bytes
    reg [7:0] temp_data;
    reg       is_spare_read;
    reg       host_ack_seen;

    // Cache hit lookup helper logic. Slots are fixed for the active ProFile block:
    // slot 0 = first host sector, slot 1 = second, slot 2 = optional third.
    wire need_C = (block_end_offset >= 11'd1024);
    wire hit_A = cache_sec0_valid && (cache_sec0_tag == sec_A);
    wire hit_B = cache_sec1_valid && (cache_sec1_tag == sec_B);
    wire hit_C = !need_C || (cache_sec2_valid && (cache_sec2_tag == sec_C));
    wire [10:0] data_rel_addr = {2'b00, block_offset} + ({1'b0, data_idx} - 11'd4);
    wire [10:0] write_rel_addr = {2'b00, block_offset} + {1'b0, data_idx};
    wire [5:0] spare_read_index = data_idx[5:0] - 6'd4;

    // Cache word address (10-bit) from a slot + 9-bit byte offset (word = byte
    // address >> 1); the even/odd lane is selected by the byte-address LSB.
    function automatic [9:0] cache_word(input [1:0] slot, input [8:0] offset);
        return {slot, offset[8:1]};
    endfunction

    // --- ProFile-side byte addressing for the current read / write byte --------
    wire [1:0] pf_rd_slot = (data_rel_addr  < 11'd512)  ? 2'd0 :
                            (data_rel_addr  < 11'd1024) ? 2'd1 : 2'd2;
    wire [9:0] pf_rd_word = cache_word(pf_rd_slot, data_rel_addr[8:0]);
    wire       pf_rd_lane = data_rel_addr[0];
    wire [1:0] pf_wr_slot = (write_rel_addr < 11'd512)  ? 2'd0 :
                            (write_rel_addr < 11'd1024) ? 2'd1 : 2'd2;
    wire [9:0] pf_wr_word = cache_word(pf_wr_slot, write_rel_addr[8:0]);
    wire       pf_wr_lane = write_rel_addr[0];
    wire       pf_wr_en   = (state == ST_WRITE_DATA_1) && _CMD && pstrb_falling;

    // --- Single write port per lane (so the array maps to LUT-RAM, not ~16K
    //     registers). The HPS sector load (sd_buff_wr) and the ProFile byte
    //     writes are in disjoint FSM phases and never overlap, so each lane
    //     collapses to one write port. Reads stay async (LUT-RAM). -------------
    wire        even_we = sd_buff_wr | (pf_wr_en && !pf_wr_lane);
    wire [9:0]  even_wa = sd_buff_wr ? {active_slot, sd_buff_addr} : pf_wr_word;
    wire [7:0]  even_wd = sd_buff_wr ? sd_buff_dout[7:0]           : pd_in;
    wire        odd_we  = sd_buff_wr | (pf_wr_en &&  pf_wr_lane);
    wire [9:0]  odd_wa  = sd_buff_wr ? {active_slot, sd_buff_addr} : pf_wr_word;
    wire [7:0]  odd_wd  = sd_buff_wr ? sd_buff_dout[15:8]          : pd_in;
    // --- Single async read port per lane ---------------------------------------
    // The HPS (sd_buff) view and the ProFile read view never read simultaneously
    // (disjoint FSM phases), so ONE address mux feeds both — one read port per
    // lane keeps each RAM to 1W+1R (no duplication).
    wire [9:0] cache_rd_word = (state == ST_READ_DATA_1) ? pf_rd_word
                                                         : {active_slot, sd_buff_addr};
    wire [7:0] even_q, odd_q;

    // Explicit MLAB LUT-RAM (async read) for each byte lane — forces the cache
    // into on-chip RAM instead of registers.
    lutram_1w1r #(.AW(10), .DW(8)) u_even_cache (
        .clk(clk), .we(even_we), .waddr(even_wa), .wdata(even_wd),
        .raddr(cache_rd_word), .rdata(even_q));
    lutram_1w1r #(.AW(10), .DW(8)) u_odd_cache (
        .clk(clk), .we(odd_we),  .waddr(odd_wa),  .wdata(odd_wd),
        .raddr(cache_rd_word), .rdata(odd_q));

    assign sd_buff_din = {odd_q, even_q};

    // HPS transfer handshake tracking. Real MiSTer streams sd_buff_wr while
    // sd_ack is HIGH and drops sd_ack when the transfer is done, so a transfer
    // COMPLETES on the FALLING edge of sd_ack (not the rising edge — on hardware
    // that fires at the START of the stream, before any data has landed).
    // hps_req guards against a stale/early ack: we only complete a transfer we
    // actually requested and saw acked.
    reg hps_ack_d = 1'b0;
    reg hps_req   = 1'b0;

    // Emulator FSM and Cache Logic
    always_ff @(posedge clk) begin
        hps_ack_d <= sd_ack;
        if (reset || _PRES == 0) begin
            state <= ST_RESET;
            _BSY <= 1'b1;
            pd_oe <= 1'b0;
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
            cache_sec0_valid <= 0;
            cache_sec1_valid <= 0;
            cache_sec2_valid <= 0;
            cache_sec0_dirty <= 0;
            cache_sec1_dirty <= 0;
            cache_sec2_dirty <= 0;
            host_ack_seen <= 1'b0;
            hps_req <= 1'b0;
        end else begin
            case (state)
                ST_RESET: begin
                    _BSY <= 1'b1;
                    pd_oe <= 1'b0;
                    sd_rd <= 1'b0;
                    sd_wr <= 1'b0;
                    host_ack_seen <= 1'b0;
                    state <= ST_IDLE;
                end

                ST_IDLE: begin
                    _BSY <= 1'b1;
                    pd_oe <= 1'b0;
                    host_ack_seen <= 1'b0;
                    // The Lisa can assert _CMD while _PRES is still low during
                    // boot. A real ESProFile sees the line after reset releases;
                    // do the same instead of requiring a new falling edge.
                    if (cmd_falling || _CMD == 1'b0) begin
                        state <= ST_HANDSHAKE_0;
                    end
                end

                ST_HANDSHAKE_0: begin
                    pd_oe <= 1'b1;
                    pd_out <= 8'h01; // Drive 0x01 on bus
                    _BSY <= 1'b0;    // Acknowledge by pulling BSY low
                    if (host_ack) begin
                        host_ack_seen <= 1'b1;
                    end
                    if (_CMD == 1) begin
                        if (host_ack_seen || host_ack_value) begin
                            host_ack_seen <= 1'b0;
                            state <= ST_CMD_RECV_0;
                        end else begin
                            host_ack_seen <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_HANDSHAKE_1: begin
                    pd_oe <= 1'b0; // Set to input
                    if (host_ack) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_CMD_RECV_0;
                    end else if (_CMD == 1) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                ST_CMD_RECV_0: begin
                    _BSY <= 1'b1; // Raise BSY to show ready
                    cmd_idx <= 0;
                    state <= ST_CMD_RECV_1;
                end

                ST_CMD_RECV_1: begin
                    if (_CMD == 0) begin
                        // Command phase completed when Lisa pulls CMD low
                        state <= ST_CMD_DECODE;
                    end else if (pstrb_falling) begin
                        commandBuffer[cmd_idx] <= pd_in;
                        cmd_idx <= cmd_idx + 1'b1;
                    end
                end

                ST_CMD_DECODE: begin
                    block_num <= {commandBuffer[1], commandBuffer[2], commandBuffer[3]};
                    is_spare_read <= (commandBuffer[1] == 8'hFF && commandBuffer[2] == 8'hFF && commandBuffer[3] == 8'hFF);
                    
                    if (commandBuffer[0] == 8'h00) begin
                        state <= ST_READ_CONFIRM_0;
                    end else if (commandBuffer[0] == 8'h01 || commandBuffer[0] == 8'h02 || commandBuffer[0] == 8'h03) begin
                        state <= ST_WRITE_CONFIRM_0;
                    end else begin
                        state <= ST_BAD_CMD;
                    end
                end

                ST_READ_CONFIRM_0: begin
                    pd_oe <= 1'b1;
                    pd_out <= 8'h02; // Read confirmation
                    _BSY <= 1'b0;
                    if (host_ack) begin
                        host_ack_seen <= 1'b1;
                    end
                    if (_CMD == 1) begin
                        if (host_ack_seen || host_ack_value) begin
                            host_ack_seen <= 1'b0;
                            if (is_spare_read) begin
                                state <= ST_READ_DATA_0;
                            end else begin
                                state <= ST_READ_CACHE_A;
                            end
                        end else begin
                            host_ack_seen <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_READ_CONFIRM_1: begin
                    pd_oe <= 1'b0; // Set to input
                    if (host_ack) begin
                        host_ack_seen <= 1'b0;
                        if (is_spare_read) begin
                            state <= ST_READ_DATA_0;
                        end else begin
                            state <= ST_READ_CACHE_A;
                        end
                    end else if (_CMD == 1) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                // Cache access state machine for Read
                ST_READ_CACHE_A: begin
                    if (hit_A) begin
                        state <= ST_READ_CACHE_B;
                    end else begin
                        active_slot <= 2'd0;
                        if (cache_sec0_valid && cache_sec0_dirty) begin
                            // Must flush dirty sector first
                            sd_lba <= cache_sec0_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_READ_CACHE_A;
                        end else begin
                            sd_lba <= sec_A;
                            state <= ST_HPS_READ;
                            return_state <= ST_READ_CACHE_A;
                        end
                    end
                end

                ST_READ_CACHE_B: begin
                    if (hit_B) begin
                        state <= ST_READ_CACHE_C;
                    end else begin
                        active_slot <= 2'd1;
                        if (cache_sec1_valid && cache_sec1_dirty) begin
                            // Must flush dirty sector first
                            sd_lba <= cache_sec1_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_READ_CACHE_B;
                        end else begin
                            sd_lba <= sec_B;
                            state <= ST_HPS_READ;
                            return_state <= ST_READ_CACHE_B;
                        end
                    end
                end

                ST_READ_CACHE_C: begin
                    if (hit_C) begin
                        state <= ST_READ_DATA_0;
                    end else begin
                        active_slot <= 2'd2;
                        if (cache_sec2_valid && cache_sec2_dirty) begin
                            sd_lba <= cache_sec2_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_READ_CACHE_C;
                        end else begin
                            sd_lba <= sec_C;
                            state <= ST_HPS_READ;
                            return_state <= ST_READ_CACHE_C;
                        end
                    end
                end

                ST_READ_DATA_0: begin
                    _BSY <= 1'b1; // Ready for data strobe
                    data_idx <= 0;
                    pd_oe <= 1'b1;
                    pd_out <= 8'h00; // First status byte must be valid before BSY releases.
                    state <= ST_READ_DATA_1;
                end

                ST_READ_DATA_1: begin
                    // Status/Data multiplexing
                    if (data_idx < 4) begin
                        pd_out <= 8'h00; // Status bytes 0-3 are zero
                    end else begin
                        if (is_spare_read) begin
                            pd_out <= ((data_idx - 4) < 48) ? spare_table_byte(spare_read_index) : 8'hFF;
                        end else begin
                            // Async LUT-RAM read of the selected lane (shared port).
                            pd_out <= pf_rd_lane ? odd_q : even_q;
                        end
                    end

                    state <= ST_READ_DATA_2;
                end

                ST_READ_DATA_2: begin
                    if (_CMD == 0) begin
                        // Lisa pulled CMD low to end the transfer
                        state <= ST_IDLE;
                    end else if (pstrb_falling) begin
                        data_idx <= data_idx + 1'b1;
                        state <= ST_READ_DATA_1;
                    end
                end

                ST_WRITE_CONFIRM_0: begin
                    pd_oe <= 1'b1;
                    pd_out <= commandBuffer[0] + 8'h02; // Write response
                    _BSY <= 1'b0;
                    if (host_ack) begin
                        host_ack_seen <= 1'b1;
                    end
                    if (_CMD == 1) begin
                        if (host_ack_seen || host_ack_value) begin
                            host_ack_seen <= 1'b0;
                            state <= ST_WRITE_CACHE_A;
                        end else begin
                            host_ack_seen <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_WRITE_CONFIRM_1: begin
                    pd_oe <= 1'b0;
                    if (host_ack) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_WRITE_CACHE_A;
                    end else if (_CMD == 1) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                // Cache access state machine for Write (Read-Modify-Write)
                ST_WRITE_CACHE_A: begin
                    if (hit_A) begin
                        state <= ST_WRITE_CACHE_B;
                    end else begin
                        active_slot <= 2'd0;
                        if (cache_sec0_valid && cache_sec0_dirty) begin
                            sd_lba <= cache_sec0_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_WRITE_CACHE_A;
                        end else begin
                            sd_lba <= sec_A;
                            state <= ST_HPS_READ;
                            return_state <= ST_WRITE_CACHE_A;
                        end
                    end
                end

                ST_WRITE_CACHE_B: begin
                    if (hit_B) begin
                        state <= ST_WRITE_CACHE_C;
                    end else begin
                        active_slot <= 2'd1;
                        if (cache_sec1_valid && cache_sec1_dirty) begin
                            sd_lba <= cache_sec1_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_WRITE_CACHE_B;
                        end else begin
                            sd_lba <= sec_B;
                            state <= ST_HPS_READ;
                            return_state <= ST_WRITE_CACHE_B;
                        end
                    end
                end

                ST_WRITE_CACHE_C: begin
                    if (hit_C) begin
                        state <= ST_WRITE_DATA_0;
                    end else begin
                        active_slot <= 2'd2;
                        if (cache_sec2_valid && cache_sec2_dirty) begin
                            sd_lba <= cache_sec2_tag;
                            state <= ST_HPS_WRITE;
                            return_state <= ST_WRITE_CACHE_C;
                        end else begin
                            sd_lba <= sec_C;
                            state <= ST_HPS_READ;
                            return_state <= ST_WRITE_CACHE_C;
                        end
                    end
                end

                ST_WRITE_DATA_0: begin
                    _BSY <= 1'b1; // Ready for data strobe
                    data_idx <= 0;
                    state <= ST_WRITE_DATA_1;
                end

                ST_WRITE_DATA_1: begin
                    if (_CMD == 0) begin
                        // Host pulled CMD low; finished receiving 532 bytes
                        // Mark cached sectors dirty
                        cache_sec0_dirty <= 1'b1;
                        cache_sec1_dirty <= 1'b1;
                        if (need_C) cache_sec2_dirty <= 1'b1;

                        state <= ST_WRITE_FLUSH_A;
                    end else if (pstrb_falling) begin
                        // The received byte is written to the cache by the
                        // dedicated single-write-port block (pf_wr_en); here we
                        // only advance the byte index.
                        data_idx <= data_idx + 1'b1;
                    end
                end

                // Write-back flush to SD card
                ST_WRITE_FLUSH_A: begin
                    if (cache_sec0_valid && cache_sec0_dirty && cache_sec0_tag == sec_A) begin
                        active_slot <= 2'd0;
                        sd_lba <= cache_sec0_tag;
                        state <= ST_HPS_WRITE;
                        return_state <= ST_WRITE_FLUSH_B;
                    end else begin
                        state <= ST_WRITE_FLUSH_B;
                    end
                end

                ST_WRITE_FLUSH_B: begin
                    if (cache_sec1_valid && cache_sec1_dirty && cache_sec1_tag == sec_B) begin
                        active_slot <= 2'd1;
                        sd_lba <= cache_sec1_tag;
                        state <= ST_HPS_WRITE;
                        return_state <= ST_WRITE_FLUSH_C;
                    end else begin
                        state <= ST_WRITE_FLUSH_C;
                    end
                end

                ST_WRITE_FLUSH_C: begin
                    if (need_C && cache_sec2_valid && cache_sec2_dirty && cache_sec2_tag == sec_C) begin
                        active_slot <= 2'd2;
                        sd_lba <= cache_sec2_tag;
                        state <= ST_HPS_WRITE;
                        return_state <= ST_WRITE_DONE_0;
                    end else begin
                        state <= ST_WRITE_DONE_0;
                    end
                end

                ST_WRITE_DONE_0: begin
                    pd_oe <= 1'b1;
                    pd_out <= 8'h06; // Write completed OK
                    _BSY <= 1'b0;
                    if (host_ack) begin
                        host_ack_seen <= 1'b1;
                    end
                    if (_CMD == 1) begin
                        if (host_ack_seen || host_ack_value) begin
                            host_ack_seen <= 1'b0;
                            data_idx <= 0;
                            pd_out <= 8'h00;
                            // Release BSY only after CMD. LOS clears the VIA
                            // interrupt after sending 0x55; releasing earlier
                            // loses the edge and leaves S200 waiting forever.
                            _BSY <= 1'b1;
                            state <= ST_WRITE_STATUS_1;
                        end else begin
                            host_ack_seen <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_WRITE_DONE_1: begin
                    pd_oe <= 1'b0;
                    if (host_ack) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_IDLE;
                    end else if (_CMD == 1) begin
                        host_ack_seen <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                // After acknowledging a write with 0x06, a ProFile waits for
                // the Lisa's third 0x55 handshake and then returns four status
                // bytes. LOS treats the 0x06 itself as a hard-error status if
                // this phase is skipped.
                ST_WRITE_STATUS_0: begin
                    pd_out <= 8'h00;
                    state <= ST_WRITE_STATUS_1;
                end

                ST_WRITE_STATUS_1: begin
                    if (pstrb_falling) begin
                        if (data_idx != 3) begin
                            data_idx <= data_idx + 1'b1;
                            state <= ST_WRITE_STATUS_0;
                        end else begin
                            pd_oe <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end
                end

                // HPS SD Card Interface Handshaking states
                ST_HPS_READ: begin
                    // Request only when the bus is idle (no stale/pending ack).
                    if (~sd_ack && ~sd_rd && ~hps_req) sd_rd <= 1'b1;
                    // Our request was acked: drop sd_rd, mark the transfer in
                    // progress. The sector words stream into the cache via the
                    // sd_buff_wr write port while sd_ack stays high.
                    if (sd_rd && sd_ack) begin
                        sd_rd  <= 1'b0;
                        hps_req <= 1'b1;
                    end
                    // sd_ack fell => the whole sector has streamed. Only now mark
                    // the cache line valid and advance.
                    if (hps_req && hps_ack_d && ~sd_ack) begin
                        hps_req <= 1'b0;
                        if (active_slot == 2'd0) begin
                            cache_sec0_tag <= sd_lba;
                            cache_sec0_valid <= 1'b1;
                            cache_sec0_dirty <= 1'b0;
                        end else if (active_slot == 2'd1) begin
                            cache_sec1_tag <= sd_lba;
                            cache_sec1_valid <= 1'b1;
                            cache_sec1_dirty <= 1'b0;
                        end else begin
                            cache_sec2_tag <= sd_lba;
                            cache_sec2_valid <= 1'b1;
                            cache_sec2_dirty <= 1'b0;
                        end
                        state <= return_state;
                    end
                end

                ST_HPS_WRITE: begin
                    if (~sd_ack && ~sd_wr && ~hps_req) sd_wr <= 1'b1;
                    if (sd_wr && sd_ack) begin
                        sd_wr  <= 1'b0;
                        hps_req <= 1'b1;
                    end
                    if (hps_req && hps_ack_d && ~sd_ack) begin
                        hps_req <= 1'b0;
                        if (active_slot == 2'd0) begin
                            cache_sec0_dirty <= 1'b0;
                        end else if (active_slot == 2'd1) begin
                            cache_sec1_dirty <= 1'b0;
                        end else begin
                            cache_sec2_dirty <= 1'b0;
                        end
                        state <= return_state;
                    end
                end

                ST_BAD_CMD: begin
                    pd_oe <= 1'b1;
                    pd_out <= 8'h55; // Error status
                    _BSY <= 1'b0;
                    if (_CMD == 1) begin
                        state <= ST_IDLE;
                    end
                end
            endcase
        end
    end

    // Simulator-visible counters for ProFile bring-up/status output.
    //  state       = current FSM state
    //  max_state   = furthest state reached (how far the boot handshake got)
    //  cmd0        = commandBuffer[0] (00=read, 01/02/03=write)
    //  blk         = low 12 bits of block_num requested
    //  cmd_edges   = _CMD falling edges (Lisa starting transactions)
    //  strb_edges  = _PSTRB falling edges (byte strobes)
    //  rd_acks     = completed SD reads (sd_ack while sd_rd)
    //  pres        = _PRES level (0 = Lisa holding ProFile in reset)
    reg [4:0] max_state /*verilator public_flat_rd*/ = 0;
    reg [7:0] cmd_edges /*verilator public_flat_rd*/ = 0;
    reg [7:0] strb_edges /*verilator public_flat_rd*/ = 0;
    reg [7:0] rd_acks /*verilator public_flat_rd*/ = 0;
    reg cmd_d = 1, strb_d = 1, rd_ack_d = 0;
    // Latch reset state if a command edge arrives while the FSM is held in reset.
    reg rst_at_cmd /*verilator public_flat_rd*/ = 0;
    reg pres_at_cmd /*verilator public_flat_rd*/ = 1;
    reg [3:0] cmd_in_rst /*verilator public_flat_rd*/ = 0;
    reg [31:0] dbg_block0_status /*verilator public_flat_rd*/ = 0;
    reg [63:0] dbg_block0_hdr /*verilator public_flat_rd*/ = 0;
    reg [63:0] dbg_last_read_hdr0 /*verilator public_flat_rd*/ = 0;
    reg [63:0] dbg_last_read_hdr1 /*verilator public_flat_rd*/ = 0;
    // DEBUG: SD-side capture to see whether the HPS actually loads real data into
    // the cache on hardware (block-0 hdr came back all-zero on the FPGA).
    reg [15:0] dbg_sd_fileid = 0;    // sd_buff_dout when writing slot0 word 2 (FILEID)
    reg [7:0]  dbg_sd_wr_cnt = 0;    // count of sd_buff_wr (cache load words)
    reg [7:0]  dbg_rd_data_cnt = 0;  // count of ST_READ_DATA_2 byte deliveries
    reg [31:0] dbg_sd_lba_last = 0;  // last requested SD sector
    always_ff @(posedge clk) begin
        if (state > max_state) max_state <= state;
        cmd_d <= _CMD; strb_d <= _PSTRB; rd_ack_d <= (sd_rd & sd_ack);
        if (cmd_d && !_CMD)   cmd_edges  <= cmd_edges + 8'd1;
        if (strb_d && !_PSTRB) strb_edges <= strb_edges + 8'd1;
        if (!rd_ack_d && (sd_rd & sd_ack)) rd_acks <= rd_acks + 8'd1;
        if (sd_buff_wr) begin
            dbg_sd_wr_cnt <= dbg_sd_wr_cnt + 8'd1;
            if (active_slot == 2'd0 && sd_buff_addr == 8'd2) dbg_sd_fileid <= sd_buff_dout;
        end
        if (state == ST_READ_DATA_2 && pstrb_falling) dbg_rd_data_cnt <= dbg_rd_data_cnt + 8'd1;
        if (sd_rd) dbg_sd_lba_last <= sd_lba;
        if (cmd_d && !_CMD && (reset || _PRES == 1'b0)) begin
            rst_at_cmd  <= reset;
            pres_at_cmd <= _PRES;
            cmd_in_rst  <= cmd_in_rst + 4'd1;
        end
        if (state == ST_CMD_DECODE && commandBuffer[0] == 8'h00 &&
            {commandBuffer[1], commandBuffer[2], commandBuffer[3]} == 24'h000000) begin
            dbg_block0_status <= 32'h0;
            dbg_block0_hdr <= 64'h0;
        end
        if (state == ST_CMD_DECODE && commandBuffer[0] == 8'h00) begin
            dbg_last_read_hdr0 <= 64'h0;
            dbg_last_read_hdr1 <= 64'h0;
        end
        if (state == ST_READ_DATA_2 && pstrb_falling && !is_spare_read) begin
            unique case (data_idx)
                10'd4:  dbg_last_read_hdr0[63:56] <= pd_out;
                10'd5:  dbg_last_read_hdr0[55:48] <= pd_out;
                10'd6:  dbg_last_read_hdr0[47:40] <= pd_out;
                10'd7:  dbg_last_read_hdr0[39:32] <= pd_out;
                10'd8:  dbg_last_read_hdr0[31:24] <= pd_out;
                10'd9:  dbg_last_read_hdr0[23:16] <= pd_out;
                10'd10: dbg_last_read_hdr0[15:8]  <= pd_out;
                10'd11: dbg_last_read_hdr0[7:0]   <= pd_out;
                10'd12: dbg_last_read_hdr1[63:56] <= pd_out;
                10'd13: dbg_last_read_hdr1[55:48] <= pd_out;
                10'd14: dbg_last_read_hdr1[47:40] <= pd_out;
                10'd15: dbg_last_read_hdr1[39:32] <= pd_out;
                10'd16: dbg_last_read_hdr1[31:24] <= pd_out;
                10'd17: dbg_last_read_hdr1[23:16] <= pd_out;
                10'd18: dbg_last_read_hdr1[15:8]  <= pd_out;
                10'd19: dbg_last_read_hdr1[7:0]   <= pd_out;
                default: ;
            endcase
        end
        if (state == ST_READ_DATA_2 && pstrb_falling && !is_spare_read && block_num == 24'h000000) begin
            unique case (data_idx)
                10'd0: dbg_block0_status[31:24] <= pd_out;
                10'd1: dbg_block0_status[23:16] <= pd_out;
                10'd2: dbg_block0_status[15:8]  <= pd_out;
                10'd3: dbg_block0_status[7:0]   <= pd_out;
                10'd4: dbg_block0_hdr[63:56] <= pd_out;
                10'd5: dbg_block0_hdr[55:48] <= pd_out;
                10'd6: dbg_block0_hdr[47:40] <= pd_out;
                10'd7: dbg_block0_hdr[39:32] <= pd_out;
                10'd8: dbg_block0_hdr[31:24] <= pd_out;
                10'd9: dbg_block0_hdr[23:16] <= pd_out;
                10'd10: dbg_block0_hdr[15:8] <= pd_out;
                10'd11: dbg_block0_hdr[7:0]  <= pd_out;
                default: ;
            endcase
        end
    end

    // DEBUG (ISSP "LPRO"/"LPR2", remove for release): expose the captured block-0
    // header/status + FSM state over JTAG so we can see what the ProFile emulator
    // delivers on real HARDWARE (the Verilator sim reads these via public_flat_rd;
    // the FPGA needs a probe). LPRO = dbg_block0_hdr (block bytes 0-7; FILEID is
    // bits [31:16] and must be 0xAAAA). LPR2 = status + max_state + live signals.
`ifndef SIMULATION
    altsource_probe #(
        .sld_auto_instance_index ("YES"), .sld_instance_index (0),
        .instance_id ("LPRO"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_pro_hdr_probe ( .source(), .probe(dbg_block0_hdr),
        .source_clk(clk), .source_ena(1'b1) );
    altsource_probe #(
        .sld_auto_instance_index ("YES"), .sld_instance_index (0),
        .instance_id ("LPR2"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_pro_st_probe ( .source(), .probe({ dbg_sd_fileid, dbg_sd_wr_cnt,
        rd_acks, dbg_rd_data_cnt, max_state, dbg_sd_lba_last[15:0], 3'd0 }),
        .source_clk(clk), .source_ena(1'b1) );
`endif
endmodule

// Simple 1-write / 1-async-read LUT-RAM. The canonical pattern below maps to
// Cyclone V MLAB (distributed LUT-RAM), which — unlike M10K block RAM — supports
// an asynchronous (combinational) read, as the ProFile data path needs. Used for
// the ProFile sector cache so it costs a handful of ALMs instead of ~16K FFs.
module lutram_1w1r #(parameter AW = 10, parameter DW = 8) (
    input               clk,
    input               we,
    input  [AW-1:0]     waddr,
    input  [DW-1:0]     wdata,
    input  [AW-1:0]     raddr,
    output [DW-1:0]     rdata
);
    (* ramstyle = "MLAB, no_rw_check" *) reg [DW-1:0] mem [2**AW];
    always @(posedge clk) if (we) mem[waddr] <= wdata;
    assign rdata = mem[raddr]; // asynchronous read
endmodule
