//
// rtc_lisa.sv
//
// Convert a MiSTer host RTC snapshot (MSM6242B BCD layout from sys/hps_io.sv)
// into the Apple Lisa COP421 clock-set packet: sixteen nibbles, sent idx 0..15
// as the COPS sequence 0x2C, {0x10|nib}..., 0x25 (see MiSTer_Lisa_RTC_Integration.md
// and references/lisaem/src/lisa/io_board/cops.c).
//
// Nibble packet (idx : field), per cops.c fall-through decode:
//   0..4 : timer/alarm  (binary, seeded 0 -> timer disabled)
//   5    : year          (BINARY 0..15 = (host_year-1980) mod 16)
//   6    : day-of-year hundreds (BCD)
//   7    : day-of-year tens     (BCD)
//   8    : day-of-year units    (BCD)
//   9    : hour  tens (BCD)   a : hour  units (BCD)
//   b    : min   tens (BCD)   c : min   units (BCD)
//   d    : sec   tens (BCD)   e : sec   units (BCD)
//   f    : tenths (BCD, seeded 0 -- MiSTer RTC is 1s resolution)
//
// The host gives day-of-MONTH + month; the COP wants day-of-YEAR, so we sum the
// month offset (leap-adjusted) here. Output `nibbles` packs idx i in [i*4 +: 4].
// A one-shot `load_req` pulses when a NEW RTC snapshot (RTC[64] toggle) has been
// converted and is stable, for the IO_board COP sequencer to consume.
//
// Pure/synthesizable; no COP bus contact (that lives in the IO_board sequencer).
//

module rtc_lisa
(
	input             clk,
	input             rst,          // hold in reset -> no requests
	input      [64:0] rtc,          // hps_io RTC (bit 64 = update toggle)
	output reg [63:0] nibbles,      // 16 nibbles, idx i at [i*4 +: 4]
	output reg        valid,        // a converted packet is available
	output reg        load_req      // 1-clk pulse when a fresh packet is ready
);

	// ---- BCD helpers --------------------------------------------------------
	function [7:0] bcd2bin(input [7:0] b);
		bcd2bin = b[7:4]*8'd10 + b[3:0];
	endfunction

	// ---- Extract host fields (all BCD except we treat them numerically) -----
	wire [7:0] h_sec   = rtc[7:0];
	wire [7:0] h_min   = rtc[15:8];
	wire [7:0] h_hour  = rtc[23:16];
	wire [7:0] h_day   = rtc[31:24];   // day of month, BCD
	wire [7:0] h_month = rtc[39:32];   // month 1..12, BCD
	wire [7:0] h_year  = rtc[47:40];   // year 2000-based, BCD (0x26 = 2026)

	wire [7:0] year_bin  = bcd2bin(h_year);            // 0..99  -> 2000+year
	wire [11:0] year_full = 12'd2000 + {4'd0, year_bin};
	wire        leap      = (year_full[1:0] == 2'b00); // 2000..2099: leap iff /4
	wire [7:0]  mon_bin   = bcd2bin(h_month);          // 1..12
	wire [7:0]  day_bin   = bcd2bin(h_day);            // 1..31

	// year slot = (year_full - 1980) mod 16, as a 4-bit binary nibble
	wire [11:0] yr_off    = year_full - 12'd1980;
	wire [3:0]  year_slot = yr_off[3:0];               // mod 16

	// cumulative days before month (non-leap): index 1..12
	reg [8:0] days_before;
	always @(*) begin
		case (mon_bin)
			8'd1:  days_before = 9'd0;
			8'd2:  days_before = 9'd31;
			8'd3:  days_before = 9'd59;
			8'd4:  days_before = 9'd90;
			8'd5:  days_before = 9'd120;
			8'd6:  days_before = 9'd151;
			8'd7:  days_before = 9'd181;
			8'd8:  days_before = 9'd212;
			8'd9:  days_before = 9'd243;
			8'd10: days_before = 9'd273;
			8'd11: days_before = 9'd304;
			8'd12: days_before = 9'd334;
			default: days_before = 9'd0;
		endcase
	end

	wire        add_leap = leap && (mon_bin > 8'd2);
	wire [8:0]  doy      = days_before + {1'b0, day_bin} + (add_leap ? 9'd1 : 9'd0); // 1..366

	// day-of-year -> 3 BCD nibbles (hundreds/tens/units)
	wire [3:0]  doy_h = (doy >= 9'd300) ? 4'd3 : (doy >= 9'd200) ? 4'd2 :
	                    (doy >= 9'd100) ? 4'd1 : 4'd0;
	wire [8:0]  doy_r = doy - {5'd0, doy_h}*9'd100;
	wire [3:0]  doy_t = doy_r / 9'd10;
	wire [3:0]  doy_u = doy_r % 9'd10;

	// assemble the 16 nibbles (idx 0..15)
	wire [63:0] packet = {
		4'd0,          // f : tenths
		h_sec[3:0],    // e : sec units
		h_sec[7:4],    // d : sec tens
		h_min[3:0],    // c : min units
		h_min[7:4],    // b : min tens
		h_hour[3:0],   // a : hour units
		h_hour[7:4],   // 9 : hour tens
		doy_u,         // 8 : day units
		doy_t,         // 7 : day tens
		doy_h,         // 6 : day hundreds
		year_slot,     // 5 : year (binary 0..15)
		4'd0,          // 4 : timer
		4'd0,          // 3
		4'd0,          // 2
		4'd0,          // 1
		4'd0           // 0 : timer
	};

	// ---- Update-toggle edge detect + settle --------------------------------
	// RTC[64] flips on each fresh HPS snapshot. Wait a few clk for the 4 words
	// to be stable, then latch the packet and pulse load_req once.
	reg        tgl_d, tgl_d2;
	reg [3:0]  settle;
	always @(posedge clk) begin
		load_req <= 1'b0;
		if (rst) begin
			tgl_d   <= rtc[64];
			tgl_d2  <= rtc[64];
			settle  <= 4'd0;
			valid   <= 1'b0;
		end else begin
			tgl_d  <= rtc[64];
			tgl_d2 <= tgl_d;
			if (tgl_d ^ tgl_d2) begin
				settle <= 4'd8;                 // new toggle: start settle timer
			end else if (settle != 4'd0) begin
				settle <= settle - 4'd1;
				if (settle == 4'd1) begin       // settled -> commit
					nibbles  <= packet;
					valid    <= 1'b1;
					load_req <= 1'b1;
				end
			end
		end
	end

endmodule
