`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/31/2025 03:22:49 PM
// Design Name: Apple Lisa Video State Machine PROM
// Module Name: VSROM
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


module PROM_6309 #(parameter ROM_file="ROM.mem") (
    input logic [7:0] A,
    input logic _E1,
    input logic _E2,
    output wire [7:0] D
    );

    // The 256 x 8 bit ROM array
    logic [7:0] ROM_array [256];

    // Before synthesis, put the proper data into the ROM array
    initial begin
        $readmemh(ROM_file, ROM_array);
    end

    // An internal data bus whose output is always enabled
    logic [7:0] D_int;
    // An internal enable signal
    logic _EN;

    // Always make D_int the data at the current ROM address
    assign D_int = ROM_array[A];
    // And make _EN the OR of the two enable signals so that it's only true (active low) if both _E1 and _E2 are true
    assign _EN = _E1 | _E2;

    // Finally, make the data output the same as D_int is the chip is enabled, and high-z if it's not enabled
    assign D = _EN ? 8'bz : D_int;

endmodule