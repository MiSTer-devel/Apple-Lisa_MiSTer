// clock_divider.v
// Clock-ENABLE generator for the single-clock Lisa core.
//
// The whole core runs on one real clock, clk_sys (81.50016 MHz, straight off the
// PLL and on a global clock network). Every "clock" the Lisa needs is provided
// here as a one-clk_sys-cycle enable strobe that pulses at the moment the old
// derived clock had a rising edge. Consumers use `@(posedge clk_sys) if (x_en)`
// instead of `@(posedge x)`, which removes all the fabric-routed derived clocks
// that could not meet hold timing / route.
//
// Exact (harmonic) rates use counters; the non-harmonic rates use a phase
// accumulator whose CARRY-OUT is the strobe (average frequency correct to a few
// ppm, one-cycle-wide pulse, glitch-free).
//
//   dotck_en    selectable: /4 (20.4MHz), /2 (40.75), 3-of-4 (~61.1), /1 (81.5)
//   c16m_en     clk_sys / 5   -> 16.300032 MHz
//   c5m_en      clk_sys / 16  ->  5.09376  MHz
//   copck2x_en  ~7.80    MHz  (COPCK_2x)   phase accumulator
//   sccck2x_en  ~7.3728  MHz  (SCCCK_2x)   phase accumulator
//   usbclk_en   ~12.00   MHz  (usbclk)     phase accumulator
//
// See todo.md: the ~61.1MHz (60M turbo) DOTCK enable is an irregular 3-of-4
// pattern; the 20/40/80 modes are exact.

`timescale 1 ps / 1 ps

module clock_divider (
    input  wire        clk_sys,     // 81.50016 MHz master clock
    input  wire [1:0]  speed_sel,   // DOTCK speed select (async; synchronized here)
    output wire        dotck_en,    // DOTCK rising-edge strobe (rate per speed_sel)
    output wire        c16m_en,     // 16.300032 MHz strobe
    output wire        c5m_en,      //  5.09376  MHz strobe
    output wire        copck2x_en,  //  7.80     MHz strobe
    output wire        sccck2x_en,  //  7.3728   MHz strobe
    output wire        usbclk_en    // 12.00     MHz strobe
);

    // --- Synchronize the (async) speed-select switches into clk_sys ---------
    (* ASYNC_REG = "TRUE" *) reg [1:0] speed_sel_meta = 2'b11;
    (* ASYNC_REG = "TRUE" *) reg [1:0] speed_sel_sync = 2'b11;
    always @(posedge clk_sys) begin
        speed_sel_meta <= speed_sel;
        speed_sel_sync <= speed_sel_meta;
    end

    // --- DOTCK enable -------------------------------------------------------
    // speed_sel mapping matches the OSD menu "CPU Speed 1x/2x/3x/4x" = 00/01/10/11:
    //   00 (1x) -> 20.4MHz  (/4)     01 (2x) -> 40.75MHz (/2)
    //   10 (3x) -> 61.1MHz  (3-of-4) 11 (4x) -> 81.5MHz  (/1)
    // (The old behavioral mux in top.sv had this inverted, which ran the default
    //  1x setting at 80MHz -> 4x-too-fast video. Fixed here.)
    reg [1:0] dcnt = 2'b00;
    always @(posedge clk_sys) begin
        dcnt <= dcnt + 2'b01;
    end
    reg dotck_en_r;
    always @(*) begin
        case (speed_sel_sync)
            2'b00:   dotck_en_r = (dcnt == 2'b00);   // 1x -> /4  -> 20.4 MHz
            2'b01:   dotck_en_r = (dcnt[0] == 1'b0); // 2x -> /2  -> 40.75 MHz
            2'b10:   dotck_en_r = (dcnt != 2'b11);   // 3x -> 3/4 -> ~61.1 MHz (irregular; see todo.md)
            default: dotck_en_r = 1'b1;              // 4x -> /1  -> 81.5 MHz
        endcase
    end
    assign dotck_en = dotck_en_r;

    // --- C16M enable = clk_sys / 5 -----------------------------------------
    reg [2:0] c16m_cnt = 3'd0;
    always @(posedge clk_sys) begin
        if (c16m_cnt == 3'd4)
            c16m_cnt <= 3'd0;
        else
            c16m_cnt <= c16m_cnt + 3'd1;
    end
    assign c16m_en = (c16m_cnt == 3'd0);

    // --- C5M enable = clk_sys / 16 -----------------------------------------
    reg [3:0] c5m_cnt = 4'd0;
    always @(posedge clk_sys) begin
        c5m_cnt <= c5m_cnt + 4'd1;
    end
    assign c5m_en = (c5m_cnt == 4'd0);

    // --- COPCK_2x enable ~7.80 MHz (phase accumulator, carry-out strobe) ----
    // COPCK_2x is the COP clock x2 (COPCK itself = 3.90 MHz, derived as
    // copck2x_en/2 in top.sv). Upstream (alexthecat123) clocks the COP from a
    // 7.8 MHz COPCK_2x net; ours was generating 3.90 MHz here (half rate), so
    // the COP sampled the serial keyboard 2x too slow and garbled every key
    // (e.g. reset 0x80->0x85, 'A' 0xF0->0x30). Corrected to 7.80 MHz.
    // inc = round((7.80 / 81.50016) * 2^32) = 411061326
    reg [31:0] copck_acc = 32'd0;
    wire [32:0] copck_sum = {1'b0, copck_acc} + 33'd411061326;
    always @(posedge clk_sys) begin
        copck_acc <= copck_sum[31:0];
    end
    assign copck2x_en = copck_sum[32];

    // --- SCCCK_2x enable ~7.3728 MHz ---------------------------------------
    // inc = round((7.3728 / 81.50016) * 2^32) = 388537773
    reg [31:0] sccck_acc = 32'd0;
    wire [32:0] sccck_sum = {1'b0, sccck_acc} + 33'd388537773;
    always @(posedge clk_sys) begin
        sccck_acc <= sccck_sum[31:0];
    end
    assign sccck2x_en = sccck_sum[32];

    // --- usbclk enable ~12.00 MHz (USB HID is stubbed on MiSTer) ------------
    // inc = round((12.00 / 81.50016) * 2^32) = 632386008
    reg [31:0] usb_acc = 32'd0;
    wire [32:0] usb_sum = {1'b0, usb_acc} + 33'd632386008;
    always @(posedge clk_sys) begin
        usb_acc <= usb_sum[31:0];
    end
    assign usbclk_en = usb_sum[32];

endmodule
