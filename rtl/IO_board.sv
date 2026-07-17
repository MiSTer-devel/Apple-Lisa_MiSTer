`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/23/2025 03:31:58 PM
// Design Name: The Apple Lisa I/O Board
// Module Name: IO_board
// Project Name: LisaFPGA
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module IO_board(
    output logic [3:0] PH,
    output logic WRD,
    output logic _WRQ,
    input logic RDA,
    output logic _DR1,
    output logic _DR0,
    output logic HDS,
    input logic SNS,
    output logic MT1,
    output logic MT0,
    input logic _IRQ, // not connected to anything, from the floppy drives
    output logic _RSIR,
    output logic _KBIR,
    output logic _IOIR,
    input logic E,
    input logic _RESET_SYSTEM,
    input logic CPUCK,
    input logic _LDMA,
    input logic _BGACK, // also not connected to anything
    input logic _BR, // also not connected to anything
    output logic _BG0,
    input logic _BG,
    input logic [15:0] BD_in,
    output logic [15:0] BD_out,
    output logic BD_OE,
    input wire [12:1] A,
    input logic _VMA,
    input logic _VPA_in,
    output logic _VPA_out,
    output logic VPA_OE,
    input logic _DTACK_in,
    output logic _DTACK_out,
    output logic DTACK_OE,
    input logic _AS,
    input logic READ,
    input logic _LDS,
    input logic _UDS,
    input logic _INTIO,
    input logic OCD,
    input logic [7:0] PD_in,
    output logic [7:0] PD_out,
    output logic _ProFile_EN,
    output logic PR_W_ungated,
    input logic _PARITY,
    output logic _PSTRB,
    output logic DR_W,
    input logic _BSY,
    output logic _CMD,
    // input logic BAT, // no battery on an FPGA
    //input logic SPKRIN,
    output logic TONE,
    output logic [5:0] CONT, // 1 analog signal on original; here we pipe out the full 6 bit digital value
    input logic KBD_in,
    output logic KBD_out,
    input logic [6:0] M,

    // Serial port signals from the internal SCC
    input logic SYNCA,
    output logic TXDA,
    output logic RTSA,
    output logic DTRA,
    input logic RXDA,
    input logic CTSA,
    input logic DCDA,
    output logic TRXCA,
    input logic RTXCA,
    output logic TXDB,
    output logic DTRB,
    output logic RTSB,
    input logic RXDB,
    input logic CTSB_TRXCB,

    input logic _CRES_in,
    output logic _CRES_out,
    output logic _NMI,
    output logic NMI_OE,
    input logic _PWRSW,
    output logic ON,

    // These clocks are normally generated on the I/O board in a real Lisa, but we gen them in the top-level module with an MMCM
    input logic sysclk, // 125MHz FPGA system clock
    input logic clk_sys,     // 81.5MHz master clock
    input logic dotck_en,    // DOTCK-rate enable strobe
    input logic c16m_en,     // 16.3MHz enable strobe
    input logic copck2x_en,  // 3.9MHz COP enable strobe
    input logic sccck_en,    // 3.6864MHz SCC enable strobe (reserved; SCC serial deferred)
    input logic COPCK, // 3.9MHz clock (the COP clock); this is NOT a clock net, so we'll use it as a clock enable
    input logic E_pos_phase, // A pulse that goes high for one cycle just after the rising edge of E, used by the 6522 VIA core
    input logic E_neg_phase, // Same but for the falling edge of E, used by the 6522 VIA core
    output logic [2:0] VC, // 3-bit volume control for the external speaker amp
    
    input logic IO_ROM_SEL, // Selects whether the I/O board uses ROM revision A8 or 40

    // RTC clock seeding: at boot, before the auto power-on press, a small
    // sequencer drives the real COP421 with the clock-set command sequence so
    // the COP keeps host time. Packet = 16 nibbles from rtc_lisa (Lisa.sv).
    input  logic [63:0] rtc_nibbles,
    input  logic        rtc_valid,
    input  logic        rtc_load_req,
    output logic        rtc_seed_done,

    input logic spoof_88 // If set, this makes the FDC RAM at address 0x018 (FCC030) return 0x88 instead of its actual contents
    );

    // Before we do anything else, let's take the _SYSTEM_RESET signal and turn it into a _RESET signal for the I/O board
    // _SYSTEM_RESET is in the DOTCK clock domain, but we need _RESET to be in the C16M clock domain
    // So we'll use a two-stage synchronizer to avoid metastability issues
    (* ASYNC_REG = "TRUE" *) logic _RESET_int, _RESET;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            _RESET_int <= _RESET_SYSTEM;
            _RESET <= _RESET_int;
        end
    end

    // Okay, let's get Page 1 out of the way first; it's literally just:
    assign _BG0 = _BG; // This forwards all the bus grants through the I/O board to expansion cards
    // If the I/O board could take control of the bus (which it can't), it might need to do something more complex here
    // And only pass the signal on if it wasn't what was trying to take over the bus

    // Now let's get the hardest page out of the way: Page 4, the floppy controller and its associated hardware
    // First, instantiate a 6504 microprocessor, but there aren't actually any IP cores available for that
    // So we'll use a 6502 core (apparently this one's transistor-accurate) and adapt it a bit since they're basically the same chip
    // This 4-bit signal is the counter that synchronizes all the operations in the floppy controller
    logic [3:0] FDC_counter;
    // The R/W line from the 6504
    logic RW_FDC;
    // The 6504's address and data buses
    logic [15:0] MA;
    logic [7:0] FD_in;

    logic [7:0] FD_out;

    logic [15:0] MA_unlatched;
    logic [7:0] FD_out_unlatched;
    logic RW_FDC_latched;
    logic _RW_FDC_unlatched;

    cpu FDC_6504(
        .clk(clk_sys), // Clock is clk_sys
        .phi(FDC_counter_clock_enables_rising[2] & c16m_en), // And we use FDC_counter[2] as the clock enable
        .reset(~_RESET), // Reset comes from systemwide _RESET
        .AB(MA_unlatched), // This core expects synchronous RAM, so we'll latch the RAM address
        .DI(FD_in), // Data input/output buses
        .DO(FD_out_unlatched), // Latch the output just like the address bus
        .WE(_RW_FDC_unlatched), // Latch the R/W line too
        .IRQ(1'b0), // 6504 actually does have IRQ, but the Lisa ties it high (inactive)
        .NMI(1'b0), // No NMI on a 6504, always inactive
        .RDY(1'b1)  // Also doesn't exist on a 6504, set to always ready
    );

    // Forward the unlatched address, data, and R/W signals to the latched versions on the rising edge of the PHI2 clock (FDC_counter[2])
    // Use C16M to clock the FF, but FDC_counter[2] as a clock enable
    logic [3:0] FDC_counter_clock_enables_rising;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            if (FDC_counter_clock_enables_rising[2]) begin
                MA <= MA_unlatched;
                FD_out <= FD_out_unlatched;
                RW_FDC <= ~_RW_FDC_unlatched;
            end
        end
    end

    /*chip_6502 FDC_6504 (
        .clk(C16M), // Use sysclk as the free-running clock
        .phi(FDC_counter_clock_enables_rising[2]), // And FDC_counter[2] as the 6502 clock enable
        .res(_RESET), // Reset comes from systemwide _RESET
        .so(1'b0), // We don't use the set overflow pin (doesn't even exist on the 6504), set it inactive
        .rdy(1'b1), // Also doesn't exist on a 6504, set to always ready
        .nmi(1'b1), // No NMI on a 6504, always inactive
        .irq(1'b1), // 6504 actually does have IRQ, but the Lisa doesn't use it
        .dbi(FD_in), // Data input/output buses
        .dbo(FD_out),
        .rw(RW_FDC), // R/W line
        // SYNC output unused
        .ab(MA) // Processor address bus
    );*/

    // The FD_in bus going into the 6504 can be fed by a few different sources
    logic [7:0] PSM_out;
    // One of the two OE signals for the state machine LS323; the other comes from MA[0]
    logic _state_machine_OE1;
    logic [7:0] RD_out;
    logic _FDC_RAM_CS_processed;
    logic [7:0] ROM_out;
    logic _IOROM_CE;

    always_comb begin
        if (!_IOROM_CE) begin
            // If the ROM is selected, then put its data on the bus
            FD_in = ROM_out;
        end else if (!_FDC_RAM_CS_processed) begin
            // If the RAM is selected, then do the same for it
            FD_in = RD_out;
        end else if (!MA[0] && !_state_machine_OE1) begin
            // And finally, put the floppy state machine's shift register output on the bus if it's selected
            FD_in = PSM_out;
        end else begin 
            // If nothing's selected, just pull it high
            FD_in = 8'b11111111;
        end
    end

    // We have to get a bit more creative for the R/W line though
    // The 6504 will leave it asserted for the entire duration of multi-byte writes, but our async RAM can't handle this
    // The RAM will detect this as a single write op and miss the second data byte, so we must deassert it in the middle of multi-byte writes
    // We can do this by simply gating it with FDC_counter[2], which is high for half of the cycle time
    /*always_comb begin
        if (RW_FDC_latched == 1'b0 && FDC_counter[2] == 1'b0) begin
            RW_FDC = 1'b0;
        end else begin
            RW_FDC = 1'b1;
        end
    end*/


    // The 6504 also generates a PHI2 clock output, which we need, but this core doesn't provide it
    // Luckily it's literally just PHI0 with a slight gate delay, so we can probably get away with just using PHI0
    // That's what we'll try, at least

    // Now let's instantiate the I/O board ROM and hook it to the 6504
    // We do this twice, once for the A8 ROM once for the 40 ROM, and use the IO_ROM_SEL signal to pick between them
    IOROM_2732 #(.ROM_file("IOROM_A8.mem")) IOROM_A8(
        .A(MA[11:0]),
        ._OE(1'b0), // Always enabled
        ._CE(_IOROM_CE | IO_ROM_SEL), // Use A8 ROM when IO_ROM_SEL is low
        .D(ROM_out)
    );

    IOROM_2732 #(.ROM_file("IOROM_40.mem")) IOROM_40(
        .A(MA[11:0]),
        ._OE(1'b0), // Always enabled
        ._CE(_IOROM_CE | ~IO_ROM_SEL), // Use 40 ROM when IO_ROM_SEL is high
        .D(ROM_out)
    );

    // Let's do the same for the two 444C-3 RAM chips that provide 1K of RAM to the FDC, shared by the 6504 for FDC and the 68K for PRAM
    // Chip select for both chips
    logic _FDC_RAM_CS;
    // Address lines for the chips, will be multiplexed between the 6504 and 68K
    logic [9:0] RA;
    // R/W line multiplexed between the 6504 and 68K too
    logic RW_FDC_RAM;

    // We've got to do some special processing on the chip select signal to get things to work on the actual FPGA
    // IF we just forwarded the select signal from the 6504 or 68K directly to the RAM, we would run into timing issues
    // The address and data lines might not be stable when the RAM sees the falling edge of the chip select signal
    // And this completely breaks the floppy controller obviously
    // So we need to do some synchronization and delay magic here to make sure the RAM gets selected only after everything is stable
    // But there's another edge case to worry about too; what if the 68K interrupted a 6504 access to RAM?
    // Well, in that case, the 6504's clock will get paused for the duration of the 68K access, and will resume (finishing the interrupted cycle) afterwards
    // But since the 68K access changed the RAM address, the RAM will still be outputting the 68K's data when the 6504 cycle resumes
    // And so the 6504 will read the wrong data, causing crazy stuff to happen
    // So we need to make sure that when the 68K stops accessing the RAM, the RAM gets unselected and reselected again so it latches the 6504 address again
    logic _FDC_RAM_CS_muxed;
    logic FDC_counter_inhibit_flag;
    logic FDC_counter_inhibit;
    logic FDC_RAM_addr_select_prev;
    logic FDC_RAM_addr_select;

    // First, we use this flip-flop to determine what should be feeding the RAM's chip select; no delay logic yet
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        // If the 68K is trying to access the RAM, then keep the select low for as long as it's selecting it
        if (~FDC_RAM_addr_select) begin
            _FDC_RAM_CS_muxed <= 1'b0;
        // If the 68K just stopped accessing the RAM, then unselect it for one sysclk cycle to allow a falling edge again
        // If we don't do this, then CS will just stay low when the 6504 regains control and tries to access RAM itself
        // And since the 6504 is trying to access a different address, the RAM needs to see a falling edge on CS again to latch the new address
        end else if (~FDC_RAM_addr_select_prev && FDC_RAM_addr_select) begin
            _FDC_RAM_CS_muxed <= 1'b1;
        // Otherwise, just forward the 6504's chip select signal directly to the RAM
        end else begin
            _FDC_RAM_CS_muxed <= _FDC_RAM_CS;
        end
      end
    end

    // This handles the setting and clearing of the counter inhibit flag that we use to pause the 6504 clock
    // The flag only lasts for one sysclk cycle here, but we'll stretch it out in the next always_ff block
    logic _DTACK_ungated;
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        // If we're at the end of a 68K access to the RAM (rising edge of FDC_RAM_addr_select), then set the flag
        // Also set it during end of the access (when DTACK is asserted), so that there's not a quick toggle of this signal
        if ((~FDC_RAM_addr_select_prev && FDC_RAM_addr_select) | !_DTACK_ungated) begin
            FDC_counter_inhibit_flag <= 1'b1;
        end else begin
            // Otherwise, clear it
            FDC_counter_inhibit_flag <= 1'b0;
        end
      end
    end

    logic [3:0] FDC_inhibit_delay;
    // Here's that next always_ff block I was talking about
    // We need the inhibit to be active a bit longer so we have time to set and clear the CS strobe of the RAM before the 6504 clock resumes
    // So we'll latch it whenever the flag goes high, and then hold it for a few sysclk cycles afterwards before releasing it again
    // The RAM CS signal is registered on sysclk/2, so 16 sysclk cycles here should be plenty of time
    always_ff @(posedge clk_sys, negedge _RESET) begin
        if (!_RESET) begin
            FDC_inhibit_delay <= 4'b0000;
            FDC_counter_inhibit <= 1'b0;
        end else if (c16m_en) begin
         if (FDC_counter_inhibit_flag) begin
            FDC_inhibit_delay <= 4'b1111;
            FDC_counter_inhibit <= 1'b1;
         end else if (FDC_inhibit_delay != 4'b0000) begin
            FDC_inhibit_delay <= FDC_inhibit_delay - 1;
            FDC_counter_inhibit <= 1'b1;
         end else if (FDC_inhibit_delay == 4'b0000) begin
            FDC_counter_inhibit <= 1'b0;
         end
        end
    end

    /*logic sysclk_counter;
    logic sysclk_divided;

    always_ff @(posedge sysclk, negedge _RESET) begin
        if (!_RESET) begin
            sysclk_counter <= 1'b0;
            sysclk_divided <= 1'b0;
        end else begin
            sysclk_counter <= sysclk_counter + 1;
            if (sysclk_counter == 1'b1) begin
                sysclk_divided <= ~sysclk_divided;
            end
        end
    end*/

    // So that all handles determining what gets forwarded to the RAM, but we still need to delay it to account for the setup time of the address and data lines
    // We do this by simply registering the signal on the rising edge of the system clock
    // We could probably get away with using the 16MHz clock here, but using the faster sysclk gives us more margin
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            _FDC_RAM_CS_processed <= _FDC_RAM_CS_muxed;
        end
    end

    // And this little flip-flop here just remembers what the previous state of FDC_RAM_addr_select was for our edge detection logic in the mux
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            FDC_RAM_addr_select_prev <= FDC_RAM_addr_select;
        end
    end

    // DEBUG (ISSP "LFDR", remove for release): dump the shared 6504<->68000 FDC
    // RAM over JTAG. The emulated drive is proven correct up to PSM_out (track
    // buffer byte-exact, framing holds to the data-field epilogue), so this
    // splits the remaining chain: if the sector buffer here holds block 0's
    // 4E FA 00 0E AA AA the read is fine and the bug is 68000-side/mapping; if
    // it holds some OTHER block's valid data it's a logical-block mapping bug
    // (which the testbench CANNOT catch -- it checks the buffer with the same
    // soff math the RTL uses); if it's garbage the bug is PSM_out -> 6504.
    wire [9:0] dbg_fdr_A;
    wire [3:0] dbg_fdr_Dlo, dbg_fdr_Dhi;

    IO_RAM_444C_3 low_FDC_RAM(
        .A(RA),
        .spoof_88(spoof_88), // Make the RAM always return ROM revision 88 if spoof_88 is set
        ._CS(_FDC_RAM_CS_processed),
        .R_W(RW_FDC_RAM),
        .D_in(RD_in[3:0]), // We'll talk about this in a second
        .D_out(RD_out[3:0]),
        .dbg_A(dbg_fdr_A),
        .dbg_D(dbg_fdr_Dlo)
    );

    IO_RAM_444C_3 high_FDC_RAM(
        .A(RA),
        .spoof_88(spoof_88),
        ._CS(_FDC_RAM_CS_processed),
        .R_W(RW_FDC_RAM),
        .D_in(RD_in[7:4]), // Same here
        .D_out(RD_out[7:4]),
        .dbg_A(dbg_fdr_A),
        .dbg_D(dbg_fdr_Dhi)
    );

    // As I said, the RAM is shared with the 68K, so let's make its contents available to the 68K on the systemwide BD bus
    // If the 68K is reading from the RAM, then put its contents on BD, else set BD to high-z so other stuff can use it
    // As with some other signals, BD can be driven by multiple modules (I/O, CPU, and expansion cards), so we have to mux it in top.sv
    // So we have to make BD_out and BD_OE signals here that go to top.sv
    // We use a tri-state OE internally to make it easier to set the OE everywhere, and then we forward it to the standard logic output
    // We'll drive BD_out later when we drive it from IO_D as well
    // Same Quartus 'z-as-1 tri0 hazard as CPU_board's BD_OE (see note there):
    // replaced the two z-drivers with an explicit OR.
    assign BD_OE = (~FDC_RAM_addr_select & READ) | (A[12] & ~_INTIO & READ);

    // Thanks to a lack of tri-state logic, we have to do some multiplexing on the RAM, which is what RD_in is for
    logic [7:0] RD_in;
    // When low, the RAM is being accessed by the 68K and its contents should be put on the BD bus
    // When we're accessing the RAM from the 68K, put the 68K's data on the RAM's input lines, else put the 6504's data on it
    assign RD_in = (~FDC_RAM_addr_select) ? BD_in[7:0] : FD_out;

    // What addresses the RAM with the RA lines depends on whether the 68K or 6504 is accessing it
    // If the 68K is accessing it, then RA comes from A[10:1], else it comes from the 6504-generated MA[9:0]
    assign RA = (~FDC_RAM_addr_select) ? A[10:1] : MA[9:0];
    // Wow, that one line of code replaced three whole LS157 multiplexers on the original board

    // Before we get down to the middle part of the schematic with all the flip-flops and stuff, let's do the PROM state machine
    // It consists of a 6309 PROM just like the VSROM and an LS323 shift register, as well as an LS174 hex D flip-flop to latch the outputs
    // It's pure magic and basically works the same way as the floppy controller state machine on the Apple ][

    // The state machine's clock
    logic state_machine_clk;
    // This one comes from the output of a 2-to-4 decoder that decodes MA[5:4]
    logic [3:0] FDC_address_decoder_1;
    assign _state_machine_OE1 = FDC_address_decoder_1[0];
    // We don't actually use QH for anything, so just tie it to a dummy wire
    logic QH_dummy; 
    
    // Address and data lines for the PROM
    logic [7:0] PROM_address;
    logic [7:0] PROM_data;

    // Clock the shiftreg on C16M, but use state_machine_clk as a clock enable
    logic state_machine_clk_enable;
    LS323_shiftreg FDC_state_shiftreg(
        .clk(clk_sys),
        .clk_en(state_machine_clk_enable & c16m_en),
        //.clk(state_machine_clk),
        ._CLR(PROM_data[3]),
        ._OE1(_state_machine_OE1),
        ._OE2(MA[0]),
        .S0(PROM_data[1]),
        .S1(PROM_data[0]),
        .SR(SNS),
        .SL(PROM_data[2]),
        .D(FD_out),
        .Q(PSM_out),
        .QA(PROM_address[1]),
        .QH(QH_dummy)
    );

    // Now let's do the PROM; it's called the "P6A" on the schematics, which is the EXACT SAME PART used in the Apple ][ disk controller
    // Cool, right?

    // Initialize the PROM address to 0 on power-up; just for simulation
    // Otherwise, the address will be X and the PROM will output X, which will propagate through the LS323 and cause everything to break
    initial begin
        PROM_address = 8'b0;
    end

    PROM_6309 #(.ROM_file("P6A.mem")) floppy_state_machine(
        .A(PROM_address),
        ._E1(1'b0), // Permanently enabled
        ._E2(1'b0),
        .D(PROM_data)
    );

    // Now we'll simulate the LS174 hex D flip-flop that latches the PROM outputs
    // As with the PROM and LS323, this is pure magic based on whatever's in that PROM, so I'm not going to try to explain how it works
    // The flip-flops are clocked by the same state machine clock as the LS323

    // Two intermediate signals used to store multiple past states of RDA
    logic RDA_int1;
    logic RDA_int2;

    // Initialize the RDA intermediate signals to 1 on power-up, just for simulation
    // Just like with the PROM address, this prevents X propagation and everything breaking
    initial begin
        RDA_int1 = 1'b1;
        RDA_int2 = 1'b1;
    end

    // The LS174 itself
    // Clock it off C16M, but use the state machine clock as a clock enable
    always_ff @(posedge clk_sys) begin // state_machine_clk) begin
        if (c16m_en) begin
         if (state_machine_clk_enable) begin
            // Latch some of the PROM data outputs back into the PROM address lines
            PROM_address[7] <= PROM_data[7];
            PROM_address[6] <= PROM_data[6];
            PROM_address[5] <= PROM_data[4];
            PROM_address[0] <= PROM_data[5];
            // And store the last two states of RDA into RDA_int1 and RDA_int2
            RDA_int1 <= RDA;
            RDA_int2 <= RDA_int1;
         end
        end
    end

    // Address line 4 of the PROM is generated by a little combinational logic based on the RDA (read data from floppy) line
    // If we're on the rising edge of RDA (RDA just went from low to high), then make PROM_address[4] low
    // In all other cases, make it high
    // Since GCR encoding bases everything on transitions, this edge detector basically converts flux transitions to bits
    assign PROM_address[4] = ~(RDA_int1 & ~RDA_int2);

    // And also, the floppy disk WRD line gets pulled straight off the PROM address line 7, before it goes thru the flip-flop
    assign WRD = PROM_address[7];

    // DEBUG (ISSP "LSEQ", remove for release): capture the GCR byte stream the
    // P6A sequencer assembles from RDA (PSM_out). Shows whether the emulated
    // flux decodes to valid GCR bytes (D5 AA 96 ...) or garbage.
    // Rolling last-2 assembled bytes for mark detection + DATA-FIELD capture, to
    // diagnose the M5 floppy-boot data-field read bug (address field frames OK but
    // the 699-byte data field reads corrupted). Detect the data mark D5 AA AD, latch
    // the first 4 GCR bytes after it (dcap0..3), and flag whether the data field
    // reaches its DE AA epilogue with framing intact (seq_saw_depi) -> distinguishes
    // "framing breaks mid-field" (sync/drift) from "framed but wrong bytes" (checksum).
    reg [7:0]  seq_r0=0, seq_r1=0, seq_prev=0;
    reg [7:0]  dcap0=0, dcap1=0, dcap2=0, dcap3=0;
    reg [15:0] seq_valid_cnt=0;
    reg        seq_saw_addr=0;    // D5 AA 96 (address mark) seen
    reg        seq_saw_data=0;    // D5 AA AD (data mark) seen
    reg        seq_saw_depi=0;    // DE AA (data epilogue) seen inside a data field
    reg        seq_in_data=0;     // between a data mark and the next mark/epilogue
    reg        dcap_arm=0;
    reg [2:0]  dcap_n=0;
    // Per-byte accounting: for EVERY byte the sequencer assembles, how many times
    // did the 6504 actually latch it? 0 = the CPU missed the byte, 1 = correct,
    // >=2 = it read the same byte twice (a duplicate corrupts the 5-byte address
    // field just as badly as a drop). Only counted while the CPU is really
    // polling, else idle gaps would score as millions of misses. Saturating, so
    // these can never wrap and mislead the way the 16-bit totals did.
    reg [31:0] q7_at_last_byte = 32'd0;
    reg [19:0] byte_miss_cnt = 20'd0, byte_ok_cnt = 20'd0, byte_dup_cnt = 20'd0;
    always @(posedge clk_sys) begin
        if (c16m_en & state_machine_clk_enable) begin
            if (PSM_out[7] & (PSM_out != seq_prev)) begin   // a new assembled byte
                seq_valid_cnt <= seq_valid_cnt + 16'd1;
                q7_at_last_byte <= q7_msb_total;
                if (reading_active) begin
                    case (q7_msb_total - q7_at_last_byte)
                        32'd0:   if (~&byte_miss_cnt) byte_miss_cnt <= byte_miss_cnt + 20'd1;
                        32'd1:   if (~&byte_ok_cnt)   byte_ok_cnt   <= byte_ok_cnt   + 20'd1;
                        default: if (~&byte_dup_cnt)  byte_dup_cnt  <= byte_dup_cnt  + 20'd1;
                    endcase
                end
                if (seq_r1 == 8'hD5 && seq_r0 == 8'hAA && PSM_out == 8'h96) begin
                    seq_saw_addr <= 1'b1; seq_in_data <= 1'b0;
                end
                if (seq_r1 == 8'hD5 && seq_r0 == 8'hAA && PSM_out == 8'hAD) begin
                    seq_saw_data <= 1'b1; seq_in_data <= 1'b1;   // (re)arm capture on each data mark
                    dcap_arm     <= 1'b1; dcap_n <= 3'd0;
                end else if (seq_in_data && seq_r1 == 8'hDE && seq_r0 == 8'hAA) begin
                    seq_saw_depi <= 1'b1; seq_in_data <= 1'b0;
                end else if (dcap_arm) begin                     // 4 GCR bytes after the data mark
                    case (dcap_n)
                        3'd0:    dcap0 <= PSM_out;
                        3'd1:    dcap1 <= PSM_out;
                        3'd2:    dcap2 <= PSM_out;
                        default: dcap3 <= PSM_out;
                    endcase
                    if (dcap_n == 3'd3) dcap_arm <= 1'b0;
                    else                dcap_n   <= dcap_n + 3'd1;
                end
                seq_r1 <= seq_r0; seq_r0 <= PSM_out;
            end
            seq_prev <= PSM_out;
        end
    end

    // DEBUG (ISSP "L654", remove for release): watch the 6504 itself. Everything
    // upstream is proven (track buffer byte-exact, framing to the DE AA epilogue,
    // serializer 524/524, right sector requested AND presented) yet the 6504's
    // sector buffer never gets good data and it logs ZERO bitslip/checksum errors.
    // So: is it even reading the shift register, what does it get, and does it
    // ever store to the buffer?
    //   Our firmware is the new_io==0 / hardware_id==$A8 build, whose byte-read
    //   loop is  find_addr: lda q6l / L1281: lda q7l / bpl L1281  -- i.e. it
    //   polls **q7l ($040E)**, not q6l, spinning until MSB=1 (a valid GCR byte).
    //   Reading it returns PSM_out via the FD_in mux. If the 6504 never reads it,
    //   or always gets FF (the mux's fall-through) or MSB=0, that is the bug.
    //   dbg_pc_6504 maps straight onto the asm listing (6504 ROM is at $1000+),
    //   so a PC parked at ~$1281 means it is stuck in exactly that spin loop.
    // Sampled at the 6504's own phi, where MA/RW_FDC/FD_in all correspond.
    wire fdc_phi_dbg = FDC_counter_clock_enables_rising[2] & c16m_en;
    wire q7l_rd_dbg  = fdc_phi_dbg && (MA[12:0] == 13'h40E) && RW_FDC;
    wire q6l_rd_dbg  = fdc_phi_dbg && (MA[12:0] == 13'h40C) && RW_FDC;
    // the 6504 writing its 524-byte sector buffer ($01F4..$03FF) -- resolves the
    // "cleared then never filled" vs "never touched since power-up" ambiguity
    wire buf_wr_dbg  = fdc_phi_dbg && FDC_RAM_addr_select && !RW_FDC &&
                       (MA[12:0] >= 13'h1F4) && (MA[12:0] <= 13'h3FF);

    reg [15:0] dbg_pc_6504   = 16'd0;   // last ROM fetch address ~= PC
    reg [15:0] dbg_q7l_cnt   = 16'd0;   // reads of the data register
    reg [15:0] dbg_q6l_cnt   = 16'd0;
    reg [15:0] dbg_bufwr_cnt = 16'd0;
    reg  [7:0] dbg_fd_at_q7l = 8'd0;    // what the 6504 actually got
    reg  [7:0] dbg_psm_at_q7l= 8'd0;    // what the sequencer had at that instant
    reg  [7:0] dbg_fd_msb_cnt= 8'd0;    // q7l reads that returned MSB=1 (valid GCR)
    reg  [7:0] dbg_fd_ff_cnt = 8'd0;    // q7l reads that returned FF (mux fall-through!)
    // THE decisive comparison: run LSEQ's EXACT mark detector, but on the byte
    // stream the 6504 actually samples at q7l instead of on PSM_out. LSEQ proves
    // PSM_out carries D5 AA 96 (saw_addr=1) yet find_addr times out, so if this
    // detector never fires the bug is the 6504's sampling/timing of the register,
    // not the GCR content. Change-detected (FD_in != prev) exactly like LSEQ,
    // because the 6504 polls faster than the byte rate and re-reads the same byte.
    reg  [7:0] q7_r0=0, q7_r1=0, q7_prev=0;
    reg  [7:0] q7_h0=0, q7_h1=0, q7_h2=0, q7_h3=0;   // last 4 distinct MSB=1 bytes
    reg [15:0] q7_msb_cnt=0;       // distinct valid bytes the 6504 saw
    reg [15:0] q7_addr_evt_cnt=0;  // times the 6504's OWN stream showed D5 AA 96
    always @(posedge clk_sys) begin
        if (fdc_phi_dbg && MA[12]) dbg_pc_6504 <= MA;
        if (q6l_rd_dbg) dbg_q6l_cnt <= dbg_q6l_cnt + 16'd1;
        if (q7l_rd_dbg) begin
            dbg_q7l_cnt   <= dbg_q7l_cnt + 16'd1;
            dbg_fd_at_q7l <= FD_in;
            dbg_psm_at_q7l<= PSM_out;
            if (FD_in[7])       dbg_fd_msb_cnt <= dbg_fd_msb_cnt + 8'd1;
            if (FD_in == 8'hFF) dbg_fd_ff_cnt  <= dbg_fd_ff_cnt  + 8'd1;
            if (FD_in[7] && (FD_in != q7_prev)) begin
                q7_msb_cnt <= q7_msb_cnt + 16'd1;
                if (q7_r1 == 8'hD5 && q7_r0 == 8'hAA && FD_in == 8'h96)
                    q7_addr_evt_cnt <= q7_addr_evt_cnt + 16'd1;
                q7_r1 <= q7_r0; q7_r0 <= FD_in;
                q7_h3 <= q7_h2; q7_h2 <= q7_h1; q7_h1 <= q7_h0; q7_h0 <= FD_in;
            end
            q7_prev <= FD_in;
        end
        if (buf_wr_dbg) dbg_bufwr_cnt <= dbg_bufwr_cnt + 16'd1;
    end

    // Free-running total of valid bytes the 6504 latched, plus an "is it polling
    // right now" gate. The LSEQ block samples the total at each new PSM_out byte;
    // the delta = how many times the CPU read THAT byte. 32-bit so the delta is
    // always meaningful (the old 16-bit counters wrapped, which made a
    // ratio-of-totals comparison garbage -- ratios came out >1).
    reg [31:0] q7_msb_total = 32'd0;
    reg [11:0] rd_active_tmr = 12'd0;         // ~50us @81.5MHz; a byte is 16us
    wire reading_active = |rd_active_tmr;
    always @(posedge clk_sys) begin
        if (q7l_rd_dbg && FD_in[7]) q7_msb_total <= q7_msb_total + 32'd1;
        if (q7l_rd_dbg)             rd_active_tmr <= 12'hFFF;
        else if (|rd_active_tmr)    rd_active_tmr <= rd_active_tmr - 12'd1;
    end

    // Now for the two LS259 addressable latches that hold the floppy drive control signals
    // This is pretty simple; they're addressed by MA[3:1] with the data on MA[0] and clocked by lines from a decoder we'll make later
    // One of the latch outputs is an intermediate signal used to form the state machine clock
    logic state_machine_clk_int;
    // The latch also outputs HDS, but it's the inverted HDS
    logic _HDS;
    addressable_latch_LS259 upper_FDC_latch(
        .clk(clk_sys),
        .A(MA[3:1]),
        .D(MA[0]),
        ._G(FDC_address_decoder_1[0] | ~c16m_en),
        ._CLR(_RESET),
        .Q({PROM_address[3], PROM_address[2], state_machine_clk_int, _HDS, PH[3:0]})
    );

    // _WRQ is just the inverted version of PROM_address[3], which was one of the outputs of the upper latch
    assign _WRQ = ~PROM_address[3];

    // Invert _HDS from the latch to get HDS
    assign HDS = ~_HDS;

    // We have to do the same inversion thing for DR0 and DR1, so make intermediate signals for them too
    logic DR0;
    logic DR1;
    // FDIR (floppy disk interrupt) and DISK_DIAG (set when the FDC is doing diagnostics) are also outputs from the lower latch
    logic FDIR;
    logic DISK_DIAG;
    // A latch output that's used to lock out CPU board accesses to the FDC RAM when the 6504 is using it
    logic DIS;
    // And a dummy bit we won't use
    logic dummy_bit;
    addressable_latch_LS259 lower_FDC_latch(
        .clk(clk_sys),
        .A(MA[3:1]),
        .D(MA[0]),
        ._G(FDC_address_decoder_1[1] | ~c16m_en),
        ._CLR(_RESET),
        .Q({FDIR, DISK_DIAG, dummy_bit, DIS, MT1, MT0, DR1, DR0})
    );

    // Synchronize the DISK_DIAG signal into the DOTCK clock domain so we can feed it to the DOTCK-clocked VIA
    (* ASYNC_REG = "TRUE" *) logic DISK_DIAG_int, DISK_DIAG_sync;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            DISK_DIAG_int <= DISK_DIAG;
            DISK_DIAG_sync <= DISK_DIAG_int;
        end
    end
    // Same deal for FDIR
    (* ASYNC_REG = "TRUE" *) logic FDIR_int, FDIR_sync;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            FDIR_int <= FDIR;
            FDIR_sync <= FDIR_int;
        end
    end
    
    // Do the inverted assignments for DR0 and DR1
    assign _DR0 = ~DR0;
    assign _DR1 = ~DR1;

    // Now let's do the main timing state machine that generates clocks for much of the FDC circuitry
    // It's a 4-bit binary counter that's fed by the 16MHz clock, and enabled by a combination of its Q1 output and a flip-flop
    // Whenever the Q3 bit goes low, it resets itself back to either 1000 or 1001 depending on the state of another flip-flop
    // The reset is done synchronously with the 16MHz clock
    // To avoid metastability, we'll implement clock enable strobes here too
    // That way, we can clock all the other parts of the FDC off C16M directly, and just gate their enables with these strobes
    logic [3:0] FDC_counter_clock_enables_falling;
    logic [3:0] FDC_counter_next;
    logic FDC_counter_enable;
    logic _DTACK_FF_1_output;
    logic already_reset;

    initial begin
        already_reset = 1'b0;
    end

    // Computer the next state of the counter combinationally; we'll register it on the clock edge later
    always_comb begin
        if (!FDC_counter[3]) begin
            // If Q3 is low, reset the counter to either 1000 or 1001 depending on the output of the DTACK flip-flop
            FDC_counter_next = {3'b100, _DTACK_FF_1_output};
        end else if (FDC_counter_enable) begin
            // Otherwise, if the counter is enabled, increment it
            FDC_counter_next = FDC_counter + 1;
        end else begin
            // And if it's not enabled, just hold the current value
            FDC_counter_next = FDC_counter;
        end
    end
        
    // Now register the counter on the rising edge of C16M
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        // The original counter didn't have a reset, but we need one to get a known state on power-up in an FPGA
        // Make sure to only do this once though, so we don't keep resetting the counter forever
        if (!_RESET && !already_reset) begin
            already_reset <= 1'b1;
            FDC_counter <= 4'b0000;
        end else begin
            // If we're not in reset, then set the counter to its next value computed earlier
            FDC_counter <= FDC_counter_next;
        end
      end
    end

    // And generate the clock enable strobes by comparing the current and next values
    assign FDC_counter_clock_enables_rising = FDC_counter_next & ~FDC_counter;
    assign FDC_counter_clock_enables_falling = ~FDC_counter_next & FDC_counter;

    // The counter is disabled when Q1 of the counter is high and the output of the secopnd flop-flop is deasserted
    // And also whenever we inhibit the counter to allow the RAM to unselect and reselect when switching between 68K and 6504 access
    // That third condition was added by me though; it's not part of the original design
    // Otherwise, it's enabled
    assign FDC_counter_enable = ((FDC_counter[1] && !FDC_RAM_addr_select) || FDC_counter_inhibit) ? 1'b0 : 1'b1;

    // Now we'll implement oone of the three flip-flops that controls the counter and the creation of _DTACK
    // _DTACK is only generated when the 68K is accessing the FDC, so it'll only be activated when the 68K is talking to us
    // The flip-flop is async preset whenever AS gets deasserted, indicating the end of a bus cycle
    // And it's clocked by the Q0 output of the counter
    // The D input goes low when we're addressing I/O with the _INTIO signal, A12 is low, and DIS is deasserted (the 68K isn't locked out)
    // High otherwise
    // The Q output determines whether the counter gets preset with 1000 or 1001, gets fed to another FF, and controls the OE for _DTACK
    // Setting the counter to 1000 is what happens when the 68K is accessing the FDC, and setting it to 1001 is what happens when it's not
    // So the state machine starts 1 state earlier when the 68K is accessing vs when it's not
    // Clock the FF on the rising edge of C16M; use a clock enable to simulate the rising edge of FDC_counter[0]

    initial begin
        _DTACK_FF_1_output = 1'b1;
    end

    // We're about to use AS in an always_ff block, so let's synchronize it to C16M first to avoid metastability
    (* ASYNC_REG = "TRUE" *) logic _AS_int, _AS_sync;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            _AS_int <= _AS;
            _AS_sync <= _AS_int;
        end
    end

    // We need to synchronize _INTIO too since it's also used in the same always_ff block
    (* ASYNC_REG = "TRUE" *) logic _INTIO_int, _INTIO_sync;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            _INTIO_int <= _INTIO;
            _INTIO_sync <= _INTIO_int;
        end
    end

    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        if (_AS_sync) begin
            // Original design was async preset on deasserted AS, but we do sync preset to avoid metastability
            _DTACK_FF_1_output <= 1'b1;
        // Otherwise, set or clear based on INTIO, A12, and DIS
        // But only if the clock enable for rising edge of FDC_counter[0] is set
        end else if (FDC_counter_clock_enables_rising[0]) begin
            if (!_INTIO_sync && !A[12] && !DIS) begin
                _DTACK_FF_1_output <= 1'b0;
            end else begin
                _DTACK_FF_1_output <= 1'b1;
            end
        end
      end
    end

    // Now we've got a second FF that's hooked up to the output of the first one, also async preset by AS
    // The only difference is that it's clocked by !PHI2 of the 6504 instead of Q0 of the counter
    // I think the purpose of this is to move the "DTACK enable" signal from the 68K's clock domain to the 6504's clock domain
    // Its Q output is used to flip the muxes that choose between the 68K and 6504 for the RAM address lines
    // And the _Q output gets gated with some other stuff to go to a third DTACK generator FF, as well as the RAM W/R line
    logic _PHI2;
    // _PHI2 is the inverted version of the 6504's PHI2 clock, which is just FDC_counter[2] in our case
    assign _PHI2 = ~FDC_counter[2];
    // Clock the FF on C16M to avoid metastability; we'll use clock enables to simulate the rising edge of _PHI2
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        if (_AS_sync) begin
            // Original design was async preset on deasserted AS, but we do sync preset to avoid metastability
            FDC_RAM_addr_select <= 1'b1;
        // D input is output of the first flop
        // Clocked on falling edge of FDC_counter[2] (AKA _PHI2)
        end else if (FDC_counter_clock_enables_falling[2]) begin
            if (_DTACK_FF_1_output) begin
                FDC_RAM_addr_select <= 1'b1;
            end else begin
                FDC_RAM_addr_select <= 1'b0;
            end
        end
      end
    end

    // And now onto the third and final flip-flop, which actually generates (an ungated version of) _DTACK
    // No async preset or clear on this one, just clock and D
    // Clock is the 16MHz clock, and D is goes low when Q1 of the counter is high and the output of the second FF is low, else high
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        if (FDC_counter[1] && !FDC_RAM_addr_select) begin
            _DTACK_ungated <= 1'b0;
        end else begin
            _DTACK_ungated <= 1'b1;
        end
      end
    end

    // Now we generate the actual _DTACK; it's _DTACK_ungated if the output from the first FF is low (68K accessing FDC), else high-z
    // As with VPA, we have to do some muxing on this in the top-level module since multiple boards can drive it
    logic _SEL9512;
    logic _PAUSE_9512;
    always_comb begin
        if (!_DTACK_FF_1_output) begin
            _DTACK_out = _DTACK_ungated;
            DTACK_OE = 1'b1;
        // The PAUSE output from the (yet to be created) 9512 is one of the things that can assert _DTACK, but only if the 9512 is selected
        // So let's do that now along with the FDC DTACK; if the chip is selected and pause is deasserted, then assert _DTACK
        end else if (!_SEL9512 && _PAUSE_9512) begin
            _DTACK_out = 1'b0;
            DTACK_OE = 1'b1;
        end else begin
            _DTACK_out = 1'b1;
            DTACK_OE = 1'b0;
        end
    end

    // Let's do some random combinational logic for things like chip selection and R/W signals now
    // These are dependent on a lot of the things that we've just generated

    // First, the R/W line for the FDC RAM, which is RW_FDC_RAM
    // This one's pretty complicated; it goes high (read) when either Q1 of the counter is high and the second FF output is low
    // Or when the RAM is being read by the 68K (which is when FDC_RAM_addr_select is high and READ is high)
    // Or when the RAM is being read by the 6504 (which is when FDC_RAM_addr_select is low and RW_FDC is high)
    // In all other cases, it goes low (write)
    assign RW_FDC_RAM = ((FDC_counter[1] && !FDC_RAM_addr_select) & (_PHI2)) | ((FDC_RAM_addr_select) ? RW_FDC : READ);

    // Now onto chip select for the FDC RAM, _FDC_RAM_CS
    // This goes low (enabled) when either the 68K is accessing the RAM (FDC_RAM_addr_select is low)
    // Or when the 6504 has the bus and the output of a yet-to-be-made decoder is asserted by both MA10 and MA12 from the 6504 being low
    logic [3:0] FDC_address_decoder_0;
    assign _FDC_RAM_CS = (FDC_RAM_addr_select) ? (FDC_address_decoder_0[0] | FDC_counter[2]) : 1'b0;

    // The I/O board ROM chip select, _IOROM_CE, is asserted (low) whenever the 6504 has the bus (FDC_RAM_addr_select high) and MA12 is high
    assign _IOROM_CE = (FDC_RAM_addr_select & MA[12]) ? 1'b0 : 1'b1;

    // Now let's make the state machine clock, state_machine_clk
    // It's goes high whenever either state_machine_clk_int (the intermediate clock from the LS259) is high
    // Or when Q1 from the counter is high, but not both (XOR)
    // The state_machine_clk_int signal from the LS259 latch is a control signal that can be set/cleared by the CPU at any time
    // And I was curious when/how that was used, so I took a look
    // It turns out that it's low most of the time, but the 6504 sets it high only during write ops (and I think format ops too)
    // And it stays high for the entire duration of the write operation
    // Since it's an XOR, this has the effect of essentially inverting the state machine clock during write operations
    // No idea why this is necessary, but I guess that's floppy disk wizardry for you
    assign state_machine_clk = state_machine_clk_int ^ FDC_counter[1];

    // The state_machine_clk is used as a clock (obviously), so we need to make a clock enable from it to avoid metastability
    logic state_machine_clk_next;
    logic FDC_counter_1_next;
    logic [3:0] FDC_counter_plus1;
    logic [3:0] FDC_counter_reset_value;
    // This is stupid, but we have to do it because apparently (FDC_counter + 1)[1] isn't valid syntax
    assign FDC_counter_plus1 = (FDC_counter + 1);
    // And same goes for the reset value
    assign FDC_counter_reset_value = {3'b100, _DTACK_FF_1_output};

    // We can't predict the next state of state_machine_clk_int since the CPU can set it at any time without warning
    // But at least we can predict the next state of FDC_counter[1], the other thing that gets XORed to make state_machine_clk
    // We need the next state since the clock enable has to be made one cycle before the actual rising edge
    always_comb begin
        if (!FDC_counter[3]) begin
            // If FDC_counter[3] is low, then the counter is being reset this cycle, so predict the next state accordingly
            // Here's where we use that dumb FDC_counter_reset_value signal from earlier
            FDC_counter_1_next = FDC_counter_reset_value[1];
        end else if (FDC_counter_enable) begin
            // Otherwise, if the counter is enabled, predict the next state based on incrementing the counter
            // And this is where the other stupid signal from above comes in; I have no idea why Vivado doesn't like (FDC_counter + 1)[1]
            FDC_counter_1_next = FDC_counter_plus1[1];
        end else begin
            // Else, the counter is disabled, so it stays the same
            FDC_counter_1_next = FDC_counter[1];
        end
        // Use that info to predict the next state_machine_clk
        state_machine_clk_next = state_machine_clk_int ^ FDC_counter_1_next;
    end

    // Finally, use that predicted next state to make the clock enable
    // The clock enable goes high whenever the current state is low and the next predicted state is high
    assign state_machine_clk_enable = ~state_machine_clk & state_machine_clk_next;
    logic state_machine_clk_prev;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            state_machine_clk_prev <= state_machine_clk;
        end
    end
    //assign state_machine_clk_enable = ~state_machine_clk_prev & state_machine_clk;

    // And last but not least for the FDC, the two decoders that generate some control signals
    // The first one is enabled whenever the 6504 has the bus (FDC_RAM_addr_select high), and decodes MA10 and MA12
    decoder_2to4 FDC_address_decoder_low(
        .AB({MA[12], MA[10]}),
        ._G(~FDC_RAM_addr_select),
        ._Y(FDC_address_decoder_0) // The 0 output is one of the two chip selects for the FDC RAM; the 1 output feeds into the second decoder
        // The 2 and 3 outputs are unused
    );

    // The second decodes MA4 and MA5, and is enabled whenever both output 1 of the first decoder is asserted (MA10 high, MA12 low)
    // And when _PHI2 is low too
    decoder_2to4 FDC_address_decoder_high(
        .AB({MA[5], MA[4]}),
        ._G(FDC_address_decoder_0[1] | ~_PHI2),
        ._Y(FDC_address_decoder_1) // The 0 and 1 outputs are used to clock the LS259 latches that hold the floppy drive control signals
        // The 2 and 3 outputs are unused
    );



    // That's it for the FDC, so now let's move onto Page 3, which is the parallel port VIA, 8530 SCC, and 9512 math coprocessor
    // We'll get the 9512 out of the way first; it's just some selection signals and the chip itself
    // But the Lisa never actually supported the 9512, so we'll just make an empty dummy 9512 module that does nothing

    // The read and write signals for the 9512
    logic _9512_RD;
    logic _9512_WR;
    // RD is asserted whenever READ is high and we've selected the 9512 with _SEL9512
    // And as you might guess, WR is asserted whenever READ is low and we've selected the 9512
    assign _9512_RD = (!_SEL9512 & READ) ? 1'b0 : 1'b1;
    assign _9512_WR = (!_SEL9512 & !READ) ? 1'b0 : 1'b1;

    // Now let's instantiate our dummy 9512 itself, which just sets all its outputs to their inactive states and not much else
    // We need to define signals for its PAUSE output, END output, and the 2MHz clock input, all of which we'll deal with later
    logic END_9512;
    logic C2M;

    // I/O board-wide 8-bit data bus
    tri [7:0] IO_D;
    logic [7:0] D_out_9512;

    // Now instantiate our dummy 9512 itself
    AM9512_FPU lisa_FPU(
        .C_D(A[3]), // We choose between the FPU's command and data registers with A3
        ._RD(_9512_RD),
        ._WR(_9512_WR),
        .RESET(~_RESET),
        .CLK(clk_sys), // Clock it with the 2MHz clock we'll make later
        ._EACK(1'b1), // Tie high like on original board
        ._SVACK(1'b1), // Same here
        ._CS(1'b0), // Lisa always keeps the chip selected
        .D_in(IO_D), // Hook the global I/O board data bus to the FPU data input
        .D_out(D_out_9512),
        .END_9512(END_9512),
        ._PAUSE(_PAUSE_9512)
    );


    // We put the 9512's output on the I/O board data bus whenever it's selected and being read from
    assign IO_D = (~_9512_RD & ~_SEL9512) ? D_out_9512 : 8'bz;

    // Now we'll move onto the 8530 SCC
    // Originally I was using a real external SCC as no good cores existed
    // But thanks to some excellent efforts by Naftaly Blum, now one does, so we'll use that

    // Define a few signals before instantiating the SCC core
    // First, the output data bus from the SCC
    logic [7:0] D_out_SCC;
    // Chip select and write enable for the SCC
    logic CS_SCC;

    // The SCC is selected whenever both VMA and AS are asserted
    assign CS_SCC = ~_VMA & ~_AS;

    // A write enable signal for the SCC that we'll generate later
    logic _WSIO;

    // Only put the SCC's output on the I/O board data bus when it's being selected and read from
    // We use another yet-to-be-made signal, _RSIO, for this, and do the same XOR with reset as before to see if we should be reading
    // In addition to the CS check, of course
    logic _RSIO;
    assign IO_D = (~(~_RESET_SYSTEM ^ _RSIO) & CS_SCC) ? D_out_SCC : 8'bz;

    logic _PSI;
    // The _PSI signal goes to the DCDB pin on the SCC, which is an input, and also goes to form part of the system NMI signal
    // If either PSI or the COP NMI is asserted, then the system NMI is asserted
    // So then what drives PSI if the SCC is an input not an output?
    // Well, it's tied to a set of NAND gates that are hard-wired to pull it high all the time, so it never actually does anything
    // My guess is that it was planned to be used for something else but never was
    // Regardless, we can just tie it high ourselves too
    assign _PSI = 1'b1;

    // Now go ahead and instantiate the SCC core
    z8530_scc absolutely_amazing_scc_implementation (
        .clk(clk_sys), // Use the DOTCK as the main "fast clock" for the SCC
        .pclk(clk_sys), // Also feed in our 4MHz clock for use on Serial A
        .sclk(clk_sys), // And then feed the 3.68MHz clock for Serial B as well
        .reset_n(_RESET_SYSTEM), // Active-low reset; make sure to use the DOTCK-synchronized one not the C16M one
        .cs_n(~CS_SCC), // Chip select, read, and write strobes, all active-low
        .rd_n(_RSIO), 
        .wr_n(_WSIO),
        .a_b(A[1]), // Channel select is just A[1]
        .d_c(A[2]), // And data/control select is A[2]
        .data_in(IO_D), // Data bus input/output from IO_D
        .data_out(D_out_SCC),
        .data_oe(), // We don't need to use the data output enable since we're doing it with tri-state logic on IO_D
        .int_n(_RSIR), // The SCC's interrupt line
        .intack_n(1'b1), // We don't use the SCC's interupt acknowledge functionality, so just tie it high (inactive)
        // Now wire up the Serial A port
        .rxca(RTXCA), // RX clock input
        .txca(TRXCA), // TX clock input
        .rxda(RXDA), // RX data input
        .txda(TXDA), // TX data output
        .ctsa_n(CTSA), // CTS input, active low
        .dcda_n(DCDA), // DCD input, active low
        .synca_n(SYNCA), // DSR input, active low
        .rtsa_n(RTSA), // RTS output, active low
        .dtra_n(DTRA), // DTR output, active low
        // And the Serial B port
        .rxcb(clk_sys), // RX clock input, hooks to the 3.68MHz crystal on the I/O board
        .txcb(CTSB_TRXCB), // TX clock input, tied together with CTSB
        .rxdb(RXDB), // RX data input
        .txdb(TXDB), // TX data output
        .ctsb_n(CTSB_TRXCB), // CTS input, active low, tied together with TXCB
        .dcdb_n(_PSI), // DCD input, active low, always tied high unless a PFG is connected
        .syncb_n(1'b0), // Tied to the 3.68MHz crystal on the real Lisa, grounded here
        .rtsb_n(RTSB), // RTS output, active low
        .dtrb_n(DTRB) // DTR output, active low
    );

    // Now we can do the parallel port VIA, which is pretty much exclusively dedicated to handling comms with the ProFile
    // We'll be using a 6522 VIA core from the NanoMac project again, but unlike the SCC, this one's full-featured and very accurate

    // First, let's define the ProFile internal data bus (which also happens to go to the contrast latch)
    logic [7:0] SD_in;
    logic [7:0] SD_out;
    // And now ungated versions of the ProFile control signals
    logic _PSTRB_ungated;
    logic _CMD_ungated;
    logic OCD_ungated;

    // We also need a WCNT signal to write stuff into the contrast latch
    logic WCNT;
    // As well as an IRQ from the VIA
    logic _IRQ_PP_VIA;
    logic IRQ_PP_VIA;
    assign _IRQ_PP_VIA = ~IRQ_PP_VIA;
    // We also need two parity signals: one for the parity of the data being sent to the ProFile, and one for the data coming from it
    logic parity_out;
    // The input parity is latched so that we can still read it after the drive has changed the data lines
    logic latched_parity_in;

    // We also need a selection signal called DSKPT, which we'll generate later
    logic _DSKPT;

    // As well as the VIA's data output lines
    logic [7:0] D_out_PP_VIA;

    // We also need signals for some of the VIA's I/O lines so that we can selectively assign bits to some of these other signals
    logic [7:0] port_b_in_PP_VIA;
    logic [7:0] port_b_out_PP_VIA;

    // And last but not least, a VIA chip select signal, which will active whenever both _DSKPT and VMA are asserted
    logic CS_PP_VIA;
    assign CS_PP_VIA = ~_DSKPT & ~_VMA;

    // We also need to sample all of the control signals from the ProFile at the E edge instead of the DOTCK edge
    // The VIA implementation is being clocked at DOTCK instead of the E clock like the original
    // Meaning that the ProFile control signals we be sampled or asserted (depending on input vs output) much faster than an E-clocked VIA
    // This can cause weirdness with the control signals not being asserted for long enough or being sampled too early
    // So we need to sample all of the signals at the E edge before feeding them into the VIA or feeding them out to the ProFile
    // No need to do PRES or OCD since they're both always asserted for long periods of time
    logic _CMD_E_sampled, _BSY_E_sampled, PR_W_E_sampled, _PSTRB_E_sampled, latched_parity_in_E_sampled;
    always_ff @(posedge clk_sys) begin
      if (dotck_en) begin
        if (E_pos_phase || E_neg_phase) begin
            // Whenever we see an E edge (rising or falling), sample all the control signals
            _CMD_E_sampled <= _CMD_ungated;
            _BSY_E_sampled <= _BSY;
            PR_W_E_sampled <= PR_W_ungated;
            _PSTRB_E_sampled <= _PSTRB_ungated;
            latched_parity_in_E_sampled <= latched_parity_in;
        end
      end
    end

    logic [7:0] port_b_ddrb_pp_via;

    // And now we can instantiate the VIA with all this information
    via6522 pp_via(
        .clock(clk_sys), // Use DOTCK as the VIA's free-running clock
        .rising(E_pos_phase & dotck_en), // Use our rising and falling edge E strobes as our clock enables
        .falling(E_neg_phase & dotck_en),
        .reset(~_RESET_SYSTEM), // Systemwide reset
        .addr(A[6:3]), // RS0-RS3 address lines come from A3 to A6
        .wen(CS_PP_VIA & ~READ), // We write when the chip is selected and READ is low
        .ren(CS_PP_VIA & READ), // We read when the chip is selected and READ is high
        .data_in(IO_D), // Data input comes from the global I/O board data bus
        .data_out(D_out_PP_VIA),
        .port_a_o(SD_out), // Port A is the ProFile data bus
        .port_a_i(SD_in),
        .port_b_o(port_b_out_PP_VIA), // These two composite signals for Port B are about to be broken out into their individual bits
        .port_b_i(port_b_in_PP_VIA),
        .port_b_t(port_b_ddrb_pp_via), // We need this DDRB signal to know which bits of Port B are inputs vs outputs
        .ca1_i(_BSY_E_sampled), // CA1 comes from the E-sampled version of _BSY
        .ca2_o(_PSTRB_ungated), // CA2 goes to the ungated version of _PSTRB
        .ca2_i(1'b0), // Make sure the unused CA2 input is tied to a known state
        .cb1_i(END_9512), // CB1 comes from the END output of the 9512
        .cb2_i(latched_parity_in_E_sampled), // CB2 comes from the latched input parity, but the E-sampled version
        .irq(IRQ_PP_VIA) // And of course IRQ goes out to the IRQ signal
    );

    // Only put the VIA's output data on the global I/O board data bus when it's being selected and read from
    assign IO_D = (CS_PP_VIA & READ) ? D_out_PP_VIA : 8'bz;

    // Hook the SD bus to the ProFile bus; the SD input bus should always reflect the ProFile bus
    // So that's PD_in if we're reading from the ProFile, and PD_out if we're writing to it
    assign SD_in = DR_W ? PD_in : PD_out;
    // The SD output bus should only drive the ProFile bus whenever _ProFile_EN is low and we're writing to the ProFile (PR_W low)
    assign PD_out = (~_ProFile_EN & ~DR_W) ? SD_out : 8'b0;

    // Now time to break out the individual bits of Port B
    assign port_b_in_PP_VIA[0] = OCD_ungated; // PB0 is OCD
    assign port_b_in_PP_VIA[1] = _BSY_E_sampled; // PB1 is the E-sampled version of _BSY, it's not gated by _ProFile_EN
    assign _ProFile_EN = port_b_out_PP_VIA[2]; // PB2 is the ProFile communications enable
    assign PR_W_ungated = port_b_out_PP_VIA[3]; // PB3 is PR_W
    assign _CMD_ungated = port_b_out_PP_VIA[4]; // PB4 is _CMD
    assign port_b_in_PP_VIA[5] = parity_out; // PB5 is the output parity
    assign port_b_in_PP_VIA[6] = DISK_DIAG_sync; // PB6 is the DOTCK-synchronized DISK_DIAG from the FDC
    assign WCNT = port_b_ddrb_pp_via[7] ? port_b_out_PP_VIA[7] : 1'b0; // PB7 is WCNT, but only when it's an output
    // Put the unused input bits of Port B into known states
    assign port_b_in_PP_VIA[4:2] = 3'b111;
    assign port_b_in_PP_VIA[7] = 1'b1;

    // Now we need to gate all those ungated ProFile control signals with the ProFile communications enable signal
    // Make sure to use the E-sampled versions of the signals, not the raw ones
    // Feed the ProFile emulator the RAW (un-E-sampled) Lisa->drive control
    // signals. The emulator runs on clk_sys (81.5MHz) and must respond to each
    // per-byte _PSTRB strobe within the host's strobe->next-read window; the
    // E-sampling added up to ~0.5us of latency, so an occasionally-short window
    // let the host read a stale/mid-transition byte -> intermittent read
    // corruption (ProFile "boot device read failed" / crashes deep into the OS
    // load). Raw signals cut the emulator's strobe response to a few clk_sys
    // cycles. (The reverse-direction _BSY / parity into the E-clocked VIA stay
    // E-sampled — see _BSY_E_sampled / latched_parity_in_E_sampled above.)
    assign DR_W = (~_ProFile_EN) ? PR_W_ungated : 1'b1;
    assign _PSTRB = (~_ProFile_EN) ? _PSTRB_ungated : 1'b1;
    assign _CMD = (~_ProFile_EN) ? _CMD_ungated : 1'b1;
    assign OCD_ungated = (~_ProFile_EN) ? OCD : 1'b1;
    //assign _BSY_ungated = (~_ProFile_EN) ? _BSY : 1'b1;

    // DEBUG (bring-up ISSP "LPEN", remove for release): does the Lisa's parallel
    // VIA ever ENABLE the ProFile? _CMD to the emulator is gated by _ProFile_EN
    // (PB2). If pen_fall_cnt stays 0, the boot ROM never runs the ProFile boot/
    // scan (the STARTUP-FROM menu blocked it) -> emulator never commanded. If
    // pen_fall_cnt > 0 but the emulator still sees no _CMD, the gating/wiring is
    // broken. cmdu_edge_cnt = raw VIA PB4(_CMD) toggles regardless of the gate.
    logic [15:0] dbg_pen_fall_cnt /*verilator public_flat_rd*/ = 0;
    logic [15:0] dbg_cmdu_edge_cnt /*verilator public_flat_rd*/ = 0;
    logic [3:0]  dbg_cmd_while_en /*verilator public_flat_rd*/ = 0; // _CMD_ungated falls while _ProFile_EN low
    logic dbg_pen_d = 1, dbg_cmdu_d = 1;
    always_ff @(posedge clk_sys) begin
        dbg_pen_d  <= _ProFile_EN;
        dbg_cmdu_d <= _CMD_ungated;
        if (dbg_pen_d && !_ProFile_EN)        dbg_pen_fall_cnt  <= dbg_pen_fall_cnt + 1'd1;
        if (dbg_cmdu_d != _CMD_ungated)       dbg_cmdu_edge_cnt <= dbg_cmdu_edge_cnt + 1'd1;
        // Decisive: does the Lisa actually assert _CMD *while it has the ProFile
        // enabled*? If this stays 0 the Lisa only reads status lines and aborts;
        // if >0 but the emulator's cmd_edges doesn't climb, the gate/E-sample
        // datapath is dropping the command.
        if (dbg_cmdu_d && !_CMD_ungated && !_ProFile_EN)
            dbg_cmd_while_en <= dbg_cmd_while_en + 1'd1;
    end
    // (No standalone probe: the design is at device capacity, so these fields are
    // folded into the existing LIO probe instance below to avoid a new JTAG node.)

    // Let's also make the _IOIR (I/O interrupt) signal, which gets asserted whenever either the VIA or FDC assert their IRQs
    // On the real board, this is an open-collector wired-OR signal (the CPU board can assert it too), but we have to do it differently here
    // That's because the synthesizer doesn't support multiple drivers on a single signal if the drivers are split between modules
    // So we'll make it a regular binary signal and handle the ORing of it with the CPU board's _IOIR in the CPU board module
    assign _IOIR = (~_IRQ_PP_VIA | FDIR) ? 1'b0 : 1'b1;

    // Time to do some parity stuff now, using our LS280 parity generator/checker modules
    // We hook one to the SD bus, which checks the input parity from the ProFile
    logic parity_ff_input;
    parity_generator_LS280 ProFile_input_parity_checker(
        .ABCDEFGHI({SD_in, _PARITY}),
        .EVEN(parity_ff_input)
    );

    // Its output goes into a flip-flop that latches the parity so we can still read it after the ProFile changes the data lines
    // The FF is clocked by _PSTRB_ungated, and it gets set whenever the EVEN output from the parity checker is high
    // The only thing that can reset it is an asynchronous reset from _PRES, which we've made synchronous here
    // So this FF basically stays idle while parities are good (not even), and then locks itself on whenever a parity error occurs
    /*logic _PRES;
    always_ff @(posedge _PSTRB_ungated, negedge _PRES) begin
        if (!_PRES) begin
            latched_parity_in <= 1'b0;
        end else begin
            if (parity_ff_input) begin
                latched_parity_in <= 1'b1;
            end
        end
    end*/
    logic _PRES;

    // We need to synchronize _PSTRB into the DOTCK domain since the parity FF that uses it is clocked by DOTCK
    (* ASYNC_REG = "TRUE" *) logic _PSTRB_ungated_int, _PSTRB_ungated_sync;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            _PSTRB_ungated_int <= _PSTRB_ungated;
            _PSTRB_ungated_sync     <= _PSTRB_ungated_int;
        end
    end

    logic _PSTRB_ungated_prev;
    always_ff @(posedge clk_sys) begin
      if (dotck_en) begin
        if (!_PRES) begin
            latched_parity_in <= 1'b0;
        end else if (_PSTRB_ungated_sync && !_PSTRB_ungated_prev) begin
            if (parity_ff_input) begin
                latched_parity_in <= 1'b1;
            end
        end
        _PSTRB_ungated_prev <= _PSTRB_ungated_sync;
      end
    end

    // And another to the PD_out bus, which generates the parity of the outgoing data to the ProFile
    // This one's simpler; no latching or anything, just a straight parity output to PB5 of the VIA
    parity_generator_LS280 ProFile_output_parity_generator(
        .ABCDEFGHI({PD_out, 1'b0}), // The 9th input is tied to 0 to make odd parity
        .ODD(parity_out)
    );


    // Now onto Page 2, which contains a little bit of address decoding and clock logic, as well as the COP421 and keyboard VIA
    // First, let's generate two clocks, C4M and C2M, by dividing C16M down
    logic [2:0] clock_divider;
    always_ff @(posedge clk_sys, negedge _RESET) begin
        if (!_RESET) begin
            // Reset the clock divider to 0 on a system reset
            clock_divider <= 3'b000;
        end else if (c16m_en) begin
            // Otherwise, increment it on each 16MHz clock cycle
            clock_divider <= clock_divider + 1'b1;
        end
    end

    // And now use BUFGs to put the divided-down clocks onto global clock nets
    BUFG C4M_bufg(
        .I(clock_divider[1]), // C4M is the second bit of the clock divider (divided by 4)
        .O(C4M)
    );

    BUFG C2M_bufg(
        .I(clock_divider[2]), // C2M is the third bit of the clock divider (divided by 8)
        .O(C2M)
    );
    
    // Now let's do some address decoding stuff to generate _DSKPT, _SEL9512 _VPA, _RSIO, and _WSIO
    // The (non-FDC portion of the) I/O board is only selected when A12 high and _INTIO is asserted
    // When selected, the particular device is chosen based on A9, A10, and A11
    // When A10 and A11 are both low, and A9 is high, we select the SCC, asserting either _RSIO or _WSIO based on the state of READ
    // When A10 is high and A11 is low, we assert _SEL9512 to select the FPU
    // When A10 is low and A11 is high, we assert _DSKPT to select the parallel port VIA
    // And when A10 and A11 are both high, we assert _CS_KBD_VIA to select the keyboard VIA
    // Selecting the SCC or either of the VIAs also asserts _VPA to tell the 68K that it's a valid peripheral address
    // We'll accomplish all this with two 2-to-4 decoders
    logic _CS_KBD_VIA;
    logic _CS_SCC_decoder;
    logic dummy_output1, dummy_output2;
    decoder_2to4 IO_board_address_decoder(
        .AB({A[11], A[10]}), // We're decoding A10 and A11 here
        ._G(~(~_INTIO & A[12])), // Decoder only enabled when A12 is high and _INTIO is asserted
        ._Y({_CS_KBD_VIA, _DSKPT, _SEL9512, _CS_SCC_decoder}) // The outputs go to the various chip selects, the LSB enables the SCC decoder
    );
    decoder_2to4 IO_board_SCC_decoder(
        .AB({READ, A[9]}), // This time, decode A9 and READ
        ._G(_CS_SCC_decoder), // Enable whenever the primary decoder selects it
        ._Y({_RSIO, dummy_output1, _WSIO, dummy_output2}) // Feed the outputs to the SCC
    );

    // And don't forget about _VPA!
    // Which we assert whenever either the keyboard VIA, parallel port VIA, or SCC is selected
    // But as with _VPA on the CPU board, we have to do the VPA muxing in the top-level module to avoid multiple drivers on one signal
    // So we do a VPA and a VPA_OE so the mux knows when to drive the signal
    assign _VPA_out = (~_CS_KBD_VIA | ~_DSKPT | ~_CS_SCC_decoder) ? 1'b0 : 1'bz;
    assign VPA_OE = (~_CS_KBD_VIA | ~_DSKPT | ~_CS_SCC_decoder);

    // Now we'll do the mux that gets keyboard and mouse data from the peripherals to the COP
    // It's a dual 4-to-1 mux, with the select lines coming from the COP, and the data lines coming from the keyboard and mouse
    logic [1:0] KBD_mouse_mux_sel /*verilator public_flat_rd*/; // A is LSB, B is MSB
    logic [1:0] KBD_mouse_data_out /*verilator public_flat_rd*/; // X is LSB, Y is MSB

    always_comb begin
        case (KBD_mouse_mux_sel)
            // Send the appropriate two bits from the keyboard/mouse to the COP based on the select lines
            2'b00: KBD_mouse_data_out = {M[6], M[2]}; // Mouse right and left
            2'b01: KBD_mouse_data_out = {M[1], M[4]}; // Mouse down and up
            2'b10: KBD_mouse_data_out = {M[5], M[0]}; // Mouse switch 0 and switch 1
            2'b11: KBD_mouse_data_out = {KBD_in, M[3]}; // Keyboard data and mouse switch 2 (which is apparently hooked to parallel port pin 5?)
        endcase
    end

    // Now we need to make the COP, but first define some signals that connect to it
    // First up, the NMI that it can send to the CPU board
    // It's got to be a wire in order to keep the COP from getting mad during synthesis
    logic _NMI_COP /*verilator public_flat_rd*/;
    // NMI gets asserted when either the COP's NMI output is asserted, or the SCC's (_PSI) is
    assign _NMI = _NMI_COP & _PSI;
    // We have to mux NMI with the NMI from the interrupt switch in top.sv, so we need an OE signal for it too
    assign NMI_OE = ~_NMI_COP | ~_PSI;
    // The reset signal that it can send to the keyboard
    logic KBD_reset_COP;
    // Another reset signal that comes from the keyboard VIA
    logic _KBD_reset_VIA;
    // The power switch signal that goes to the COP
    // Same deal about being a wire
    wire _PWRSW_COP /*verilator public_flat_rd*/;
    // And the signals used to communicate between the COP and the keyboard VIA
    // The L bus is a bidirectional 8 bit data bus used to send commands and data between the COP and the VIA
    logic [7:0] L_COP_out;
    logic [7:0] L_COP_in;
    // The READY signal is driven by the COP over its D3 pin (to VIA pin PB6) to tell the VIA when it's ready to receive a command
    logic _READY_COP;
    // This is the SI (shift in) pin on the COP. It's used to acknowledge to the COP that we've read a byte off its L bus
    logic READ_ACK_COP;
    // This is the SO (shift out) pin on the COP, which hooks to VIA pin CA1. It gets asserted whenever the COP has data ready for the VIA
    logic DATA_QUEUED_COP /*verilator public_flat_rd*/;
    
    // Go ahead and make synchronizers that sync _READY and DATA_QUEUED to the DOTCK domain so we can feed them into a VIA
    // No need to sync the whole data bus because a flip-flop synchronizer can't work over multiple bits at once due to inter-bit skew
    // So just sync the control signals and use them as a metric to know when to read the data bus
    (* ASYNC_REG = "TRUE" *) logic _READY_COP_int, _READY_COP_sync;
    (* ASYNC_REG = "TRUE" *) logic DATA_QUEUED_COP_int, DATA_QUEUED_COP_sync;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            _READY_COP_int <= _READY_COP;
            _READY_COP_sync <= _READY_COP_int;
            DATA_QUEUED_COP_int <= DATA_QUEUED_COP;
            DATA_QUEUED_COP_sync <= DATA_QUEUED_COP_int;
        end
    end

    // We also need to sync the READ_ACK signal from the VIA to the COPCK_2x domain for the same reason
    (* ASYNC_REG = "TRUE" *) logic READ_ACK_COP_int, READ_ACK_COP_sync;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            READ_ACK_COP_int <= READ_ACK_COP;
            READ_ACK_COP_sync <= READ_ACK_COP_int;
        end
    end


    // The COP _PWRSW line gets asserted whenever the user hits the power switch, or the _RESET line goes low
    // Make sure the RESET condition only works when the system is on though
    // RESET is held asserted all the time while it's off, so otherwise the COP would think the power switch is being held down all the time
    // And since the COP refuses to start up the system until PWRSW is released, the system would never start
    assign _PWRSW_COP = _PWRSW; //& (_RESET | ~ON);

    // The KBD line is bidirectional, and we'll handle the tri-state output pin in top.sv
    // Here, just make an output signal that'll go to the keyboard pin's IOBUF when the COP wants to reset the keyboard
    // The COP or keyboard VIA asserts this low to reset the keyboard, and it goes high-z otherwise
    // Make sure that the VIA's reset is only valid when the reset pin is set as an output (DDRB[0]=1)
    // This prevents the VIA from sending an absurdly-long reset pulse to the keyboard when it's configured for input during system reset
    // We don't need a separate OE signal here; this can double as our OE since the keyboard line is open-collector
    logic [7:0] KBD_via_DDRB;
    assign KBD_out = ((KBD_reset_COP & KBD_mouse_mux_sel[1]) || (!_KBD_reset_VIA & KBD_via_DDRB[0])) ? 1'b0 : 1'b1;

    logic dummy_COP0, dummy_COP1, dummy_COP2; // Dummy wires for unused COP outputs
    logic [7:0] dummy_COP_L_en;
    logic [3:0] dummy_COP_D_en /*verilator public_flat_rd*/;
    logic [3:0] dummy_COP_G_en;
    logic dummy_COP_SO_en, dummy_COP_SK_en;

    // One other thing we need to do: turn COPCK into a clock enable that goes high the cycle before the rising edge of COPCK_2x
    logic COPCK_clk_enable /*verilator public_flat_rd*/;
    logic COPCK_core_enable /*verilator public_flat_rd*/ = 1'b0;
    logic COPCK_core_phase = 1'b0;
    always_ff @(posedge clk_sys) begin
        // Register the qualified pulse for a full master-clock cycle. Passing
        // the phase-accumulator carry directly into the converted VHDL core
        // lets it disappear during the same settle cycle in Verilator, leaving
        // the COP's internal divide counter permanently at its POR value.
        COPCK_core_enable <= 1'b0;
        if (copck2x_en) begin
            COPCK_core_phase <= ~COPCK_core_phase;
            COPCK_core_enable <= ~COPCK_core_phase;
            // Luckily we can make this simply by just inverting COPCK
            COPCK_clk_enable <= ~COPCK;
        end
    end

    `ifdef SIM_COP_STUB
    logic [5:0] sim_cop_byte_idx /*verilator public_flat_rd*/ = 6'd0;
    logic [1:0] sim_cop_seq_kind = 2'd0; // 1=keyboard reset, 2=clock response, 3=injected key
    logic [7:0] sim_cop_key_inject /*verilator public_flat_rw*/ = 8'h00;
    logic sim_cop_power_seen = 1'b0;
    logic sim_cop_started = 1'b0;
    logic sim_cop_ack_prev = 1'b1;
    logic sim_cop_kbd_reset_active = 1'b0;
    logic sim_cop_send_pending = 1'b0;
    logic sim_cop_cmd_active = 1'b0;
    logic sim_cop_cmd_pending = 1'b0;
    logic sim_cop_response_armed = 1'b0;
    logic [7:0] sim_cop_l_out_prev = 8'h80;
    logic sim_cop_ora_read_toggle = 1'b0;
    logic [19:0] sim_cop_gap_cnt = 20'd0;
    logic [11:0] sim_cop_hold_cnt = 12'd0;
    logic [11:0] sim_cop_power_cnt = 12'd0;
    logic [5:0] sim_cop_ready_cnt = 6'd0;

    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            logic kbd_reset_asserted;
            kbd_reset_asserted = (KBD_via_DDRB[0] && !_KBD_reset_VIA);

            if (!_PWRSW_COP) begin
                sim_cop_power_seen <= 1'b1;
                if (sim_cop_power_cnt != 12'hfff) sim_cop_power_cnt <= sim_cop_power_cnt + 1'b1;
            end

            if (!sim_cop_started && sim_cop_power_seen && (_PWRSW_COP || sim_cop_power_cnt == 12'hfff)) begin
                sim_cop_started <= 1'b1;
                ON <= 1'b1;
                _READY_COP <= 1'b0;
                KBD_mouse_mux_sel <= 2'b00;
                KBD_reset_COP <= 1'b1;
                DATA_QUEUED_COP <= 1'b0;
                L_COP_in <= 8'h80;
                sim_cop_byte_idx <= 6'd0;
                sim_cop_seq_kind <= 2'd0;
                sim_cop_gap_cnt <= 20'd0;
                sim_cop_hold_cnt <= 12'd0;
                sim_cop_kbd_reset_active <= 1'b0;
                sim_cop_send_pending <= 1'b0;
                sim_cop_cmd_active <= 1'b0;
                sim_cop_cmd_pending <= 1'b0;
                sim_cop_response_armed <= 1'b0;
                sim_cop_l_out_prev <= L_COP_out_int;
                sim_cop_ack_prev <= sim_cop_ora_read_toggle;
                sim_cop_ready_cnt <= 6'd31;
            end else if (sim_cop_started) begin
                KBD_reset_COP <= 1'b1;

                // CRDY is COP-driven. LOS waits for both edges before making
                // VIA port A an output, so CRDY cannot depend on DDRA already
                // being set to output as the old simulation shim required.
                if (sim_cop_ready_cnt == 6'd0) begin
                    sim_cop_ready_cnt <= 6'd31;
                    _READY_COP <= ~_READY_COP;
                end else begin
                    sim_cop_ready_cnt <= sim_cop_ready_cnt - 1'b1;
                end

                if (L_COP_out_int != sim_cop_l_out_prev) begin
                    if (L_COP_out_int == 8'h02) begin
                        sim_cop_cmd_pending <= 1'b1;
                    end
                    sim_cop_l_out_prev <= L_COP_out_int;
                end

                if (KBD_via_DDRA == 8'hff && !sim_cop_cmd_active) begin
                    sim_cop_cmd_active <= 1'b1;
                    if ((sim_cop_cmd_pending || L_COP_out_int == 8'h02) &&
                        sim_cop_seq_kind == 2'd0 && !DATA_QUEUED_COP && sim_cop_gap_cnt == 20'd0) begin
                        sim_cop_seq_kind <= 2'd2;
                        sim_cop_byte_idx <= 6'd0;
                        sim_cop_send_pending <= 1'b0;
                        sim_cop_response_armed <= 1'b1;
                        sim_cop_cmd_pending <= 1'b0;
                    end
                end else if (KBD_via_DDRA != 8'hff) begin
                    if (sim_cop_response_armed) begin
                        sim_cop_response_armed <= 1'b0;
                        sim_cop_send_pending <= 1'b1;
                        sim_cop_gap_cnt <= 20'd64;
                    end
                    sim_cop_cmd_active <= 1'b0;
                end

                if (kbd_reset_asserted) begin
                    sim_cop_kbd_reset_active <= 1'b1;
                end else if (sim_cop_kbd_reset_active) begin
                    sim_cop_kbd_reset_active <= 1'b0;
                    sim_cop_byte_idx <= 6'd0;
                    sim_cop_seq_kind <= 2'd1;
                    sim_cop_send_pending <= 1'b1;
                    sim_cop_gap_cnt <= 20'd625000;
                    DATA_QUEUED_COP <= 1'b0;
                    sim_cop_hold_cnt <= 12'd0;
                end else if (sim_cop_key_inject != 8'h00 && sim_cop_seq_kind == 2'd0 &&
                             !DATA_QUEUED_COP && sim_cop_gap_cnt == 20'd0 &&
                             !sim_cop_send_pending && !sim_cop_response_armed) begin
                    L_COP_in <= sim_cop_key_inject;
                    DATA_QUEUED_COP <= 1'b1;
                    sim_cop_seq_kind <= 2'd3;
                    sim_cop_byte_idx <= 6'd0;
                    sim_cop_hold_cnt <= 12'd0;
                    sim_cop_ack_prev <= sim_cop_ora_read_toggle;
                    sim_cop_key_inject <= 8'h00;
                end else if (sim_cop_gap_cnt != 20'd0) begin
                    DATA_QUEUED_COP <= 1'b0;
                    sim_cop_gap_cnt <= sim_cop_gap_cnt - 1'b1;
                    sim_cop_hold_cnt <= 12'd0;
                    if (sim_cop_gap_cnt == 20'd1 && sim_cop_send_pending) begin
                        if (sim_cop_seq_kind == 2'd2 && sim_cop_byte_idx == 6'd0) begin
                            L_COP_in <= 8'h80;
                        end else if (sim_cop_seq_kind == 2'd2 && sim_cop_byte_idx == 6'd1) begin
                            L_COP_in <= 8'he0;
                        end else if (sim_cop_byte_idx == 6'd0) begin
                            L_COP_in <= 8'h80;
                        end else if (sim_cop_seq_kind == 2'd1 && sim_cop_byte_idx == 6'd1) begin
                            L_COP_in <= 8'hbf;
                        end else begin
                            L_COP_in <= 8'h00;
                        end
                        DATA_QUEUED_COP <= 1'b1;
                        sim_cop_send_pending <= 1'b0;
                        sim_cop_ack_prev <= sim_cop_ora_read_toggle;
                    end
                end else if (DATA_QUEUED_COP && sim_cop_ora_read_toggle != sim_cop_ack_prev) begin
                    DATA_QUEUED_COP <= 1'b0;
                    sim_cop_byte_idx <= sim_cop_byte_idx + 1'b1;
                    sim_cop_hold_cnt <= 12'd0;
                    if ((sim_cop_seq_kind == 2'd1 && sim_cop_byte_idx == 6'd0) ||
                        (sim_cop_seq_kind == 2'd2 && sim_cop_byte_idx < 6'd6)) begin
                        sim_cop_send_pending <= 1'b1;
                        sim_cop_gap_cnt <= 20'd64;
                    end else begin
                        sim_cop_seq_kind <= 2'd0;
                    end
                end else if (DATA_QUEUED_COP && sim_cop_hold_cnt == 12'hfff) begin
                    sim_cop_hold_cnt <= 12'hfff;
                end else if (DATA_QUEUED_COP && sim_cop_hold_cnt != 12'hfff) begin
                    sim_cop_hold_cnt <= sim_cop_hold_cnt + 1'b1;
                end
            end else begin
                ON <= 1'b0;
                _READY_COP <= 1'b1;
                KBD_mouse_mux_sel <= 2'b00;
                KBD_reset_COP <= 1'b1;
                DATA_QUEUED_COP <= 1'b0;
                L_COP_in <= 8'h80;
                sim_cop_gap_cnt <= 20'd0;
                sim_cop_hold_cnt <= 12'd0;
                sim_cop_kbd_reset_active <= 1'b0;
                sim_cop_send_pending <= 1'b0;
                sim_cop_seq_kind <= 2'd0;
                sim_cop_cmd_active <= 1'b0;
                sim_cop_cmd_pending <= 1'b0;
                sim_cop_response_armed <= 1'b0;
                sim_cop_l_out_prev <= L_COP_out_int;
                sim_cop_ready_cnt <= 6'd0;
            end

            if (!(sim_cop_started && (sim_cop_gap_cnt != 20'd0 || DATA_QUEUED_COP))) begin
                sim_cop_ack_prev <= sim_cop_ora_read_toggle;
            end
            _NMI_COP <= 1'b1;
        end
    end
    `else
    `ifdef SIMULATION
    // Keep the headless simulator's COP observability/injection hooks present
    // when the real COP is instantiated. The old behavioral COP is now opt-in;
    // sim_cop_key_inject is consumed only by that stub until the headless path
    // drives the real keyboard serial interface.
    logic [5:0] sim_cop_byte_idx /*verilator public_flat_rd*/ = 6'd0;
    logic [7:0] sim_cop_key_inject /*verilator public_flat_rw*/ = 8'h00;
    logic sim_cop_ora_read_toggle = 1'b0;
    `endif
    // Both the FPGA and the Verilator sim now use the GHDL-generated Verilog COP
    // (rtl/t420_notri.v), which has the VHDL generics (opt_ck_div=16, opt_type=1)
    // baked in at generation time — instantiate WITHOUT parameters.
    t420_notri cop421 (
        .ck_i(clk_sys),
        `ifdef SIMULATION
        .ck_en_i(COPCK_core_enable), // Registered enable required by the converted Verilog model.
        `else
        .ck_en_i(COPCK_clk_enable & copck2x_en), // Preserve the validated FPGA COP clock phase.
        `endif
        .reset_n_i(1'b1), // Other than power-on reset, which is handled internally, we never reset the COP because that would wipe the RTC
        .cko_i(1'b0), // Crystal clock mode does not use the external CKO input.
        .io_l_i(L_COP_out), // Hook up the bidirectional L bus
        .io_l_o(L_COP_in),
        .io_l_en_o(dummy_COP_L_en),
        .io_d_o({_READY_COP, KBD_mouse_mux_sel, ON}), // The D output bus is 4 bits, which we use for READY, the 2-bit mux select, and the ON signal
        .io_d_en_o(dummy_COP_D_en),
        .io_g_i({_PWRSW_COP, _NMI_COP, KBD_mouse_data_out[0], KBD_mouse_data_out[1]}), // The G bus is also 4 bits, and we use it to input PWRSW and the two keyboard/mouse data bits
        // The NMI input is unused (it's an output), but things break if we don't hook the corresponding NMI output to the input port
        // I learned this the hard way and spent far more time than I care to admit trying to figure out why the COP wasn't working
        .io_g_o({dummy_COP0, _NMI_COP, dummy_COP1, dummy_COP2}), // The only G output is for NMI, tie the others to dummy wires
        .io_g_en_o(dummy_COP_G_en),
        .io_in_i(4'b1111), // The I inputs don't even exist on the COP421, so just tie them to 1
        .si_i(READ_ACK_COP_sync), // SI is an input to the COP from CA2 on the VIA; used to tell the cop when we've read a byte off its bus; use the version that's synced to the COPCK domain
        .so_o(DATA_QUEUED_COP), // And the SO output goes to CA1 on the VIA, which is asserted whenever the COP has data ready for the VIA
        .so_en_o(dummy_COP_SO_en),
        .sk_o(KBD_reset_COP), // SK is the keyboard reset output from the COP
        .sk_en_o(dummy_COP_SK_en)
    );
    `endif

    // Now we'll do the keyboard VIA, which is another 6522 just like the parallel port VIA
    // Like the PP VIA, we need to be able to break out some of the I/O lines on Port B
    logic [7:0] port_b_in_KBD_VIA;
    logic [7:0] port_b_out_KBD_VIA;

    // We also need to create an output bus for the VIA of course
    logic [7:0] D_out_KBD_VIA;

    // We also need a chip select for the VIA
    // We already made the _CS_KBD_VIA signal earlier, but that's only half the picture; VMA also must be asserted
    logic CS_KBD_VIA;
    assign CS_KBD_VIA = ~_CS_KBD_VIA & ~_VMA;

    logic KBIR;
    assign _KBIR = ~KBIR;

    // DEBUG (bring-up ISSP "LIO", remove for release): monitor the keyboard-VIA
    // access path. VIA1 is reached through the 68k's 6800-style VPA/VMA/E cycle
    // (unlike the async parallel VIA), so if the boot ROM reports error 50
    // (COPS VIA), count each stage: VPA requested -> VMA response -> chip
    // select, plus last written/read data, to see where the chain breaks.
    logic [7:0] dbg_kv_wr_cnt = 0, dbg_kv_rd_cnt = 0;
    logic [7:0] dbg_vma_cnt = 0, dbg_vpa_cnt = 0, dbg_epos_cnt = 0;
    logic [7:0] dbg_kv_last_wr = 0, dbg_kv_last_rd = 0, dbg_kv_bd_at_wr = 0, dbg_kv_bd_nz = 0;
    logic [7:0] dbg_pp_io_nz = 0;
    logic [3:0] dbg_kv_last_addr = 0;
    logic       dbg_vma_d = 1, dbg_cskv_d = 1, dbg_kv_sel_d = 0;
    logic [7:0] dbg_kv_read_data /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_kv_read_ora /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_kv_read_ifr /*verilator public_flat_rd*/ = 0;
    logic [3:0] dbg_kv_read_addr /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_kv_read_count /*verilator public_flat_rd*/ = 0;
    logic       dbg_kv_read_so /*verilator public_flat_rd*/ = 0;
    logic       dbg_kv_read_ack /*verilator public_flat_rd*/ = 0;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            dbg_vma_d  <= _VMA;
            dbg_cskv_d <= _CS_KBD_VIA;
            dbg_kv_sel_d <= CS_KBD_VIA;
            if (dbg_vma_d && !_VMA)         dbg_vma_cnt <= dbg_vma_cnt + 1'd1;
            if (dbg_cskv_d && !_CS_KBD_VIA) dbg_vpa_cnt <= dbg_vpa_cnt + 1'd1;
            if (E_pos_phase)                dbg_epos_cnt <= dbg_epos_cnt + 1'd1;
            if (CS_KBD_VIA && !dbg_kv_sel_d) begin // first tick of each selected access
                dbg_kv_last_addr <= A[4:1];
                if (READ) begin
                    dbg_kv_rd_cnt <= dbg_kv_rd_cnt + 1'd1;
                end else begin
                    dbg_kv_wr_cnt <= dbg_kv_wr_cnt + 1'd1;
                end
            end
            if (dbg_kv_sel_d && !CS_KBD_VIA && READ) dbg_kv_last_rd <= D_out_KBD_VIA; // capture at access end
            if (CS_KBD_VIA && READ && E_neg_phase) begin
                dbg_kv_read_count <= dbg_kv_read_count + 1'b1;
                dbg_kv_read_addr <= A[4:1];
                dbg_kv_read_data <= D_out_KBD_VIA;
                dbg_kv_read_ora <= (L_COP_out_int & KBD_via_DDRA) | (L_COP_in & ~KBD_via_DDRA);
                // kbd_via.irq_flags is a hierarchical reference into the VIA
                // instance: Verilator supports it (marked public_flat_rd) but
                // Quartus synthesis cannot resolve it. dbg_kv_read_ifr is a
                // sim-only debug signal, so drive the VIA's flags only in sim.
`ifdef SIMULATION
                dbg_kv_read_ifr <= {KBIR, kbd_via.irq_flags};
`else
                dbg_kv_read_ifr <= {KBIR, 7'b0};
`endif
                dbg_kv_read_so <= DATA_QUEUED_COP_sync;
                dbg_kv_read_ack <= READ_ACK_COP;
            end
            `ifdef SIMULATION
            if (CS_KBD_VIA && READ && E_neg_phase && A[4:1] == 4'h1) begin
                sim_cop_ora_read_toggle <= ~sim_cop_ora_read_toggle;
            end
            `endif
            // Capture the data path at the exact moment the via6522 model latches
            // a write (wen & E-falling strobe): IO_D is what the VIA sees,
            // BD_in[7:0] is what the CPU/top mux delivered. Nonzero BD with zero
            // IO_D = the IO_D driver condition is broken; both zero = CPU/top side.
            if (CS_KBD_VIA && !READ && E_neg_phase) begin
                dbg_kv_last_wr <= IO_D;
                dbg_kv_bd_at_wr <= BD_in[7:0];
            end
            // Latch ANY nonzero write data seen on BD during a kbd-VIA write
            // window: distinguishes "data never present" from "data gone by the
            // E-falling strobe".
            if (CS_KBD_VIA && !READ && BD_in[7:0] != 8'h00) begin
                dbg_kv_bd_nz <= BD_in[7:0];
            end
            // Control: same sticky capture for the parallel VIA (async/DTACK
            // device whose identical ROM test PASSES) — proves the working
            // write path really carries nonzero data through IO_D.
            if (CS_PP_VIA && !READ && IO_D != 8'h00) begin
                dbg_pp_io_nz <= IO_D;
            end
        end
    end
    `ifndef SIMULATION
    altsource_probe #(
        .sld_auto_instance_index ("YES"), .sld_instance_index (0),
        .instance_id ("LIO"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    // LIO now repurposed for ProFile-enable diagnosis (error-50 keyboard-VIA
    // debug is solved). Layout: [63:48]=pen_fall_cnt [47:32]=cmdu_edge_cnt
    // [31:24]=kv_wr_cnt [23:16]=kv_rd_cnt [15:8]=pp_io_nz
    // [7]=_ProFile_EN [6]=_CMD_ungated [5]=_CMD [4]=_PSTRB [3:0]=0
    ) u_io_probe ( .source(), .probe({
        dbg_pen_fall_cnt, dbg_cmdu_edge_cnt,
        dbg_kv_wr_cnt, dbg_kv_rd_cnt, dbg_pp_io_nz,
        _ProFile_EN, _CMD_ungated, _CMD, _PSTRB, dbg_cmd_while_en
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    // LSEQ: GCR read diagnosis. [63]=saw D5 AA 96 (addr mark) [62]=saw D5 AA AD
    //   (data mark) [61]=saw DE AA data epilogue (framing held to field end)
    //   [60]=FDIR_ever [59]=FDIR [47:32]=valid byte count
    //   [31:24]=dcap0 [23:16]=dcap1 [15:8]=dcap2 [7:0]=dcap3 (first 4 GCR bytes after data mark)
    reg fdir_ever = 1'b0;
    always @(posedge clk_sys) if (FDIR) fdir_ever <= 1'b1;
    altsource_probe #(
        .instance_id ("LSEQ"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_seq_probe ( .source(), .probe({
        seq_saw_addr, seq_saw_data, seq_saw_depi, fdir_ever, FDIR, 11'd0,
        seq_valid_cnt, dcap0, dcap1, dcap2, dcap3
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    // LFDR: FDC-RAM dump. source = 10-bit RAM address, probe [7:0] = that byte
    // (high nibble from high_FDC_RAM, low from low_FDC_RAM), [17:8] = the address
    // echoed back so a dump can verify the source actually landed.
    altsource_probe #(
        .instance_id ("LFDR"), .probe_width (32), .source_width (10),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_fdr_probe ( .source(dbg_fdr_A), .probe({
        14'd0, dbg_fdr_A, dbg_fdr_Dhi, dbg_fdr_Dlo
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    // L654: the 6504 itself. [63:48]=PC (last ROM fetch; maps onto the asm
    // listing, ROM at $1000+) [47:32]=q7l data-register read count
    // [31:16]=writes to the $01F4-$03FF sector buffer [15:8]=last FD_in at q7l
    // [7:0]=PSM_out at that same instant.
    altsource_probe #(
        .instance_id ("L654"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_6504_probe ( .source(), .probe({
        dbg_pc_6504, dbg_q7l_cnt, dbg_bufwr_cnt, dbg_fd_at_q7l, dbg_psm_at_q7l
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    // L65B: the 6504's OWN byte stream, via LSEQ's exact detector.
    // [63:48]=distinct MSB=1 bytes the 6504 saw [47:32]=times ITS stream showed
    // D5 AA 96 (compare against LSEQ.saw_addr on PSM_out!) [31:0]=last 4 distinct
    // valid bytes, newest in [7:0].
    altsource_probe #(
        .instance_id ("L65B"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_6504b_probe ( .source(), .probe({
        q7_msb_cnt, q7_addr_evt_cnt, q7_h3, q7_h2, q7_h1, q7_h0
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    // L65C: per-byte accounting of the 6504 vs the sequencer, over the SAME
    // window. [63:44]=bytes the CPU MISSED [43:24]=bytes read exactly once (OK)
    // [23:4]=bytes read 2+ times (DUPLICATE). Saturating 20-bit: no wrap.
    altsource_probe #(
        .instance_id ("L65C"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_6504c_probe ( .source(), .probe({
        byte_miss_cnt, byte_ok_cnt, byte_dup_cnt, 4'd0
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    `else
    assign dbg_fdr_A = 10'd0;   // sim: no JTAG source drives the dump port
    `endif

    logic READ_ACK_COP_ungated;
    logic ca2_oe;
    logic [7:0] L_COP_out_int /*verilator public_flat_rd*/;
    logic [7:0] KBD_via_DDRA /*verilator public_flat_rd*/;

    // And now we instantiate the chip
    via6522 kbd_via(
        .clock(clk_sys), // Use DOTCK as the VIA's free-running clock
        .rising(E_pos_phase & dotck_en), // Use our rising and falling edge E strobes as our clock enables
        .falling(E_neg_phase & dotck_en),
        .reset(~_RESET_SYSTEM), // Systemwide reset
        .addr(A[4:1]), // RS0-RS3 address lines come from A1 to A4
        .wen(CS_KBD_VIA & ~READ), // We write when the chip is selected and READ is low
        .ren(CS_KBD_VIA & READ), // We read when the chip is selected and READ is high
        .data_in(IO_D), // Data input comes from the global I/O board data bus
        .data_out(D_out_KBD_VIA),
        .port_a_o(L_COP_out_int), // Port A is the comms bus to the COP
        .port_a_i(L_COP_in),
        .port_a_t(KBD_via_DDRA), // We only want to drive the COP outputs when we're writing to it
        .port_b_o(port_b_out_KBD_VIA),
        .port_b_i(port_b_in_KBD_VIA),
        .port_b_t(KBD_via_DDRB), // We need the DDRB register so we can know when PB0 is an output to drive the keyboard reset line
        .ca1_i(DATA_QUEUED_COP_sync), // CA1 comes from the SO (data queued) output of the COP, but synced to the DOTCK domain
        .ca2_o(READ_ACK_COP_ungated), // CA2 goes to the SI (read acknowledge) input of the COP
        .ca2_t(ca2_oe), // We need to be able to tri-state CA2 so we don't drive the COP's SI line when we're not supposed to
        .ca2_i(1'b0), // Make sure the unused CA2 input is tied to a known state
        .cb1_i(1'b1), // CB1 is pulled up to 5V
        .cb2_o(TONE), // CB2 generates the TONE audio frequency output
        .cb2_i(1'b0), // Make sure the unused CB2 input is tied to a known state
        .irq(KBIR) // The IRQ from this VIA is _KBIR that goes to the CPU board
    );

    // ======================= RTC clock-seed sequencer ========================
    // Once per FPGA config, before the auto power-on press, drive the real COP421
    // with the COPS clock-set sequence  0x2C, {0x10|nibble}x16, 0x25  so it keeps
    // host time. Muxes into the VIA->COP drive path (L_COP_out_int / DDRA) and is
    // fully transparent + released once done (seq_active=0), so the normal
    // keyboard path is untouched. No _RESET dependency (init-value one-shot) so a
    // mid-run reset can never re-seed and collide with live OS COPS traffic. The
    // per-byte 0x80 idle gap (DDRA low) lets the COP see each command as a fresh
    // edge even when consecutive nibbles are identical.
    // Per-byte handshake mirrors the boot ROM COPSCMD routine ($FE0956): stage the
    // byte on the (idle) bus, wait for CRDY (_READY_COP, low=ready) to go
    // low->high->low so we land in a FRESH ready window, drive DDRA=0xFF, wait for
    // CRDY high (the COP has latched), hold briefly, release. Pacing to CRDY (not a
    // fixed delay) is what makes the COP reliably accept every byte -- especially
    // the closing 0x25, without which the COP is left stuck in clock-set mode.
    localparam logic [7:0] RTC_CMD_SET = 8'h2C; // enter set mode, power on, clk stopped
    localparam logic [7:0] RTC_CMD_GO  = 8'h25; // exit set mode, power on, timer off
    localparam logic [2:0] RS_WAIT=3'd0, RS_LOW1=3'd1, RS_HIGH1=3'd2, RS_LOW2=3'd3,
                           RS_DRV=3'd4, RS_HOLD=3'd5, RS_GAP=3'd6, RS_DONE=3'd7;
    localparam logic [15:0] RTC_HOLD_T = 16'd2048; // long trailing hold (direct-drive; the
                                                   // COP needs the byte held well past CRDY)
    localparam logic [15:0] RTC_GAP_T  = 16'd1024; // idle gap; must exceed the 768-c16m
                                                   // extended-DDRA hold so the bus fully
                                                   // returns to 0x80 between bytes
    localparam logic [15:0] RTC_TMO    = 16'd16384;// per-CRDY-wait timeout: advance anyway
                                                   // (fallback if CRDY isn't toggling) so the
                                                   // sequence ALWAYS finishes through 0x25

    logic        seq_active = 1'b0;
    logic        seq_ddra   = 1'b0;
    logic  [7:0] seq_byte   = 8'h80;
    logic  [4:0] seq_idx    = 5'd0;   // 0..17 (0x2C, 16 nibbles, 0x25)
    logic [15:0] seq_timer  = 16'd0;
    logic [15:0] seq_tmo    = 16'd0;
    logic  [2:0] seq_state  = RS_WAIT;
    logic        seq_started= 1'b0;
    logic        rdy_s0 = 1'b1, rdy_s = 1'b1;
    // The COP only runs its command loop once powered on (ON=1). Seed AFTER ON,
    // after a settle delay (let the boot ROM's initial COP keyboard handshake
    // finish) and only when the VIA isn't driving the COP (KBD_via_DDRA==0), so
    // the seed lands in a quiet window well before the OS reads the clock.
    logic [21:0] on_dly = 22'd0;
    logic [11:0] quiet_cnt = 12'd0;   // sustained VIA-idle (KBD_via_DDRA==0) counter

    // byte for sequence position i: 0=0x2C, 1..16=0x10|nibble(i-1), 17=0x25
    function automatic logic [7:0] rtc_seqbyte(input logic [4:0] i);
        logic [5:0] nsel;
        if (i == 5'd0)       rtc_seqbyte = RTC_CMD_SET;
        else if (i <= 5'd16) begin
            nsel = {1'b0, (i - 5'd1)} << 2;             // nibble idx (i-1) * 4
            rtc_seqbyte = {4'h1, rtc_nibbles[nsel +: 4]};
        end else             rtc_seqbyte = RTC_CMD_GO;
    endfunction

    wire tmo = (seq_tmo == 16'd0);

    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            // sync CRDY (_READY_COP) into this domain for the seed handshake
            rdy_s0 <= _READY_COP; rdy_s <= rdy_s0;
            if (seq_tmo != 0) seq_tmo <= seq_tmo - 1'b1;
            // settle timer since the COP powered on (saturating)
            if (!ON) on_dly <= 22'd0;
            else if (!on_dly[21]) on_dly <= on_dly + 1'b1;
            // sustained VIA-idle: only seed when the COP bus has been quiet a while,
            // so we don't start on top of a boot-ROM keyboard COP transaction.
            if (KBD_via_DDRA != 8'h00) quiet_cnt <= 12'd0;
            else if (!quiet_cnt[11])  quiet_cnt <= quiet_cnt + 1'b1;

            case (seq_state)
                RS_WAIT: begin
                    seq_active <= 1'b0; seq_ddra <= 1'b0; seq_byte <= 8'h80;
                    if (rtc_valid && ON && on_dly[21] && quiet_cnt[11] && !seq_started) begin
                        seq_started <= 1'b1;
                        seq_idx     <= 5'd0;
                        seq_byte    <= rtc_seqbyte(5'd0);
                        seq_active  <= 1'b1;
                        seq_ddra    <= 1'b0;           // stage byte, bus still idle
                        seq_tmo     <= RTC_TMO;
                        seq_state   <= RS_LOW1;
                    end
                end
                RS_LOW1:  begin seq_active<=1'b1; seq_ddra<=1'b0;   // wait CRDY low (ready)
                    if (!rdy_s || tmo) begin seq_tmo<=RTC_TMO; seq_state<=RS_HIGH1; end end
                RS_HIGH1: begin seq_active<=1'b1; seq_ddra<=1'b0;   // wait CRDY high (skip)
                    if ( rdy_s || tmo) begin seq_tmo<=RTC_TMO; seq_state<=RS_LOW2; end end
                RS_LOW2:  begin seq_active<=1'b1; seq_ddra<=1'b0;   // wait fresh CRDY low
                    if (!rdy_s || tmo) begin seq_tmo<=RTC_TMO; seq_state<=RS_DRV; end end
                RS_DRV:   begin seq_active<=1'b1; seq_ddra<=1'b1;   // DRIVE, wait CRDY high = latched
                    if ( rdy_s || tmo) begin seq_timer<=RTC_HOLD_T; seq_state<=RS_HOLD; end end
                RS_HOLD:  begin seq_active<=1'b1; seq_ddra<=1'b1;   // brief trailing hold
                    if (seq_timer!=0) seq_timer<=seq_timer-1'b1;
                    else begin seq_ddra<=1'b0; seq_timer<=RTC_GAP_T; seq_state<=RS_GAP; end end
                RS_GAP:   begin seq_active<=1'b1; seq_ddra<=1'b0;   // idle 0x80, then next byte
                    if (seq_timer!=0) seq_timer<=seq_timer-1'b1;
                    else if (seq_idx == 5'd17) seq_state <= RS_DONE;
                    else begin
                        seq_idx  <= seq_idx + 1'b1;
                        seq_byte <= rtc_seqbyte(seq_idx + 1'b1);
                        seq_tmo  <= RTC_TMO;
                        seq_state<= RS_LOW1;
                    end end
                default:  begin seq_active<=1'b0; seq_ddra<=1'b0; end // RS_DONE
            endcase
        end
    end

    assign rtc_seed_done = (seq_state == RS_DONE);
    // (the seed drives L_COP_out directly below -- the extended-DDRA path is gated
    //  by _RESET, which is asserted during the seed's reset-hold window)

    // DEBUG (bring-up ISSP "LCOP", remove for release): COP<->VIA1 handshake
    // monitor. The boot ROM is stuck in ReadCOPS polling for the COP's startup
    // byte; this shows whether the COP raises SO (data queued), what byte it
    // puts on the L bus, whether the 68k's read-acks reach it, and whether the
    // COP is busy talking to the keyboard line instead.
    logic [7:0] dbg_so_cnt /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_ack_cnt /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_kbdout_cnt /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_kbdin_cnt /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_l_in_last /*verilator public_flat_rd*/ = 0;
    logic [7:0] dbg_l_out_last /*verilator public_flat_rd*/ = 0;
    logic       dbg_so_d = 0, dbg_ack_d = 0, dbg_kbdo_d = 1, dbg_kbdi_d = 1;
    // DEBUG: capture the FIRST 4 keycodes the COP sends the CPU at boot (frozen
    // after 4) so we can see the exact reset/keypress sequence that sets BTMENU.
    logic [7:0] kc0 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc1 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc2 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc3 /*verilator public_flat_rd*/ = 0;
    // Extend to 8 codes so the FULL COPS reset sequence is visible (kc0..kc3
    // showed 85,87,80,BF which per RSTSCAN shouldn't raise BTMENU -> the trigger
    // is in the codes AFTER kc3; capture them to find it).
    logic [7:0] kc4 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc5 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc6 /*verilator public_flat_rd*/ = 0;
    logic [7:0] kc7 /*verilator public_flat_rd*/ = 0;
    logic [3:0] kc_idx = 0;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            dbg_so_d   <= DATA_QUEUED_COP;
            dbg_ack_d  <= READ_ACK_COP;
            dbg_kbdo_d <= KBD_out;
            dbg_kbdi_d <= KBD_in;
            if (DATA_QUEUED_COP && !dbg_so_d) begin
                dbg_so_cnt <= dbg_so_cnt + 1'd1;
                dbg_l_in_last <= L_COP_in;
                case (kc_idx)
                    4'd0: kc0 <= L_COP_in;
                    4'd1: kc1 <= L_COP_in;
                    4'd2: kc2 <= L_COP_in;
                    4'd3: kc3 <= L_COP_in;
                    4'd4: kc4 <= L_COP_in;
                    4'd5: kc5 <= L_COP_in;
                    4'd6: kc6 <= L_COP_in;
                    4'd7: kc7 <= L_COP_in;
                    default: ;
                endcase
                if (kc_idx < 4'd8) kc_idx <= kc_idx + 1'd1;
            end
            if (READ_ACK_COP != dbg_ack_d) dbg_ack_cnt <= dbg_ack_cnt + 1'd1;
            if (KBD_out != dbg_kbdo_d) dbg_kbdout_cnt <= dbg_kbdout_cnt + 1'd1;
            if (KBD_in  != dbg_kbdi_d) dbg_kbdin_cnt  <= dbg_kbdin_cnt + 1'd1;
            dbg_l_out_last <= L_COP_out;
        end
    end
    `ifndef SIMULATION
    altsource_probe #(
        .sld_auto_instance_index ("YES"), .sld_instance_index (0),
        .instance_id ("LCOP"), .probe_width (64), .source_width (1),
        .source_initial_value ("0"), .enable_metastability ("NO")
    ) u_cop_probe ( .source(), .probe({
        // First 8 COPS boot codes the COP delivered to the CPU, in order.
        kc0, kc1, kc2, kc3, kc4, kc5, kc6, kc7
    }), .source_clk(clk_sys), .source_ena(1'b1) );
    `endif

    // When CA2 is an output, drive the COP's SI line with it, else leave it high
    assign READ_ACK_COP = (ca2_oe) ? READ_ACK_COP_ungated : 1'b1;

    // Only drive the L bus to the COP when the VIA is set to output on Port A
    // Otherwise set it to all zeros, except the high bit which is pulled up to 5V on the schematic
    // I've noticed that the COP is really picky about how long the output is enabled for, so we have to condition the DDRA enable a bit
    // At a 20MHz DOTCK, everything's fine, but if we overclock to 60MHz, the COP won't respond to commands on L_COP_out anymore
    // This is because of the faster CPU speed; even though the CPU keeps DDRA set to output for the entire extent of the ready pulse,
    // The COP actually expects it to be driven for a bit after the pulse ends too, and with a faster CPU clock, that extra time gets cut off
    // This isn't a problem in the boot ROM because of how its code is written; only in LOS
    // But anyway, the fix is to make an extended version of DDRA that stays high for a little while after the regular DDRA goes low
    // This requires clocking our extension logic off a non-DOTCK clock so it's independent of the CPU speed, so we'll use C16M for that
    // But this also means that we need to sync DDRA from the VIA into the C16M domain before we begin
    (* ASYNC_REG = "TRUE" *) logic KBD_via_DDRA_int, KBD_via_DDRA_sync;
    always_ff @(posedge clk_sys) begin
        if (c16m_en) begin
            KBD_via_DDRA_int <= KBD_via_DDRA;
            KBD_via_DDRA_sync <= KBD_via_DDRA_int;
        end
    end
    logic KBD_via_DDRA_extended;
    logic [10:0] DDRA_extension_counter;
    always_ff @(posedge clk_sys) begin
      if (c16m_en) begin
        if (!_RESET) begin
            // On reset, clear the counter and the extended DDRA signal
            DDRA_extension_counter <= 11'b0;
            KBD_via_DDRA_extended <= 1'b0;
        end else begin
            if (KBD_via_DDRA_sync) begin
                // Whenever DDRA goes high, immediately set the extended DDRA signal high and reset the counter
                KBD_via_DDRA_extended <= 1'b1;
                DDRA_extension_counter <= 11'b0;
                // Otherwise, DDRA is low
            end else begin
                if (DDRA_extension_counter < 11'd768) begin
                    // If DDRA is low but the counter hasn't reached its max value yet, increment it
                    DDRA_extension_counter <= DDRA_extension_counter + 1'b1;
                    KBD_via_DDRA_extended <= 1'b1; // And keep the extended signal high
                end else begin
                    // Once the counter reaches its max value, set the extended signal low
                    KBD_via_DDRA_extended <= 1'b0;
                end
            end
        end
      end
    end

    // Next, synchronize this signal into the COPCK_2x domain
    (* ASYNC_REG = "TRUE" *) logic KBD_via_DDRA_extended_int, KBD_via_DDRA_extended_sync;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            KBD_via_DDRA_extended_int <= KBD_via_DDRA_extended;
            KBD_via_DDRA_extended_sync <= KBD_via_DDRA_extended_int;
        end
    end

    // And now gate L_COP_out with this synced extended DDRA signal
    // Make sure we latch the value of L_cop_out_int when DDRA goes low though, so that it stays the same through the end of the extended pulse
    logic KBD_VIA_DDRA_extended_sync_prev;
    always_ff @(posedge clk_sys) begin
      if (copck2x_en) begin
        // RTC seed drives the COP L bus DIRECTLY (bypasses the extended-DDRA path,
        // which is held cleared while !_RESET -- and _RESET is asserted during the
        // seed's reset-hold window). seq holds each byte long past CRDY (RTC_HOLD_T)
        // so the COP latches it. Transparent + released once seeding is done.
        if (seq_active) begin
            L_COP_out <= seq_ddra ? seq_byte : 8'b10000000;
        // So latch L_COP_out_int on the rising edge of the DDRA extended signal
        end else if (KBD_via_DDRA_extended_sync && !KBD_VIA_DDRA_extended_sync_prev) begin
            L_COP_out <= L_COP_out_int;
        end else if (!KBD_via_DDRA_extended_sync) begin
            // And then when the extended signal goes low, hold L_COP_out at its default of 0x80
            L_COP_out <= 8'b10000000;
        end
        KBD_VIA_DDRA_extended_sync_prev <= KBD_via_DDRA_extended_sync;
      end
    end

    // Only put the VIA's output data on the global I/O board data bus when it's being selected and read from
    assign IO_D = (CS_KBD_VIA & READ) ? D_out_KBD_VIA : 8'bz;

    // And oh yeah, we also need to expose that I/O data bus to the BD bus when necessary
    // That happens whenever A12 and _INTIO are both asserted, the direction (BD to IO_D or IO_D to BD) is determined by READ
    // And do BD_out for the FDC as well
    // Once again, BD is muxed in the top-level module, so we need an OE too
    assign IO_D = (A[12] & ~_INTIO & ~READ) ? BD_in[7:0] : 8'bz;

    always_comb begin
        if (~FDC_RAM_addr_select && READ) begin
            // Feed BD_out from the FDC RAM when it's selected by the CPU board and we're reading
            BD_out = {8'b0, FD_in};
        end else if (A[12] & ~_INTIO & READ) begin
            // Otherwise, if the rest of the I/O board is selected and we're reading, feed BD_out from the I/O board data bus
            BD_out = {8'b0, IO_D};
        end else begin
            // Else, just set BD to 0
            BD_out = 16'b0;
        end
    end

    // Now we break out the Port B bits
    assign _KBD_reset_VIA = port_b_out_KBD_VIA[0]; // PB0 is _KBD_reset_VIA
    assign VC = port_b_out_KBD_VIA[3:1]; // PB1 to PB3 are the three bits of VC (volume control)
    assign port_b_in_KBD_VIA[4] = FDIR_sync; // PB4 is FDIR synced to the DOTCK domain from the FDC
    assign port_b_in_KBD_VIA[5] = _PRES; // PB5 is _PRES from the ProFile
    assign port_b_in_KBD_VIA[6] = _READY_COP_sync; // PB6 is _READY from the COP, but synced to the DOTCK domain
    // PB7 is one of the things that can drive _CRES, but the ProFile can also drive _CRES, so we have separate CRES_out and CRES_in lines
    always_comb begin
        if (KBD_via_DDRB[7]) begin
            // Assert _CRES_out when PB7 is an output and it's low, or when the system is in reset
            _CRES_out = port_b_out_KBD_VIA[7] & _RESET_SYSTEM;
            // Otherwise, if PB7 is an input, then just have _CRES_out follow the state of RESET
        end else begin
            _CRES_out = _RESET_SYSTEM;
        end
    end
    // Put the other unused bits of Port B into known states
    assign port_b_in_KBD_VIA[0] = 1'b0;
    assign port_b_in_KBD_VIA[1] = 1'b0;
    assign port_b_in_KBD_VIA[2] = 1'b0;
    assign port_b_in_KBD_VIA[3] = 1'b0;
    assign port_b_in_KBD_VIA[7] = 1'b0;

    // And finally, we need to generate _PRES from _CRES
    // This is super easy though; they're literally exactly the same thing, _PRES is just buffered through an extra LS09 AND gate
    // But we don't care about that here, so just tie them together
    assign _PRES = _CRES_out & _CRES_in;

    // Last but not least, Page 5, from which we literally only need to implement one thing: the contrast latch
    // The original I/O board also had a DAC to convert the contrast to an analog voltage, but we have to do that externally (or over HDMI)
    // Before we implement the contrast latch itself, we need to synchronize the WCNT signal from the VIA and the contrast bits into the DOTCK domain
    (* ASYNC_REG = "TRUE" *) logic WCNT_int, WCNT_sync;
    (* ASYNC_REG = "TRUE" *) logic [5:0] CONT_int, CONT_sync;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            WCNT_int <= WCNT;
            WCNT_sync <= WCNT_int;
            CONT_int <= SD_out[7:2];
            CONT_sync <= CONT_int;
        end
    end
    // Now do the actual contrast latch
    logic WCNT_sync_prev;
    always_ff @(posedge clk_sys, negedge _RESET_SYSTEM) begin
        if (!_RESET_SYSTEM) begin
            CONT <= 6'b0; // On reset, set contrast to 0
        end else if (dotck_en) begin
            if (WCNT_sync && !WCNT_sync_prev) begin
                CONT <= CONT_sync; // Otherwise, latch bits [7:2] of the SD bus from the PP VIA into CONT on the rising edge of WCNT
            end
            WCNT_sync_prev <= WCNT_sync; // And keep track of the previous state of WCNT so we can detect rising edges
        end
    end

endmodule
