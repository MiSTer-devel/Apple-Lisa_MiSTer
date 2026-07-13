`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/29/2025 11:38:35 PM
// Design Name: The Apple Lisa - All Inside an FPGA!!!
// Module Name: top
// Project Name: LisaFPGA
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 1.2 - Fixed SRAM issues for boards with marginal SRAM ICs and started clocking the VIAs off DOTCK instead of E for better timing stability.
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module top(
        input logic sysclk,

        output logic _VSYNC,
        output logic _HSYNC,
        output logic VID,
        output logic [5:0] CONT,
        input logic INVID,
        input logic SCANLINES,
        input logic FRAMERATE_SEL,

        output logic TONE,
        output logic [2:0] VC,

        output logic HDMI_CLK_N,
        output logic HDMI_CLK_P,
        output logic [2:0] HDMI_D_N,
        output logic [2:0] HDMI_D_P,

        output logic _CE_SRAM,
        output logic _OE_SRAM,
        output logic _WE_SRAM,
        output logic _UDS_SRAM,
        output logic _LDS_SRAM,
        output logic [20:1] A_SRAM,
        inout logic [15:0] D_SRAM,
        // RAM-size-inhibited RAS/CAS for the deterministic SDRAM controller.
        output logic _RAS_SRAM,
        output logic _CAS_SRAM,

        input logic [1:0] RAM_SEL,

        inout logic [5:0] ESFLOPPY_COMM_BUS,
        input logic RDA_ESFLOPPY,
        output logic WRD_ESFLOPPY,
        input logic SNS_ESFLOPPY,
        output logic _WRQ_ESFLOPPY,
        output logic HDS_ESFLOPPY,
        output logic [3:0] PH_ESFLOPPY,
        output logic MT1_ESFLOPPY,
        output logic MT0_ESFLOPPY,
        output logic _DR1_ESFLOPPY,
        output logic _DR0_ESFLOPPY,
        output logic PWM_ESFLOPPY,

        input logic LEFT_ESFLOPPY,
        input logic OK_ESFLOPPY,
        input logic RIGHT_ESFLOPPY,

        input logic RDA_EXTFLOPPY,
        output logic WRD_EXTFLOPPY,
        input logic SNS_EXTFLOPPY,
        output logic _WRQ_EXTFLOPPY,
        output logic HDS_EXTFLOPPY,
        output logic [3:0] PH_EXTFLOPPY,
        output logic MT1_EXTFLOPPY,
        output logic MT0_EXTFLOPPY,
        output logic _DR1_EXTFLOPPY,
        output logic _DR0_EXTFLOPPY,
        output logic PWM_EXTFLOPPY,

        input logic FLOPPY_SRC,

        inout logic [2:0] ESPROFILE_COMM_BUS,
        output logic _CMD_ESPROFILE,
        input logic _BSY_ESPROFILE,
        output logic R_W_ESPROFILE,
        output logic _STRB_ESPROFILE,
        output logic _PRES_ESPROFILE, // was inout (open-collector); top is the only driver on MiSTer
        input logic _PARITY_ESPROFILE,
        input logic OCD_ESPROFILE,
        // Was `inout [7:0] PD_ESPROFILE`; split to kill the internal tri-state
        // (see note at the old pd_esprofile_gen block).
        input  logic [7:0] PD_ESPROFILE_in,
        output logic [7:0] PD_ESPROFILE_out,

        output logic _CMD_EXTPROFILE,
        input logic _BSY_EXTPROFILE,
        output logic R_W_EXTPROFILE,
        output logic _STRB_EXTPROFILE,
        inout logic _PRES_EXTPROFILE,
        input logic _PARITY_EXTPROFILE,
        input logic OCD_EXTPROFILE,
        inout logic [7:0] PD_EXTPROFILE,

        input logic HDD_SRC,

        inout logic KBD_DN,
        inout logic KBD_DP,

        // Was `inout logic KBD` (open-collector keyboard line). Quartus resolves
        // internal undriven tri-nets to 0 here (no pull-up), which held the COP's
        // keyboard line low forever. Split into explicit in/out; the wired-AND
        // happens in Lisa.sv.
        input logic KBD_line_in,
        output logic KBD_line_out,

        input logic KBD_SEL,

        inout logic MOUSE_DN,
        inout logic MOUSE_DP,

        input logic [6:0] M_LISA,

        input logic MOUSE_SEL,

        (* PULLTYPE = "PULLDOWN" *) input logic [5:0] GPIO,

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

        output logic INTERNAL_SCC_EN,

        input logic _PWRSW,
        output logic ON,
        input logic _RSTSW,
        output logic _RESET,
        input logic _NMISW,

        input logic [1:0] SPEED_SEL,
        input logic CPU_ROM_SEL,
        input logic IO_ROM_SEL,

        // RTC clock seeding (from Lisa.sv rtc_lisa -> IO_board COP sequencer)
        input  logic [63:0] rtc_nibbles,
        input  logic        rtc_valid,
        input  logic        rtc_load_req,
        output logic        rtc_seed_done,

        output logic usbclk_en, // ~12MHz usbclk clock-enable (usb runs on clk_sys now)
        input logic clk_sys,  // 81.50016 MHz master clock; all Lisa clocks are divided from this
        input logic pll_locked, // DEBUG (bring-up ISSP): main_pll locked status
        output logic pixel_ce, // DOTCK-rate pixel clock-enable for the MiSTer video scaler (CE_PIXEL)
        output logic dbg_va,   // VA_overflow (high during vertical blanking)
        output logic dbg_clr   // _clr_vid_clk (marks horizontal active start)
    );

    // This is the board ID for the LisaFPGA identity register; software can read it to see if it's on a real Lisa or an FPGA
    // The identity register is just a byte-extended version of the system status register
    localparam logic [2:0] LisaFPGA_ID = 3'b110;
    // This flag says whether this is a LisaFPGA Desktop board (as opposed to a Motherboard Replacement)
    // It's also exposed as a field in the identity register
    localparam logic LisaFPGA_Desktop = 1'b1;

    // The internal Verilog SCC is now working, so enable the transceivers that hook it to the serial bus instead of using the external SCC
    assign INTERNAL_SCC_EN = 1'b0;

    // Pass the LEFT, OK, and RIGHT signals from the ESFloppy control buttons straight back out to the ESP32 again
    // Just pick three of the ESFLOPPY_COMM_BUS lines for this
    assign ESFLOPPY_COMM_BUS[0] = LEFT_ESFLOPPY;
    assign ESFLOPPY_COMM_BUS[1] = OK_ESFLOPPY;
    assign ESFLOPPY_COMM_BUS[2] = RIGHT_ESFLOPPY;
    // Set the rest of the comm bus to a defined state
    assign ESFLOPPY_COMM_BUS[5:3] = 3'b000;

    logic _SL0;
    logic _SH0;
    logic _SL1;
    logic _SH1;
    logic _SL2;
    logic _SH2;
    tri1 _INT0;
    tri1 _IAK0;
    tri1 _INT1;
    tri1 _IAK1; 
    tri1 _INT2; 
    tri1 _IAK2; 
    tri1 _RSIR; 
    tri1 _KBIR; 
    logic _IOIR; // Original is open-collector, we're making it a regular logic signal instead, so unidirectional now (out of I/O, into CPU)
    logic E;
    logic CPUCK;
    tri1 _LDMA; 
    tri1 _BGACK; 
    tri1 _BR; 
    logic _BG;
    logic [15:0] BD;
    logic [15:0] BD_CPU;
    logic BD_OE_CPU;
    logic [15:0] BD_IO;
    logic BD_OE_IO;
    logic [12:1] A;
    logic _VMA;
    logic _VPA; // Original is open-collector, we're making it a regular logic signal instead that gets muxed here in the top module
    logic _VPA_CPU; // It gets muxed from these
    logic VPA_OE_CPU;
    logic _VPA_IO;
    logic VPA_OE_IO;
    logic _DTACK; // Original is open-collector, we're making it a regular logic signal instead that gets muxed here in the top module
    logic _DTACK_CPU; // It gets muxed from these
    logic DTACK_OE_CPU;
    logic _DTACK_IO;
    logic DTACK_OE_IO;
    tri1 _AS;
    tri1 READ;
    tri1 _LDS;
    tri1 _UDS;
    logic _CSYNC;
    logic _INTIO;
    logic VA10B;
    logic VA9B;
    logic _R1;
    logic _R2;
    tri [15:0] MD;
    logic [15:0] MD_IN;
    logic [15:0] MD_OUT;
    logic [8:1] RA;
    logic A16;
    logic A17;
    logic A18;
    logic A19;
    logic MREAD;
    logic _CAS;
    logic _RAS;
    logic A20;
    logic _HDER; // Original is open-collector, we're making it a regular logic signal instead that gets muxed here in the top module
    logic _HDER_CPU; // It gets muxed from these
    logic HDER_OE_CPU;
    logic _HDER_MEM;
    logic HDER_OE_MEM;
    logic _SFER; // Original is open-collector, we're making it a regular logic signal instead that gets muxed here in the top module
    logic _SFER_CPU; // It gets muxed from these
    logic SFER_OE_CPU;
    logic _SFER_MEM;
    logic SFER_OE_MEM;
    logic VID_int;
    logic _NMI;
    logic VAL_LED;
    logic E_pos_phase;
    logic E_neg_phase;

    logic T1, T2, T3;

    assign _BGACK = 1'b1;
    assign _LDMA = 1'b1;
    assign _BR = 1'b1;
    assign _INT0 = 1'b1;
    assign _INT1 = 1'b1;
    assign _INT2 = 1'b1;

    logic sysclk_ibuf;

    assign sysclk_ibuf = sysclk;

    // Level signals that used to be their own clocks are now clk_sys-domain
    // registers/strobes generated in the clock section below:
    //   COPCK          - the 1.95MHz COP clock LEVEL (still a level; the COP model
    //                    takes clk_sys + copck2x_en and derives its own enable)
    //   SCCCK_ungated  - the 3.6864MHz SCC clock LEVEL (used to form sccck_en)
    // All the old derived clock nets (DOTCK/C16M/C5M/SCCCK/*_2x/*_ungated clocks)
    // are gone; consumers use clk_sys + the matching enable strobe instead.
    logic COPCK;
    logic SCCCK_ungated;

    // We use an MMCM for this, but there's a catch
    // It can't generate either COPCK or SCCCK directly because the frequencies are too low
    // So instead, we generate 2x the frequency of each and divide it by 2 with flip-flops
    // We'll use this MMCM to generate everything but the DOTCK
    // ---------------------------------------------------------------------
    // Single-clock enable generator. The whole core runs on clk_sys; each old
    // derived clock is now a one-clk_sys-cycle enable strobe pulsing when that
    // clock used to have a rising edge. The DOTCK speed-select mux is folded
    // into the generator (speed_sel picks the dotck_en divide ratio).
    // ---------------------------------------------------------------------
    wire dotck_en_raw, c16m_en_raw, c5m_en_raw, copck2x_en, sccck2x_en;
    // usbclk_en is a module output port (declared in the port list)

    // DEBUG (bring-up ISSP): live override of speed-select and ON-gate over JTAG.
    wire [1:0] dbg_speed_override;
    wire       dbg_speed_override_en;
    wire       dbg_force_on;
    wire [1:0] speed_sel_eff = dbg_speed_override_en ? dbg_speed_override : SPEED_SEL;

    clock_divider primary_clock_divider (
        .clk_sys(clk_sys),
        .speed_sel(speed_sel_eff),
        .dotck_en(dotck_en_raw),
        .c16m_en(c16m_en_raw),
        .c5m_en(c5m_en_raw),
        .copck2x_en(copck2x_en),
        .sccck2x_en(sccck2x_en),
        .usbclk_en(usbclk_en)
    );

    // COPCK level (COPCK_2x divided by 2), advanced only on COPCK_2x ticks
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            `ifdef SIMULATION
                if (!_RSTSW) COPCK <= 1'b0;
                else         COPCK <= ~COPCK;
            `else
                COPCK <= ~COPCK;
            `endif
        end
    end

    // SCCCK level (SCCCK_2x divided by 2) with its reset synchronized in.
    (* ASYNC_REG = "TRUE" *) logic _RESET_SCCCK_int, _RESET_SCCCK_sync;
    always_ff @(posedge clk_sys) begin
        if (sccck2x_en) begin
            _RESET_SCCCK_int  <= _RESET;
            _RESET_SCCCK_sync <= _RESET_SCCCK_int;
        end
    end
    always_ff @(posedge clk_sys, negedge _RESET_SCCCK_sync) begin
        if (!_RESET_SCCCK_sync) SCCCK_ungated <= 1'b0;
        else if (sccck2x_en)    SCCCK_ungated <= ~SCCCK_ungated;
    end
    // SCCCK rising-edge enable (3.6864MHz strobe) for the SCC serial domain.
    wire sccck_en_raw = sccck2x_en & ~SCCCK_ungated;

    // ON-gate the core enables: the Lisa freezes when powered off, exactly like
    // the old design gated the derived clocks. One ON synchronizer suffices now
    // that everything is in the clk_sys domain. copck2x_en / usbclk_en stay
    // ungated (the COP and USB logic run whenever the FPGA is powered).
    wire ON_val;
    assign ON_val = ON;

    (* ASYNC_REG = "TRUE" *) logic ON_int, ON_sync;
    always_ff @(posedge clk_sys) begin
        ON_int  <= ON_val;
        ON_sync <= ON_int;
    end

    // DEBUG (bring-up): dbg_force_on can bypass the ON gate over JTAG.
    wire on_eff = ON_sync | dbg_force_on;
    wire dotck_en = dotck_en_raw & on_eff;
    wire c16m_en  = c16m_en_raw  & on_eff;
    wire c5m_en   = c5m_en_raw   & on_eff;
    wire sccck_en = sccck_en_raw & on_eff;

    `ifndef SIMULATION
    debug_issp u_debug_issp (
        .clk_sys(clk_sys),
        .pll_locked(pll_locked),
        .vsync_n(_VSYNC),
        .hsync_n(_HSYNC),
        .dotck_en(dotck_en),
        .core_on(ON),
        .core_on_sync(ON_sync),
        .reset_n(_RESET),
        .speed_override(dbg_speed_override),
        .speed_override_en(dbg_speed_override_en),
        .force_on(dbg_force_on)
    );
    `else
    assign dbg_speed_override = 2'b00;
    assign dbg_speed_override_en = 1'b0;
    assign dbg_force_on = 1'b0;
    `endif

    // Pixel clock-enable for the MiSTer scaler: one strobe per DOTCK (Lisa pixel).
    assign pixel_ce = dotck_en;

    // Expose the core's raw blanking signals; Lisa.sv reconstructs a clean
    // 720-wide horizontal DE window from them (VA_overflow = vertical blank,
    // _clr_vid_clk's first fall each line = horizontal active start).
    assign dbg_va  = VA_overflow;
    assign dbg_clr = _clr_vid_clk;

    logic _RSTSW_int;

    // We need to be able to reset when the COP turns the Lisa on too, not just when the reset button is pressed
    // Otherwise, many things will work, but some will be in bad states at power-on
    // Like the 6504 for instance, which will pick up executing code wherever it left off when the Lisa was last powered down
    logic ON_prev;
    logic ON_rising;

    // Hold the whole machine in reset until the RTC clock-seed finishes, so the
    // COP is seeded with the CPU/VIA idle (no boot-traffic contention on the COP
    // bus) -- then release and let it boot with the clock already set. The COP
    // powers on and runs independently of this reset, so there is no deadlock; a
    // ~2s timeout guarantees boot even if no host RTC ever arrives.
    logic        seed_reset_hold = 1'b1;
    logic [24:0] seed_rst_tmo    = 25'd0;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            ON_prev <= ON_val;
            if (ON_val & ~ON_prev) begin
                seed_reset_hold <= 1'b1;         // (re)assert hold at each power-on
                seed_rst_tmo    <= 25'd0;
            end else begin
                if (!seed_rst_tmo[24]) seed_rst_tmo <= seed_rst_tmo + 1'b1;
                if (rtc_seed_done | seed_rst_tmo[24]) seed_reset_hold <= 1'b0;
            end
            _RSTSW_int <= _RSTSW & ~(ON_val & ~ON_prev) & ~seed_reset_hold;
        end
    end

    // We also need to do some stuff with the _PWRSW signal to address a bug in the original Lisa system
    // On the original Lisa, if you held the power button down for too long when trying to turn on, you'd get an Error 52
    // So the simple fix here is to detect the falling edge of _PWRSW and just assert the power signal for a brief period after that occurs
    // As opposed to the entire time that _PWRSW is low

    // First, synchronize the _PWRSW signal to the COPCK domain
    (* ASYNC_REG = "TRUE" *) logic _PWRSW_int, _PWRSW_sync;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
            _PWRSW_int <= _PWRSW;
            _PWRSW_sync <= _PWRSW_int;
        end
    end
    // Now detect the falling edge of the synchronized version of _PWRSW
    logic _PWRSW_sync_prev;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) _PWRSW_sync_prev <= _PWRSW_sync;
    end
    // And now generate a pulse whenever we see a falling edge on _PWRSW_sync
    logic _PWRSW_falling;
    logic [15:0] _PWRSW_pulse_counter; // We want the pulse to last a little more than just 1 clock, so make a counter to allow this
    localparam [15:0] PWRSW_PULSE_MAX = 16'hFFFF;
    always_ff @(posedge clk_sys) begin
        if (copck2x_en) begin
        if (_PWRSW_sync_prev && !_PWRSW_sync) begin
            _PWRSW_falling <= 1'b0; // If we see a falling edge, start the pulse
            _PWRSW_pulse_counter <= 16'h0; // Reset the counter at the start of the pulse just in case it's not already reset
        end else if (!_PWRSW_falling) begin
            // We end up here if we're in the middle of a pulse
            if (_PWRSW_pulse_counter == PWRSW_PULSE_MAX) begin
                _PWRSW_falling <= 1'b1; // If a (rather arbitrary) FFFF clock cycles have passed, end the pulse
            end else begin
                _PWRSW_pulse_counter <= _PWRSW_pulse_counter + 1; // Otherwise, increment the counter and keep going
            end
        end else begin
            _PWRSW_pulse_counter <= 16'h0; //If we're not in a pulse, make sure the counter is reset
            _PWRSW_falling <= 1'b1; // And make sure the falling signal is deasserted
        end
        end
    end

    // We need a version of _RSTSW_int synchronized into the "DOTCK" (dotck_en) pace for the CPU board
    (* ASYNC_REG = "TRUE" *) logic _RSTSW_dotck_int, _RSTSW_dotck;
    always_ff @(posedge clk_sys) begin
        if (dotck_en) begin
            _RSTSW_dotck_int <= _RSTSW_int;
            _RSTSW_dotck <= _RSTSW_dotck_int;
        end
    end

    // Note the inversion of _VSYNC and VID here; the LS132 on the motherboard does this
    logic _VSYNC_int;
    assign _VSYNC = ~_VSYNC_int;
    assign VID = ~VID_int;

    logic tmds_clock;
    logic [2:0] tmds;

    logic VA_overflow;
    logic _clr_vid_clk;

    HDMI_Interface lisa_hdmi_output(
        .sysclk(sysclk_ibuf),
        ._reset(_RESET),
        .DOTCK(clk_sys), // HDMI_Interface is stubbed on MiSTer; DOTCK input is ignored

        .framerate_sel(FRAMERATE_SEL), // 0 for 1080p30, 1 for 1080p60
        .VA_overflow(VA_overflow), // Replaces VSYNC; better reflects the VSYNC time which is actually longer than _VSYNC
        ._clr_vid_clk(_clr_vid_clk), // Replaces _HSYNC; better reflects the HSYNC time which is actually shorter than _HSYNC
        .VID(VID_int),
        .CONT(CONT),
        .TONE(TONE),
        .VC(VC),
        .CPU_ROM_SEL(CPU_ROM_SEL),
        .blank_video(~ON_val), // When the Lisa is off, we want to blank the video output
        .scanlines(SCANLINES), // When high, put scanlines on the video output to make it look cool
        .tmds_clock(tmds_clock),
        .tmds(tmds)
    );

    assign HDMI_D_P = 3'b0;
    assign HDMI_D_N = 3'b0;
    assign HDMI_CLK_P = 1'b0;
    assign HDMI_CLK_N = 1'b0;

    CPU_board cpu_board(
        ._SL0(_SL0),
        ._SH0(_SH0),
        ._SL1(_SL1),
        ._SH1(_SH1),
        ._SL2(_SL2),
        ._SH2(_SH2),
        ._INT0(_INT0),
        ._IAK0(_IAK0),
        ._INT1(_INT1),
        ._IAK1(_IAK1),
        ._INT2(_INT2),
        ._IAK2(_IAK2),
        ._RSIR(_RSIR),
        ._KBIR(_KBIR),
        ._IOIR(_IOIR),
        .E(E),
        ._RESET(_RESET),
        .CPUCK(CPUCK),
        ._LDMA(_LDMA),
        ._BGACK(_BGACK),
        ._BR(_BR),
        ._BG(_BG),
        .BD_in(BD),
        .BD_out(BD_CPU),
        .BD_OE(BD_OE_CPU),
        .A_OUT(A),
        ._VMA(_VMA),
        ._VPA_in(_VPA),
        ._VPA_out(_VPA_CPU),
        .VPA_OE(VPA_OE_CPU),
        ._DTACK_in(_DTACK),
        ._DTACK_out(_DTACK_CPU),
        .DTACK_OE(DTACK_OE_CPU),
        ._AS(_AS),
        .READ(READ),
        ._LDS(_LDS),
        ._UDS(_UDS),
        ._CSYNC(_CSYNC),
        ._INTIO(_INTIO),
        .VA10B(VA10B),
        .VA9B(VA9B),
        ._R1(_R1),
        ._R2(_R2),
        .MD_IN(MD_IN),
        .MD_OUT(MD_OUT),
        .RA(RA),
        ._RSTSW(_RSTSW_dotck),
        .A16(A16),
        .A17(A17),
        .A18(A18),
        .A19(A19),
        .clk_sys(clk_sys),
        .dotck_en(dotck_en),
        .MREAD(MREAD),
        ._CAS(_CAS),
        ._RAS(_RAS),
        .A20(A20),
        ._HSYNC(_HSYNC),
        ._HDER_in(_HDER),
        ._HDER_out(_HDER_CPU),
        .HDER_OE(HDER_OE_CPU),
        ._VSYNC(_VSYNC_int),
        ._SFER_in(_SFER),
        ._SFER_out(_SFER_CPU),
        .SFER_OE(SFER_OE_CPU),
        .VID(VID_int),
        ._NMI(_NMI),

        .VAL_LED(VAL_LED),
        .INVID(~INVID),
        .E_pos_phase(E_pos_phase),
        .E_neg_phase(E_neg_phase),
        .CPU_ROM_SEL(CPU_ROM_SEL),
        .VA_overflow(VA_overflow),
        ._clr_vid_clk(_clr_vid_clk),
        .SPEED_SEL(SPEED_SEL),
        .LisaFPGA_ID(LisaFPGA_ID),
        .LisaFPGA_Desktop(LisaFPGA_Desktop)
    );

    logic [3:0] PH;
    logic WRD;
    logic _WRQ;
    logic RDA;
    logic _DR1;
    logic _DR0;
    logic HDS;
    logic SNS;
    logic MT1;
    logic MT0;
    logic _IRQ;
    logic _BG0;
    logic OCD;
    logic [7:0] PD_in;
    logic [7:0] PD_out;
    logic _ProFile_EN;
    logic PR_W_ungated;
    logic _PARITY;
    logic _PSTRB;
    logic DR_W;
    logic _BSY;
    logic _CMD;
    //logic SPKRIN;
    logic KBD_in;
    logic KBD_out;
    logic [6:0] M;
    logic _NMI_IO;
    logic NMI_OE_IO;
    logic _CRES_in;
    logic _CRES_out;

    // Here we mux VPA from the CPU board, I/O board, and expansion slots together
    always_comb begin
        // If the CPU board is trying to assert VPA, let it through
        if (VPA_OE_CPU) begin
            _VPA <= _VPA_CPU;
        // Otherwise, if the I/O board is trying to assert VPA, let it through
        end else if (VPA_OE_IO) begin
            _VPA <= _VPA_IO;
        // And otherwise, nothing is trying to drive it, so make sure it's deasserted
        end else begin
            _VPA <= 1'b1;
        end
        // Add more to this mux once we add the expansion slots!
    end

    // Same deal with the DTACK mux
    always_comb begin
        if (DTACK_OE_CPU) begin
            _DTACK <= _DTACK_CPU;
        end else if (DTACK_OE_IO) begin
            _DTACK <= _DTACK_IO;
        end else begin
            _DTACK <= 1'b1;
        end
        // Add more to this mux once we add the expansion slots!
    end

    // And we need one for the buffered data bus (BD) too
    always_comb begin
        if (BD_OE_CPU) begin
            BD <= BD_CPU;
        end else if (BD_OE_IO) begin
            BD <= BD_IO;
        end else begin
            BD <= 16'b0;
        end
        // Add more to this mux once we add the expansion slots!
    end

     // And another mux for NMI, which can be triggered by either the I/O board or the interrupt switch
    always_comb begin
        if (NMI_OE_IO) begin
            _NMI = _NMI_IO;
        end else if (!_NMISW) begin
            _NMI = 1'b0;
        end else begin
            _NMI = 1'b1;
        end
    end

    // And yet another for HDER, which can be triggered by either the CPU board or the memory board
    always_comb begin
        if (HDER_OE_CPU) begin
            _HDER = _HDER_CPU;
        end else if (HDER_OE_MEM) begin
            _HDER = _HDER_MEM;
        end else begin
            _HDER = 1'b1;
        end
    end

    // One more for SFER too, which is the same deal as HDER
    always_comb begin
        if (SFER_OE_CPU) begin
            _SFER = _SFER_CPU;
        end else if (SFER_OE_MEM) begin
            _SFER = _SFER_MEM;
        end else begin
            _SFER = 1'b1;
        end
    end

    assign _INT0 = 1'b1;
    assign _INT1 = 1'b1;
    assign _INT2 = 1'b1;

    assign _IRQ = 1'b1;

    // The floppy drive signals come from either the onboard ESFloppy or an external floppy drive
    // This depends on the FLOPPY_SRC signal, so we need to mux between them

    // First generate the Sony drive's PWM motor control signal
    // It's derived from MT0, but processed through the Lite Adapter
    // So let's make a Lite adapter to generate it
    logic PWM;

    Lite_Adapter lisa_lite (
        .clk(clk_sys),
        .c5m_en(c5m_en),
        .rst(~_RSTSW_int),
        .PH0(PH[0]),
        .MT(MT1),
        .PWM(PWM)
    );

    always_comb begin
        // If FLOPPY_SRC is high, use the external floppy drive signals
        if (FLOPPY_SRC) begin
            if (IO_ROM_SEL) begin
                // If we're in Twiggy mode, hook RDA and SNS up to their own individual pins
                RDA = RDA_EXTFLOPPY;
                SNS = SNS_EXTFLOPPY;
            end else begin
                // If we're in Sony mode, hook both RDA and SNS to RDA
                RDA = RDA_EXTFLOPPY;
                SNS = RDA_EXTFLOPPY;
            end
            WRD_EXTFLOPPY = WRD;
            _WRQ_EXTFLOPPY = _WRQ;
            HDS_EXTFLOPPY = HDS;
            PH_EXTFLOPPY = PH;
            MT1_EXTFLOPPY = MT1;
            MT0_EXTFLOPPY = MT0;
            _DR1_EXTFLOPPY = _DR1;
            _DR0_EXTFLOPPY = _DR0;
            PWM_EXTFLOPPY = PWM;
            // And make sure that the onboard ESFloppy signals are inactive
            WRD_ESFLOPPY = 1'b0;
            _WRQ_ESFLOPPY = 1'b1;
            HDS_ESFLOPPY = 1'b0;
            PH_ESFLOPPY = 4'b0000;
            MT1_ESFLOPPY = 1'b0;
            MT0_ESFLOPPY = 1'b0;
            _DR1_ESFLOPPY = 1'b1;
            _DR0_ESFLOPPY = 1'b1;
            PWM_ESFLOPPY = 1'b0;
        // Otherwise, use the onboard ESFloppy signals
        end else begin
            if (IO_ROM_SEL) begin
                // If we're in Twiggy mode, hook RDA and SNS up to their own individual pins
                RDA = RDA_ESFLOPPY;
                SNS = SNS_ESFLOPPY;
            end else begin
                // If we're in Sony mode, hook both RDA and SNS to RDA
                RDA = RDA_ESFLOPPY;
                SNS = RDA_ESFLOPPY;
            end
            WRD_ESFLOPPY = WRD;
            _WRQ_ESFLOPPY = _WRQ;
            HDS_ESFLOPPY = HDS;
            PH_ESFLOPPY = PH;
            MT1_ESFLOPPY = MT1;
            MT0_ESFLOPPY = MT0;
            _DR1_ESFLOPPY = _DR1;
            _DR0_ESFLOPPY = _DR0;
            PWM_ESFLOPPY = PWM;
            // And make sure that the external floppy drive signals are inactive
            WRD_EXTFLOPPY = 1'b0;
            _WRQ_EXTFLOPPY = 1'b1;
            HDS_EXTFLOPPY = 1'b0;
            PH_EXTFLOPPY = 4'b0000;
            MT1_EXTFLOPPY = 1'b0;
            MT0_EXTFLOPPY = 1'b0;
            _DR1_EXTFLOPPY = 1'b1;
            _DR0_EXTFLOPPY = 1'b1;
            PWM_EXTFLOPPY = 1'b0;
        end
    end

    // The mouse can either be driven over USB or by a real Lisa/Mac mouse
    logic [6:0] M_USB;

    // Now it's time to do our USB peripherals
    // Previously, the first USB port was for the mouse and the second for the keyboard
    // But now they're flexible and you can plug either device into either port
    // So we basically instantiate two USB HID host controllers, one for each port
    // And then read their type codes to figure out which is which
    // Then we route the mouse data from whichever port has the mouse, and the keyboard data from whichever port has the keyboard

    // Before we do anything else related to USB though, we need to mess with our reset signal a bit
    // The regular reset signal is generated in the DOTCK domain, but we need it in the usbclk domain
    // So we'll create a synchronized version of it here
    (* ASYNC_REG = "TRUE" *) logic usbrst_int, usbrst;
    always_ff @(posedge clk_sys) begin
        if (usbclk_en) begin
            usbrst_int <= _RESET;
            usbrst <= usbrst_int;
        end
    end

    // We also need IOBUFs for the USB data lines since they're bidirectional
    // First for the USB D+ line
    logic usb_dp_in_port0;
    logic usb_dp_out_port0;
    logic usb_dm_in_port0;
    logic usb_dm_out_port0;
    logic usb_oe_port0;
    assign MOUSE_DP = usb_oe_port0 ? usb_dp_out_port0 : 1'bZ;
    assign usb_dp_in_port0 = MOUSE_DP;

    assign MOUSE_DN = usb_oe_port0 ? usb_dm_out_port0 : 1'bZ;
    assign usb_dm_in_port0 = MOUSE_DN;

    logic [1:0] usb_typ_port0;
    logic usb_report_port0;
    logic [7:0] usb_mouse_btn_port0;
    logic signed [7:0] usb_mouse_dx_port0;
    logic signed [7:0] usb_mouse_dy_port0;
    logic [7:0] usb_key_modifiers_port0;
    logic [7:0] usb_key1_port0;
    // Instantiate the USB HID host module for the first USB port (port 0, previously hard-coded to be for the mouse)
    `ifndef SIMULATION
        usb_hid_host usb_port0 (
            .usbclk(clk_sys), // stubbed usb_hid_host ignores this clock
            .usbrst_n(usbrst), // Active-low reset
            .usb_dm(usb_dm_out_port0), // USB I/O
            .usb_dp(usb_dp_out_port0),
            .usb_dp_in(usb_dp_in_port0),
            .usb_dm_in(usb_dm_in_port0),
            .usb_oe(usb_oe_port0),
            .typ(usb_typ_port0), // Type 2 = mouse, type 1 = keyboard
            .report(usb_report_port0), // Pulses when we get a report from the device
            .mouse_btn(usb_mouse_btn_port0), // Mouse button states
            .mouse_dx(usb_mouse_dx_port0), // Mouse x and y movement
            .mouse_dy(usb_mouse_dy_port0),
            .key_modifiers(usb_key_modifiers_port0), // Keyboard key modifier bits
            .key1(usb_key1_port0) // Up to 4 simultaneous keycodes
        );
    `endif

    // Now repeat all that for the second USB port (port 1), previously hard-coded to be for the keyboard but now can be for anything
    // We also need IOBUFs for the USB data lines since they're bidirectional
    // First for the USB D+ line
    logic usb_dp_in_port1;
    logic usb_dp_out_port1;
    logic usb_dm_in_port1;
    logic usb_dm_out_port1;
    logic usb_oe_port1;
    assign KBD_DP = usb_oe_port1 ? usb_dp_out_port1 : 1'bZ;
    assign usb_dp_in_port1 = KBD_DP;

    assign KBD_DN = usb_oe_port1 ? usb_dm_out_port1 : 1'bZ;
    assign usb_dm_in_port1 = KBD_DN;

    logic [1:0] usb_typ_port1;
    logic usb_report_port1;
    logic [7:0] usb_mouse_btn_port1;
    logic signed [7:0] usb_mouse_dx_port1;
    logic signed [7:0] usb_mouse_dy_port1;
    logic [7:0] usb_key_modifiers_port1;
    logic [7:0] usb_key1_port1;
    // Instantiate the USB HID host module for the second USB port (port 1, previously hard-coded to be for the keyboard)
    `ifndef SIMULATION
        usb_hid_host usb_port1 (
            .usbclk(clk_sys), // stubbed usb_hid_host ignores this clock
            .usbrst_n(usbrst), // Active-low reset
            .usb_dm(usb_dm_out_port1), // USB I/O
            .usb_dp(usb_dp_out_port1),
            .usb_dp_in(usb_dp_in_port1),
            .usb_dm_in(usb_dm_in_port1),
            .usb_oe(usb_oe_port1),
            .typ(usb_typ_port1), // Type 2 = mouse, type 1 = keyboard
            .report(usb_report_port1), // Pulses when we get a report from the device
            .mouse_btn(usb_mouse_btn_port1), // Mouse button states
            .mouse_dx(usb_mouse_dx_port1), // Mouse x and y movement
            .mouse_dy(usb_mouse_dy_port1),
            .key_modifiers(usb_key_modifiers_port1), // Keyboard key modifier bits
            .key1(usb_key1_port1) // Up to 4 simultaneous keycodes
        );
    `endif

    // Now we just need to look at the type codes from each port and route the data accordingly
    logic signed [7:0] mouse_dx_selected;
    logic signed [7:0] mouse_dy_selected;
    logic [7:0] mouse_btn_selected;
    logic mouse_report_selected;
    logic [7:0] key_modifiers_selected;
    logic [7:0] key1_selected;
    logic key_report_selected;

    always_comb begin
        if (usb_typ_port0 == 2'd1) begin
            // If the port0 type is 1, then it's a keyboard, so route it to the keyboard module
            key_modifiers_selected = usb_key_modifiers_port0;
            key1_selected = usb_key1_port0;
            key_report_selected = usb_report_port0;
        end else if (usb_typ_port1 == 2'd1) begin
            // Otherwise, if port1 is a keyboard, then route that to the keyboard module
            // Notice that if both ports are keyboards, port0 takes priority
            key_modifiers_selected = usb_key_modifiers_port1;
            key1_selected = usb_key1_port1;
            key_report_selected = usb_report_port1;
        end else begin
            // If neither port is a keyboard, just send zeros to the keyboard module
            key_modifiers_selected = 8'b0;
            key1_selected = 8'b0;
            key_report_selected = 1'b0;
        end
        if (usb_typ_port0 == 2'd2) begin
            // If the port0 type is 2, then it's a mouse, so route it to the mouse module
            mouse_dx_selected = usb_mouse_dx_port0;
            mouse_dy_selected = usb_mouse_dy_port0;
            mouse_btn_selected = usb_mouse_btn_port0;
            mouse_report_selected = usb_report_port0;
        end else if (usb_typ_port1 == 2'd2) begin
            // Otherwise, if port1 is a mouse, then route that to the mouse module
            // Once again, if both ports are the same peripheral, then port0 takes priority
            mouse_dx_selected = usb_mouse_dx_port1;
            mouse_dy_selected = usb_mouse_dy_port1;
            mouse_btn_selected = usb_mouse_btn_port1;
            mouse_report_selected = usb_report_port1;
        end else begin
            // If neither port is a mouse, just send zeros to the mouse module
            mouse_dx_selected = 8'sb0;
            mouse_dy_selected = 8'sb0;
            mouse_btn_selected = 1'b0;
            mouse_report_selected = 1'b0;
        end
    end

    logic KBD_in_USB;
    logic KBD_out_USB;
    // Finally, instantiate the USB mouse interface module, routing in the appropriate signals
    `ifndef SIMULATION
        usb_mouse_interface usb_mouse_interface (
            .clk_sys(clk_sys),
            .usbclk_en(usbclk_en),
            .usbrst(usbrst),
            .mouse_dx_in(mouse_dx_selected),
            .mouse_dy_in(mouse_dy_selected),
            .mouse_btn_in(mouse_btn_selected),
            .report(mouse_report_selected),
            .M(M_USB)
        );
        // And now the USB keyboard one.
        // NOTE: this is the legacy Vivado USB-host keyboard path. MiSTer
        // hardwires KBD_SEL=0 (Lisa.sv) so it is muxed out; the adapter now
        // takes a key-EVENT stream ({key_code_in, key_press_in} + report) and
        // the Vivado usb_host only exposes held-key LEVELS, so this path is left
        // inert (report tied low = no key events) until a level->event converter
        // is added. key1_selected is passed through only to keep it driven.
        usb_keyboard_interface usb_kbd_interface (
            .clk_sys(clk_sys),
            .usbclk_en(usbclk_en),
            .usbrst(usbrst),
            .key_code_in(key1_selected),
            .key_press_in(1'b0),
            .report(1'b0),
            .KBD_in(KBD_out_USB),
            .KBD_out(KBD_in_USB)
        );
    `endif

    // There's a little more we need to do for the keyboard though; it's bidirectional, so we need to make an IOBUF for the Lisa keyboard interface
    logic KBD_in_LISA;
    logic KBD_out_LISA;
    assign KBD_line_out = KBD_out_LISA;    // drive value (0 = pulling the line low)
    assign KBD_in_LISA  = KBD_line_in;     // combined line state from Lisa.sv

    // And we have to mux between the USB and Lisa keyboard interfaces, depending on the KBD_SEL signal
    always_comb begin
        // If it's high, then use the USB keyboard
        if (KBD_SEL) begin
            KBD_in = KBD_in_USB;
            KBD_out_USB = KBD_out;
            KBD_out_LISA = 1'b1; // Make sure the Lisa keyboard interface is inactive
        // And if it's low, use the Lisa keyboard interface
        end else begin
            KBD_in = KBD_in_LISA;
            KBD_out_LISA = KBD_out;
            KBD_out_USB = 1'b1; // Make sure the USB keyboard interface is inactive
        end
    end

    // The Lisa mouse interface is literally just the M_LISA line from the port declaration
    // So now mux between them based on the MOUSE_SEL signal
    always_comb begin
        // If MOUSE_SEL is high, use the USB mouse
        if (MOUSE_SEL) begin
            M = M_USB;
        // Otherwise, use the Lisa mouse interface
        end else begin
            M = M_LISA;
        end
    end

    // In real life, the ProFile can either be a real ProFile, or an onboard ESProFile emulator
    // We'll need to mux between them, but first let's worry about the ProFile's bidirectional data bus
    genvar i;
    logic [7:0] PD_in_ESProFile;
    logic [7:0] PD_out_ESProFile;
    logic _ProFile_EN_ESProFile;
    logic PR_W_ungated_ESProFile;
    logic _CRES_out_ESProFile;
    logic _CRES_in_ESProFile;

    logic [7:0] PD_in_ExtProFile;
    logic [7:0] PD_out_ExtProFile;
    logic _ProFile_EN_ExtProFile;
    logic PR_W_ungated_ExtProFile;
    logic _CRES_out_ExtProFile;
    logic _CRES_in_ExtProFile;
    // Was a behavioral tri-state bus + open-collector reset. Quartus resolves
    // internal z-nets unpredictably (same hazard as BD_OE / the KBD line), so
    // the ESProFile bus is now explicit: top outputs its drive value (FF =
    // pulled-up idle) and reads the combined line from Lisa.sv, which muxes
    // in the profile emulator's drive.
    assign PD_ESPROFILE_out = (~_ProFile_EN_ESProFile && ~PR_W_ungated_ESProFile)
                              ? PD_out_ESProFile : 8'hFF;
    assign PD_in_ESProFile  = PD_ESPROFILE_in;

    // CRES/PRES reset line: top is the only driver on MiSTer (plain output).
    assign _PRES_ESPROFILE  = _CRES_out_ESProFile;
    assign _CRES_in_ESProFile = _PRES_ESPROFILE;

    // Now do the same thing for the external "real" ProFile
    generate
        for (i = 0; i < 8; i++) begin: pd_extprofile_gen
            assign PD_EXTPROFILE[i] = (~_ProFile_EN_ExtProFile && ~PR_W_ungated_ExtProFile) ? PD_out_ExtProFile[i] : 1'bZ;
            assign PD_in_ExtProFile[i] = PD_EXTPROFILE[i];
        end
    endgenerate

    assign _PRES_EXTPROFILE = ~_CRES_out_ExtProFile ? 1'b0 : 1'bZ;
    assign _CRES_in_ExtProFile = _PRES_EXTPROFILE;
    // For now, just hard-code something to the "ESProFile comm bus"
    assign ESPROFILE_COMM_BUS = 3'b101;
    // And now we just have to mux all that, along with some unidirectional control signals
    // This depends on the state of the HDD_SRC switch
    always_comb begin
        // If HDD_SRC is low, use the ESProFile
        if (!HDD_SRC) begin
            PD_in = PD_in_ESProFile;
            PD_out_ESProFile = PD_out;
            _ProFile_EN_ESProFile = _ProFile_EN;
            PR_W_ungated_ESProFile = PR_W_ungated;
            _CRES_in = _CRES_in_ESProFile;
            _CRES_out_ESProFile = _CRES_out;
            _CMD_ESPROFILE = _CMD;
            _BSY = _BSY_ESPROFILE;
            R_W_ESPROFILE = DR_W;
            _STRB_ESPROFILE = _PSTRB;
            _PARITY = _PARITY_ESPROFILE;
            OCD = OCD_ESPROFILE;
            // But make sure that the external ProFile is left in a safe state (all outputs deasserted)
            PD_out_ExtProFile = 8'b00000000;
            _ProFile_EN_ExtProFile = 1'b1;
            PR_W_ungated_ExtProFile = 1'b1;
            _CRES_out_ExtProFile = 1'b1;
            _CMD_EXTPROFILE = 1'b1;
            R_W_EXTPROFILE = 1'b1;
            _STRB_EXTPROFILE = 1'b1;
        // Otherwise, use the external "real" ProFile
        end else begin
            PD_in = PD_in_ExtProFile;
            PD_out_ExtProFile = PD_out;
            _ProFile_EN_ExtProFile = _ProFile_EN;
            PR_W_ungated_ExtProFile = PR_W_ungated;
            _CRES_in = _CRES_in_ExtProFile;
            _CRES_out_ExtProFile = _CRES_out;
            _CMD_EXTPROFILE = _CMD;
            _BSY = _BSY_EXTPROFILE;
            R_W_EXTPROFILE = DR_W;
            _STRB_EXTPROFILE = _PSTRB;
            _PARITY = _PARITY_EXTPROFILE;
            OCD = OCD_EXTPROFILE;
            // And make sure that ESProFile is left in a safe state
            PD_out_ESProFile = 8'b00000000;
            _ProFile_EN_ESProFile = 1'b1;
            PR_W_ungated_ESProFile = 1'b1;
            _CRES_out_ESProFile = 1'b1;
            _CMD_ESPROFILE = 1'b1;
            R_W_ESPROFILE = 1'b1;
            _STRB_ESPROFILE = 1'b1;
        end
    end

    IO_board io_board(
        .PH(PH),
        .WRD(WRD),
        ._WRQ(_WRQ),
        .RDA(RDA),
        ._DR1(_DR1),
        ._DR0(_DR0),
        .HDS(HDS),
        .SNS(SNS),
        .MT1(MT1),
        .MT0(MT0),
        ._IRQ(_IRQ),
        ._RSIR(_RSIR),
        ._KBIR(_KBIR),
        ._IOIR(_IOIR),
        .E(E),
        ._RESET_SYSTEM(_RESET),
        .CPUCK(CPUCK),
        ._LDMA(_LDMA),
        ._BGACK(_BGACK),
        ._BR(_BR),
        ._BG0(_BG0),
        ._BG(_BG),
        .BD_in(BD),
        .BD_out(BD_IO),
        .BD_OE(BD_OE_IO),
        .A(A),
        ._VMA(_VMA),
        ._VPA_in(_VPA),
        ._VPA_out(_VPA_IO),
        .VPA_OE(VPA_OE_IO),
        ._DTACK_in(_DTACK),
        ._DTACK_out(_DTACK_IO),
        .DTACK_OE(DTACK_OE_IO),
        ._AS(_AS),
        .READ(READ),
        ._LDS(_LDS),
        ._UDS(_UDS),
        ._INTIO(_INTIO),
        .OCD(OCD),
        .PD_in(PD_in),
        .PD_out(PD_out),
        ._ProFile_EN(_ProFile_EN),
        .PR_W_ungated(PR_W_ungated),
        ._PARITY(_PARITY),
        ._PSTRB(_PSTRB),
        .DR_W(DR_W),
        ._BSY(_BSY),
        ._CMD(_CMD),
        //.SPKRIN(SPKRIN),
        .TONE(TONE),
        .CONT(CONT),
        .KBD_in(KBD_in),
        .KBD_out(KBD_out),
        .M(M),
        .SYNCA(SYNCA),
        .TXDA(TXDA),
        .RTSA(RTSA),
        .DTRA(DTRA),
        .RXDA(RXDA),
        .CTSA(CTSA),
        .DCDA(DCDA),
        .TRXCA(TRXCA),
        .RTXCA(RTXCA),
        .TXDB(TXDB),
        .DTRB(DTRB),
        .RTSB(RTSB),
        .RXDB(RXDB),
        .CTSB_TRXCB(CTSB_TRXCB),
        ._CRES_in(_CRES_in),
        ._CRES_out(_CRES_out),
        ._NMI(_NMI_IO),
        .NMI_OE(NMI_OE_IO),
        ._PWRSW(_PWRSW_falling),
        .ON(ON),

        .sysclk(sysclk_ibuf),
        .c16m_en(c16m_en),
        .copck2x_en(copck2x_en),
        .COPCK(COPCK),
        .sccck_en(sccck_en),
        .E_pos_phase(E_pos_phase),
        .E_neg_phase(E_neg_phase),
        .clk_sys(clk_sys),
        .dotck_en(dotck_en),
        .VC(VC),
        .IO_ROM_SEL(IO_ROM_SEL),
        // RTC clock seeding
        .rtc_nibbles(rtc_nibbles),
        .rtc_valid(rtc_valid),
        .rtc_load_req(rtc_load_req),
        .rtc_seed_done(rtc_seed_done),
        .spoof_88(GPIO[0])
    );

    logic [15:0] DIN_SRAM;
    logic [15:0] DOUT_SRAM;
    logic SRAM_BUS_DIR;
    generate
        for (i = 0; i < 16; i++) begin: sram_d_gen
            assign D_SRAM[i] = ~SRAM_BUS_DIR ? DOUT_SRAM[i] : 1'bZ;
            assign DIN_SRAM[i] = D_SRAM[i];
        end
    endgenerate

    // (Removed the 128-deep LTRC dot-trace buffer — it did its job finding the
    //  BD tri-state bug and was too large to keep in the device.)

    `ifdef SIMULATION
        // In simulation, mem_board_2mb uses an internal RAM model in SDRAM_Controller_Flat.
    `else
        // On hardware, mem_board_2mb drives the external SRAM chip.
    `endif
        mem_board_2mb slot1(
            .RA(RA),
            .A16(A16),
            .A17(A17),
            .A18(A18),
            .A19(A19),
            .A20(A20),
            .RAM_SEL(RAM_SEL),
            .clk_sys(clk_sys),
        .dotck_en(dotck_en),
            ._UDS(_UDS),
            ._LDS(_LDS),
            ._CAS(_CAS),
            ._RAS(_RAS),
            .MREAD(MREAD),
            .MD_IN(MD_OUT),
            .MD_OUT(MD_IN),
            ._HDER_in(_HDER),
            ._HDER_out(_HDER_MEM),
            .HDER_OE(HDER_OE_MEM),
            ._SFER_in(_SFER),
            ._SFER_out(_SFER_MEM),
            .SFER_OE(SFER_OE_MEM),
            ._CE_SRAM(_CE_SRAM),
            ._OE_SRAM(_OE_SRAM),
            ._WE_SRAM(_WE_SRAM),
            ._UDS_SRAM(_UDS_SRAM),
            ._LDS_SRAM(_LDS_SRAM),
            .A_SRAM(A_SRAM),
            .DIN_SRAM(DIN_SRAM),
            .DOUT_SRAM(DOUT_SRAM),
            .SRAM_BUS_DIR(SRAM_BUS_DIR),
            ._RAS_SDRAM_out(_RAS_SRAM),
            ._CAS_SDRAM_out(_CAS_SRAM)
        );

endmodule
