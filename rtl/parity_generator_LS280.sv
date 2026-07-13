`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/30/2025 03:17:04 PM
// Design Name: 74LS280 Parity Generator/Checker
// Module Name: parity_generator_LS280
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


module parity_generator_LS280(
    input logic [8:0] ABCDEFGHI,
    output logic EVEN,
    output logic ODD
    );

    assign ODD = ~(ABCDEFGHI[0] ^ ABCDEFGHI[1] ^ ABCDEFGHI[2] ^ ABCDEFGHI[3] ^ ABCDEFGHI[4] ^ ABCDEFGHI[5] ^ ABCDEFGHI[6] ^ ABCDEFGHI[7] ^ ABCDEFGHI[8]);
    assign EVEN = ~ODD;

endmodule
