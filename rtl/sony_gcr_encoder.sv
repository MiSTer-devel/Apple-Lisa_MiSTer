/*
 sony_gcr_encoder.sv

 On-the-fly 6-and-2 GCR track encoder for the Apple Sony 3.5" 400K drive.

 Ported from MacPlus_MiSTer/rtl/floppy_track_encoder.v (refs/MacPlus_MiSTer).
 Only cosmetic changes for M0: module renamed so it can live alongside the
 Lisa core and be adapted for Lisa 524-byte (12-tag + 512-data) sectors in a
 later milestone (M4). The GCR nibbler, sync/address/data-field structure, the
 Sony byte table and the per-zone sector counts are unchanged from the proven
 MacPlus implementation.

 M4 TODO (see plan): widen the data field from 512 -> 524 bytes so the 12 Lisa
 tag bytes are encoded ahead of the 512 data bytes (Lisa REQUIRES real tags),
 extend the STATE_DATA terminal count 683 -> 699 and the 683-4 strobe guards,
 and re-base `addr` onto the per-track buffer (sector*524 + src index).

 encode a full floppy track from raw sector data on the fly
 */

/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off CASEINCOMPLETE */

module sony_gcr_encoder (
   // system signals
   input 			clk, // clock at which data bytes are delivered via odata
   input				ready,
   input 			rst,

   input 			side,
   input 			sides,
   input [6:0] 	track, // current track

   // Source byte selectors -> sony_drive maps these to the per-track buffer.
   // src_offset runs 0..523 within a 524-byte Lisa sector: 0..11 = tags,
   // 12..523 = data. (The MacPlus reference emitted a whole-image byte address;
   // here sony_drive owns the buffer layout so it can place tags + data.)
   output [3:0] 	o_sector,
   output [9:0] 	o_srcoff,
   input [7:0] 	idata,

   output [7:0] 	odata,
   output       	o_sync      // 1 while emitting a self-sync (0xFF) byte -> 10 cells
);

   assign o_sector = sector;
   assign o_srcoff = src_offset;
   assign o_sync   = (state == STATE_SYN0) || (state == STATE_SYN1);

   // number of sectors on current track
   wire [3:0] spt =
	      (track[6:4] == 3'd0)?4'd12: // track  0 - 15
	      (track[6:4] == 3'd1)?4'd11: // track 16 - 31
	      (track[6:4] == 3'd2)?4'd10: // track 32 - 47
	      (track[6:4] == 3'd3)?4'd9:  // track 48 - 63
	      4'd8;                       // track 64 - ...

   // (soff/track-offset math removed: sony_drive now owns the per-track buffer
   //  addressing via o_sector/o_srcoff, so the encoder no longer computes a
   //  whole-image address. spt is still used for the sector interleave below.)

   // parts of an address block
   wire [5:0] sec_in_tr = {2'b00, sector};
   wire [5:0] track_low = track[5:0];
   wire [5:0] track_hi = { side, 4'b0000, track[6] };
   wire [5:0] format = { sides, 5'h2 };          // double sided = 22, single sided = 2
   wire [5:0] checksum = track_low ^ sec_in_tr ^ track_hi ^ format;

   // data input to the sony encoder during address block
   wire [5:0] sony_addr_in =
	      (count == 3)?track_low:
	      (count == 4)?sec_in_tr:
	      (count == 5)?track_hi:
	      (count == 6)?format:
	      checksum;

   // data input to the sony encoder during data header
   wire [5:0] sony_dhdr_in = sec_in_tr;

   wire [5:0] sony_dsum_in =
	      (count == 0)?{ c3[7:6], c2[7:6], c1[7:6] }:
	      (count == 1)?c3[5:0]:
	      (count == 2)?c2[5:0]:
	      c1[5:0];

   // feed data into sony encoder
   wire [5:0] si =
	      (state == STATE_ADDR)?sony_addr_in:
	      (state == STATE_DHDR)?sony_dhdr_in:
	      (state == STATE_DZRO)?nib_out:
	      (state == STATE_DPRE)?nib_out:
	      (state == STATE_DATA)?nib_out:
	      (state == STATE_DSUM)?sony_dsum_in:
	      6'h3f;

   // encoder table taken from MESS emulator
   wire [7:0] sony_to_disk_byte =
	      (si==6'h00)?8'h96:(si==6'h01)?8'h97:(si==6'h02)?8'h9a:(si==6'h03)?8'h9b: // 0x00
	      (si==6'h04)?8'h9d:(si==6'h05)?8'h9e:(si==6'h06)?8'h9f:(si==6'h07)?8'ha6:
	      (si==6'h08)?8'ha7:(si==6'h09)?8'hab:(si==6'h0a)?8'hac:(si==6'h0b)?8'had:
	      (si==6'h0c)?8'hae:(si==6'h0d)?8'haf:(si==6'h0e)?8'hb2:(si==6'h0f)?8'hb3:

	      (si==6'h10)?8'hb4:(si==6'h11)?8'hb5:(si==6'h12)?8'hb6:(si==6'h13)?8'hb7: // 0x10
	      (si==6'h14)?8'hb9:(si==6'h15)?8'hba:(si==6'h16)?8'hbb:(si==6'h17)?8'hbc:
	      (si==6'h18)?8'hbd:(si==6'h19)?8'hbe:(si==6'h1a)?8'hbf:(si==6'h1b)?8'hcb:
	      (si==6'h1c)?8'hcd:(si==6'h1d)?8'hce:(si==6'h1e)?8'hcf:(si==6'h1f)?8'hd3:

	      (si==6'h20)?8'hd6:(si==6'h21)?8'hd7:(si==6'h22)?8'hd9:(si==6'h23)?8'hda: // 0x20
	      (si==6'h24)?8'hdb:(si==6'h25)?8'hdc:(si==6'h26)?8'hdd:(si==6'h27)?8'hde:
	      (si==6'h28)?8'hdf:(si==6'h29)?8'he5:(si==6'h2a)?8'he6:(si==6'h2b)?8'he7:
	      (si==6'h2c)?8'he9:(si==6'h2d)?8'hea:(si==6'h2e)?8'heb:(si==6'h2f)?8'hec:

	      (si==6'h30)?8'hed:(si==6'h31)?8'hee:(si==6'h32)?8'hef:(si==6'h33)?8'hf2: // 0x30
	      (si==6'h34)?8'hf3:(si==6'h35)?8'hf4:(si==6'h36)?8'hf5:(si==6'h37)?8'hf6:
	      (si==6'h38)?8'hf7:(si==6'h39)?8'hf9:(si==6'h3a)?8'hfa:(si==6'h3b)?8'hfb:
	      (si==6'h3c)?8'hfc:(si==6'h3d)?8'hfd:(si==6'h3e)?8'hfe:            8'hff;

   // states of encoder state machine
   localparam STATE_SYN0 = 4'd0;      // 56 bytes sync pattern (0xff)
   localparam STATE_ADDR = 4'd1;      // 10 bytes address block
   localparam STATE_SYN1 = 4'd2;      // 5 bytes sync pattern (0xff)
   localparam STATE_DHDR = 4'd3;      // 4 bytes data block header
   localparam STATE_DZRO = 4'd4;      // 8 encoded zero bytes in data block
   localparam STATE_DPRE = 4'd5;      // 4 bytes data prefetch
   localparam STATE_DATA = 4'd6;      // the payload itself
   localparam STATE_DSUM = 4'd7;      // 4 bytes data checksum
   localparam STATE_DTRL = 4'd8;      // 3 bytes data block trailer
   localparam STATE_WAIT = 4'd15;     // wait until start of next sector

   // output data during address block
   wire [7:0] odata_addr =
	      (count == 0)?8'hd5:
	      (count == 1)?8'haa:
	      (count == 2)?8'h96:
	      (count == 8)?8'hde:
	      (count == 9)?8'haa:
	      sony_to_disk_byte;

   wire [7:0] odata_dhdr =
	      (count == 0)?8'hd5:
	      (count == 1)?8'haa:
	      (count == 2)?8'had:
	      sony_to_disk_byte;

   wire [7:0] odata_dtrl =
	      (count == 0)?8'hde:
	      (count == 1)?8'haa:
	      8'hff;

   // demultiplex output data
   assign odata = (state == STATE_ADDR)?odata_addr:
		  (state == STATE_DHDR)?odata_dhdr:
		  (state == STATE_DZRO)?sony_to_disk_byte:
		  (state == STATE_DPRE)?sony_to_disk_byte:
		  (state == STATE_DATA)?sony_to_disk_byte:
		  (state == STATE_DSUM)?sony_to_disk_byte:
		  (state == STATE_DTRL)?odata_dtrl:
		  8'hff;

   // ------------------------ nibbler ----------------------------

   reg [7:0]  c1;
   reg [7:0]  c2;
   reg 	      c2x;
   reg [7:0]  c3;
   reg 	      c3x;

   wire       nibbler_reset = (state == STATE_DHDR);
   reg [1:0]  cnt;

   reg [7:0] nib_xor_0;
   reg [7:0] nib_xor_1;
   reg [7:0] nib_xor_2;

   // request an input byte. this happens 4 byte ahead of output.
   // only three bytes are read while four bytes are written due
   // to 6:2 encoding
   // Lisa: 524-byte payload (12 tags + 512 data) -> 699 GCR data bytes.
   wire strobe = ((state == STATE_DPRE) ||
		    ((state == STATE_DATA) && (count < 699-4-1)))
					&& (cnt != 3);

reg [7:0] data_latch;
always @(posedge clk) if(ready && strobe) data_latch <= idata;

always @(posedge clk or posedge nibbler_reset) begin
   if(nibbler_reset) begin
		c1 <= 8'h00;
		c2 <= 8'h00;
		c2x <= 1'b0;
		c3 <= 8'h00;
		c3x <= 1'b0;
		cnt <= 2'd0;
		nib_xor_0 <= 8'h00;
		nib_xor_1 <= 8'h00;
		nib_xor_2 <= 8'h00;
   end else if(ready && ((state == STATE_DPRE) || (state == STATE_DATA))) begin
		cnt <= cnt + 2'd1;

		// memory read during cnt 0-3
		if(count < 699-4) begin

			// encode first byte
			if(cnt == 1) begin
				c1 <= { c1[6:0], c1[7] };
				{ c3x, c3 } <= { 1'b0, c3 } + { 1'b0, nib_in } + { 8'd0, c1[7] };
				nib_xor_0 <= nib_in ^ { c1[6:0], c1[7] };
			end

			// encode second byte
			if(cnt == 2) begin
				{ c2x, c2 } <= { 1'b0, c2 } + { 1'b0, nib_in } + { 8'd0, c3x };
				c3x <= 1'b0;
				nib_xor_1 <= nib_in ^ c3;
			end

			// encode third byte
			if(cnt == 3) begin
				c1 <= c1 + nib_in + { 7'd0, c2x };
				c2x <= 1'b0;
				nib_xor_2 <= nib_in ^ c2;
			end
		end else begin
			// since there are 512/3 = 170 2/3 three byte blocks in a sector the
			// last run has to be filled up with zeros
			if(cnt == 3)
				nib_xor_2 <= 8'h00;
		end
	end
end

// bytes going into the nibbler
wire [7:0] nib_in =
			(state == STATE_DZRO)?8'h00:
			data_latch;

// four six bit units come out of the nibbler
wire [5:0] nib_out =
			(cnt == 1)?nib_xor_0[5:0]:
	      (cnt == 2)?nib_xor_1[5:0]:
	      (cnt == 3)?nib_xor_2[5:0]:
	      { nib_xor_0[7:6], nib_xor_1[7:6], nib_xor_2[7:6] };

// count bytes per sector
reg [3:0]  state;
reg [9:0]  count;
reg [3:0]  sector;
reg [9:0] src_offset;
always @(posedge clk or posedge rst) begin
	if(rst) begin
		count <= 10'd0;
		state <= STATE_SYN0;
		sector <= 4'd0;
	   src_offset <= 10'd0;
	end else if(ready) begin
		count <= count + 10'd1;

	   if(strobe)
			src_offset <= src_offset + 10'd1;

		case(state)

			// send 14*4=56 sync bytes
			STATE_SYN0: begin
				if(count == 55) begin
					state <= STATE_ADDR;
					count <= 10'd0;
				end
			end

			// send 10 bytes address block
			STATE_ADDR: begin
				if(count == 9) begin
					state <= STATE_SYN1;
					count <= 10'd0;
				end
			end

			// send 5 sync bytes
			STATE_SYN1: begin
				if(count == 4) begin
					state <= STATE_DHDR;
					count <= 10'd0;
				end
			end

   	   // send 4 bytes data block hdr
			STATE_DHDR: begin
				if(count == 3) begin
					state <= STATE_DPRE;   // Lisa: no 0x96 preamble; tags are in the 524B payload
					count <= 10'd0;
				end
			end

      	// send 8 zero bytes before data block
			STATE_DZRO: begin
				if(count == 11) begin
					state <= STATE_DPRE;
					count <= 10'd0;
				end
			end

       	// start prefetching 4 bytes data
			STATE_DPRE: begin
				if(count == 3) begin
					state <= STATE_DATA;
					count <= 10'd0;
				end
			end

      	// send 512 bytes data block 6:2 encoded in 683 bytes
			STATE_DATA: begin
				if(count == 698) begin
					state <= STATE_DSUM;
					count <= 10'd0;
				end
			end

       	// send 4 bytes data checksum
			STATE_DSUM: begin
				if(count == 3) begin
					state <= STATE_DTRL;
					count <= 10'd0;
				end
			end

       	// send 3 bytes data block trailer
			STATE_DTRL: begin
				if(count == 2) begin
					state <= STATE_WAIT;
					count <= 10'd0;
				end
			end

			// fill sector up to 1024 bytes
			STATE_WAIT: begin
				begin
					count <= 10'd0;
					state <= STATE_SYN0;
				   src_offset <= 10'd0;

					// interleave of 2
					if((sector == spt-4'd2) ||
						(sector == spt-4'd1))   sector <= { 3'd0, !sector[0] };
					else						      sector <= sector + 4'd2;
				end
			end
		endcase
   end
end

endmodule
