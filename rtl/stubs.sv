// Stubs for Xilinx primitives and Vivado-specific boards to enable compilation on MiSTer (Cyclone V)
// Since these modules/primitives are not used on MiSTer, they are stubbed out.

module BUFG (
    input  I,
    output O
);
    assign O = I;
endmodule

module HDMI_Interface (
    input sysclk,
    input _reset,
    input DOTCK,
    input framerate_sel,
    input VA_overflow,
    input _clr_vid_clk,
    input VID,
    input [5:0] CONT,
    input TONE,
    input [2:0] VC,
    input CPU_ROM_SEL,
    input blank_video,
    input scanlines,
    output tmds_clock,
    output [2:0] tmds
);
    assign tmds_clock = 1'b0;
    assign tmds = 3'b000;
endmodule

module usb_hid_host (
    input usbclk,
    input usbrst_n,
    output usb_dm,
    output usb_dp,
    input usb_dp_in,
    input usb_dm_in,
    output usb_oe,
    output [1:0] typ,
    output report,
    output [7:0] mouse_btn,
    output [7:0] mouse_dx,
    output [7:0] mouse_dy,
    output [7:0] key_modifiers,
    output [7:0] key1
);
    assign usb_dm = 1'b0;
    assign usb_dp = 1'b0;
    assign usb_oe = 1'b0;
    assign typ = 2'b00;
    assign report = 1'b0;
    assign mouse_btn = 8'b0;
    assign mouse_dx = 8'b0;
    assign mouse_dy = 8'b0;
    assign key_modifiers = 8'b0;
    assign key1 = 8'b0;
endmodule
