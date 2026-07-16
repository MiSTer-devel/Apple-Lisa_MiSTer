`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/23/2025 05:41:58 PM
// Design Name: Apple Lisa Floppy Controller RAM (444C-3)
// Module Name: IO_RAM_444C_3
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


module IO_RAM_444C_3(
    input logic [9:0] A,
    input logic spoof_88,
    input logic _CS,
    input logic R_W,
    input logic [3:0] D_in,
    output wire [3:0] D_out,
    // DEBUG (ISSP "LFDR", remove for release): async read port so the shared
    // 6504<->68000 FDC RAM can be dumped over JTAG. Read-only; cannot disturb
    // the real ports.
    input  logic [9:0] dbg_A,
    output logic [3:0] dbg_D
    );

    // The RAM array itself; 1024 x 4 Bits
    `ifdef SIMULATION
        logic [3:0] RAM_array [0:1023] = '{default:4'b0000};
    `else
        logic [3:0] RAM_array [0:1023];
    `endif

    // DEBUG (ISSP "LFDR", remove for release): JTAG dump read port.
    assign dbg_D = RAM_array[dbg_A];

    logic [3:0] D_out_int;
    assign D_out = (!_CS && R_W) ? D_out_int : 4'bz;

    always_ff @(negedge _CS) begin
        // If the chip is selected and it's a read, then forward the data on to the output
        if (R_W) begin
            // If we're trying to access address 0x018 (FCC030), and spoof88 is set, then return 0x8 instead of the actual contents
            // This way, we can trick the Lisa into thinking this is a 2/10 by returning ROM revision 88 instead of A8 if the user wants
            if (A == 10'h018 && spoof_88) begin
                D_out_int <= 4'h8;
            end else begin
                // Otherwise, just return the actual contents of the RAM at the specified address
                D_out_int <= RAM_array[A];
            end
        // If the chip is selected and it's a write, then grab the 4 bits off the bus and write them to RAM
        end else begin
            RAM_array[A] <= D_in;
            D_out_int <= 4'h0; // Just to get everything off the bus and be safe
        end
    end

endmodule