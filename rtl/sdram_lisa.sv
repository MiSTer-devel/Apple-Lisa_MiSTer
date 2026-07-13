//
// sdram_lisa.sv
//
// Deterministic, Lisa-memory-cycle-locked SDRAM controller for the Lisa MiSTer
// core, enabling reliable operation at CPU speeds 1x/2x/3x/4x.
//
// The Lisa's own DRAM timing (CPU_board.sv) already emits a textbook RAS->CAS
// sequence with a built-in tRCD gap (RAS falls at T0, CAS falls at T2). This
// controller phase-locks a fixed SDRAM access to that:
//
//   RAS falls (T0)  -> +1 clk (row settles) -> ACTIVATE (row = addr[19:8])
//   CAS falls (T2)  -> READ/WRITE (col = addr[7:0]) with auto-precharge
//   +CAS_LATENCY    -> register read data
//   RAS rises (idle)-> AUTO_REFRESH when due (start of the gap, no collision)
//
// Gating READ/WRITE on _CAS actually being low (not a fixed cycle count) makes
// the SAME code correct at every DOTCK rate (4x: RAS->CAS gap = tRCD; 1x: 8 clk
// of slack).
//
// Address remap: SDRAM row = high word-address bits {A20-17,row_addr}=addr[19:8]
// (valid at RAS time); column = low bits col_addr=addr[7:0] (valid at CAS).
// 2 MB -> 12-bit row + 8-bit column, bank 0. AUTO_REFRESH refreshes all rows.
//
// Commands are driven DIRECTLY from the state machine (single register stage,
// same structure as Sorgelig's proven sdram_ctrl), so read data is captured at
// CAS_LATENCY+1 states after the READ. Reuses Sorgelig's init/mode FSM and DDIO
// SDRAM_CLK (sdram_ctrl.sv, (c) 2018 Sorgelig, GPLv3). GPLv3.
//

module sdram_lisa
(
	inout  reg [15:0] SDRAM_DQ,
	output reg [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output reg  [1:0] SDRAM_BA,
	output            SDRAM_nCS,
	output reg        SDRAM_nWE,
	output reg        SDRAM_nRAS,
	output reg        SDRAM_nCAS,
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	input             init,        // FPGA-config-done init pulse
	input             clk,         // clk_sys (81.5 MHz)
	input             dotck_en,    // DOTCK strobe (for gap length in dot-cycles)

	// Lisa memory-cycle interface (from SDRAM_Controller_Flat via top/Lisa.sv)
	input             ras_n,       // Lisa _RAS: falls at T0 (row valid)
	input             cas_n,       // Lisa _CAS: falls at T2 (col valid)
	input      [19:0] addr,        // full word address {A20-17,row_addr,col_addr}
	input             we,          // 1 = write cycle (_OE_SRAM = ~R_W)
	input             wrl,         // write low byte  (LDS)
	input             wrh,         // write high byte (UDS)
	input      [15:0] din,         // write data
	output reg [15:0] dout,        // read data (valid within the memory cycle)

	input       [1:0] rd_dly,      // read-capture tuning (extra clk past CL)

	output reg [23:0] refresh_cnt, // diagnostics
	output reg [15:0] access_cnt
);

assign SDRAM_nCS  = 0;
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY = 3'd2;   // tRCD ~2 clk @81.5MHz
localparam CAS_LATENCY  = 3'd2;
localparam MODE = { 3'b000, 1'b1 /*single-write*/, 2'b00 /*std*/, CAS_LATENCY,
                    1'b0 /*sequential*/, 3'b000 /*BL=1*/ };

localparam CMD_NOP          = 3'b111;
localparam CMD_ACTIVE       = 3'b011;
localparam CMD_READ         = 3'b101;
localparam CMD_WRITE        = 3'b100;
localparam CMD_PRECHARGE    = 3'b010;
localparam CMD_AUTO_REFRESH = 3'b001;
localparam CMD_LOAD_MODE    = 3'b000;

wire [11:0] row_bits = addr[19:8];   // valid at RAS time
wire  [7:0] col_bits = addr[7:0];    // valid at CAS time

// ---- Init / mode FSM (from Sorgelig) ----------------------------------------
localparam MODE_NORMAL = 2'b00, MODE_RESET = 2'b01, MODE_LDM = 2'b10, MODE_PRE = 2'b11;
reg [1:0] mode = MODE_RESET;
reg [4:0] reset = 5'h1f;
reg [3:0] icnt = 0;
always @(posedge clk) begin
	reg init_old = 0;
	init_old <= init;
	if (init_old & ~init) begin reset <= 5'h1f; mode <= MODE_RESET; icnt <= 0; end
	else if (reset != 0) begin
		icnt <= icnt + 1'd1;
		if (icnt == 4'hf) begin
			reset <= reset - 5'd1;
			if      (reset == 14) mode <= MODE_PRE;
			else if (reset == 3)  mode <= MODE_LDM;
			else if (reset == 1)  mode <= MODE_NORMAL;
			else                  mode <= MODE_RESET;
		end
	end
end
wire normal = (mode == MODE_NORMAL);

// ---- Access manager (single block: drives SDRAM commands directly) ----------
localparam S_IDLE=3'd0, S_ACT_ISSUE=3'd1, S_ACT=3'd2, S_RDWAIT=3'd3, S_REF=3'd4;
reg [2:0] st = S_IDLE;
reg [3:0] tcnt = 0;
reg [3:0] rd_cnt = 0;   // clk since READ issued
reg ras_d = 1, cas_d = 1;
wire ras_fall = ras_d & ~ras_n;
wire ras_rise = ~ras_d & ras_n;
// CAS low for >=2 clk: SDRAM_Controller_Flat latches col_addr ON the _CAS-fall
// edge (registered, valid the NEXT clk), so only then is the column stable.
wire cas_low  = ~cas_n & ~cas_d;

reg [9:0] rfs_cnt = 0;
reg [7:0] rfs_pending = 0;   // refreshes owed; burst-drained during idle gaps so
                             // sustained load (active video + busy CPU) can't
                             // starve refresh -> RAM decay -> screen interference
reg       ref_fire;          // a refresh is being issued this cycle
// Gap length in DOTCK cycles that RAS has been high. A brief inter-access gap
// is exactly 3 dotck (RAS high T5..T7); a genuine idle gap (blanking / idle
// slot) is >=11 dotck. Only refresh when rashi>=4 -> guaranteed a long idle
// with the next access >=~8 dotck away, so tRFC finishes before it. Counting in
// DOTCK (not clk) makes this correct at every speed (no single clk threshold
// separates 1x's 12-clk brief gap from 4x's 11-clk idle gap).
reg [3:0] rashi = 0;

// ---- Slot-phase tracker (ref_mode=1) ---------------------------------------
// The Lisa memory cycle is a fixed 8-DOTCK slot; RAS falls at the slot boundary
// (T0, phase 0). sphase counts DOTCK within the slot and is RESYNCED to 0 on
// every ras_fall, so during a long idle stretch (blanking / idle slots) it still
// predicts the boundaries where the NEXT access could begin. boundary_idle
// pulses when a full slot elapses with RAS high (an idle slot boundary): at that
// instant the next possible ras_fall is a full 8 DOTCK away -> a refresh issued
// now has guaranteed headroom for tRFC at 1x/2x/3x. ref_req latches that intent
// until a refresh is issued (or an access preempts it).
reg [2:0] sphase = 0;
reg       boundary_idle = 0;
reg       ref_req = 0;

// Access latch: a ras_fall that arrives while the FSM is busy (mid-refresh, from
// a cadence disruption like an interrupt) is REMEMBERED here instead of being
// silently dropped. The Lisa holds addr/RAS/CAS stable for the whole memory
// cycle, so once the refresh finishes we service the still-pending access a few
// clk late -> read data is still delivered before the Lisa latches it (ample
// slack at 1x/2x). This makes refresh collisions invisible rather than fatal.
reg       acc_pend = 0;

always @(posedge clk) begin
	ras_d <= ras_n;
	cas_d <= cas_n;
	ref_fire = 1'b0;                                          // set below on issue

	if (!ras_n)          rashi <= 4'd0;                        // access -> reset
	else if (dotck_en)   rashi <= (rashi < 4'd15) ? rashi + 1'd1 : 4'd15;

	// slot phase: resync on ras_fall (= boundary), else advance per DOTCK. A full
	// wrap (7->0) with RAS still high marks an idle slot boundary.
	boundary_idle <= 1'b0;
	if (ras_fall) begin
		sphase <= 3'd0;
	end else if (dotck_en) begin
		if (sphase == 3'd7) begin
			sphase <= 3'd0;
			if (ras_n) boundary_idle <= 1'b1;             // idle slot completed
		end else sphase <= sphase + 1'd1;
	end

	// arm the refresh request at a safe boundary; an access always preempts it.
	// (the S_IDLE issue below clears it when a refresh actually fires.)
	if (ras_fall)             ref_req <= 1'b0;
	else if (boundary_idle)   ref_req <= 1'b1;

	// access latch: remember any ras_fall; cleared when we begin serving it
	// (S_ACT_ISSUE, below) or if the Lisa ends the cycle first (ras_rise).
	if (ras_fall)      acc_pend <= 1'b1;
	else if (ras_rise) acc_pend <= 1'b0;

	// default command = NOP, no data drive
	{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	SDRAM_A  <= 13'd0;
	SDRAM_BA <= 2'b00;
	SDRAM_DQ <= 16'bz;

	if (!normal) begin
		st <= S_IDLE; tcnt <= 0; rfs_pending <= 0; rfs_cnt <= 0;
		if (icnt == 4'h0) begin
			if (mode == MODE_PRE) begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
				SDRAM_A <= 13'b0010000000000;         // A10=1: precharge all
			end else if (mode == MODE_LDM) begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
				SDRAM_A <= MODE;
			end
		end
	end else begin
		case (st)
			S_IDLE: begin
				tcnt <= 0;
				// Serve a fresh OR a latched (recovered-from-refresh) access. Only
				// serve a still-live cycle (ras_n low); a pend whose cycle already
				// ended is dropped by the ras_rise clear above.
				// Refresh only at a phase-locked idle-slot boundary (ref_req),
				// double-guarded by rashi>=4 (kills a 1-clk ras/dotck skew that
				// could false-trigger on an active slot).
				if (ras_fall || (acc_pend && !ras_n)) begin
					acc_pend <= 1'b0;              // consume; begin serving
					st <= S_ACT_ISSUE;             // wait 1 clk for row to settle
				end else if (rfs_pending != 0 && ref_req && rashi >= 4'd4) begin
					{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;
					ref_fire = 1'b1;
					refresh_cnt <= refresh_cnt + 1'd1;
					ref_req <= 1'b0;               // consume; re-arm at next boundary
					st <= S_REF;
					tcnt <= 0;
				end
			end

			S_ACT_ISSUE: begin
				{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
				SDRAM_BA <= 2'b00;
				SDRAM_A  <= {1'b0, row_bits};        // 13-bit row
				tcnt     <= 0;
				st       <= S_ACT;
			end

			S_ACT: begin
				tcnt <= tcnt + 1'd1;
				if (cas_low && tcnt >= RASCAS_DELAY-1'd1 && (!we || wrl || wrh)) begin
					SDRAM_BA <= 2'b00;
					// A[12:11]=DQM, A[10:9]=2'b10 (A10=auto-precharge), A[8:0]=col
					SDRAM_A  <= { (we ? ~{wrh,wrl} : 2'b00), 2'b10, 1'b0, col_bits };
					if (we) begin
						{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
						SDRAM_DQ   <= din;
						access_cnt <= access_cnt + 1'd1;
						st <= S_IDLE;
					end else begin
						{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
						rd_cnt <= 0;
						st <= S_RDWAIT;
					end
				end else if (ras_n) begin
					// access ended before READ/WRITE: close the open row
					{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
					SDRAM_A <= 13'b0010000000000;
					st <= S_IDLE;
				end
			end

			// Read data capture: nominally CAS_LATENCY clk after the READ state,
			// live-tunable +0..3 (rd_dly) to nail the DDIO-shifted capture point.
			S_RDWAIT: begin
				rd_cnt <= rd_cnt + 1'd1;
				if (rd_cnt >= (CAS_LATENCY + {1'b0, rd_dly})) begin
					dout       <= SDRAM_DQ;
					access_cnt <= access_cnt + 1'd1;
					st         <= S_IDLE;
				end
			end

			S_REF: begin                              // tRFC busy (~60ns = 5 clk)
				tcnt <= tcnt + 1'd1;
				// exit at tcnt>=4: AUTO_REFRESH->next ACTIVATE spans ~7 clk (>tRFC),
				// while minimizing how long a latched access waits behind a refresh.
				if (tcnt >= 4'd4) st <= S_IDLE;
			end
			default: st <= S_IDLE;
		endcase
	end

	// Refresh backlog: one owed per ~450 clk (5.5us -> ample vs the 7.8us/row
	// requirement); decremented when a refresh is issued. inc and dec cancel if
	// they coincide. Burst-draining in idle gaps keeps this small under load.
	if (normal) begin
		if (rfs_cnt == 10'd449) begin
			rfs_cnt <= 0;
			if (!ref_fire && rfs_pending != 8'hff) rfs_pending <= rfs_pending + 1'd1;
		end else begin
			rfs_cnt <= rfs_cnt + 1'd1;
			if (ref_fire && rfs_pending != 0)      rfs_pending <= rfs_pending - 1'd1;
		end
	end
end

// ---- DDIO SDRAM_CLK (180 deg from clk), from Sorgelig -----------------------
altddio_out
#(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
	.invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
);

endmodule
