`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/31/2025 03:22:25 PM
// Design Name: Apple Lisa 2764 Boot ROM
// Module Name: bootrom_2764
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


module bootrom_2764 #(parameter ROM_file="ROM.mem") (
    input logic [12:0] A,
    input logic _OE,
    input logic _CE,
    output wire [7:0] D
    );

    // The 64K x 1 bit (so 8K x 8 bit) ROM array
    logic [7:0] ROM_array [8192];

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
