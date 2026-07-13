`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/23/2025 05:39:45 PM
// Design Name: Apple Lisa I/O ROM (2732)
// Module Name: IOROM_2732
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


module IOROM_2732 #(parameter ROM_file="ROM.mem") ( 
    input logic [11:0] A,
    input logic _OE,
    input logic _CE,
    output wire [7:0] D
    );

    // This is literally just a 2732 ROM (4K x 8 bit)

    // The 4K x 8 bit ROM array
    logic [7:0] ROM_array [4096];

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
    // And make _EN the OR of the two enable signals so that it's only true (active low) if both _OE and _CE are true
    assign _EN = _OE | _CE;

    // Finally, make the data output the same as D_int is the chip is enabled, and high-z if it's not enabled
    assign D = _EN ? 8'bz : D_int;

endmodule