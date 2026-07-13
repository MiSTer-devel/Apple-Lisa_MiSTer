`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/30/2025 11:59:58 AM
// Design Name: 4164 64K x 1 Bit DRAM Chip
// Module Name: RAM_4164
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

// 4164 is a 64K x 1 bit DRAM chip
// Addressing is done in two steps, first the row address is latched on the falling
// edge of RAS, then the column address is latched on the falling edge of CAS
// If WE is high when CAS falls, it's a read cycle, otherwise it's a write cycle
// If WE falls while CAS is already low, it's a late write cycle to the last addressed
// location (using the previously latched row and column addresses)
// There's no CE signal; the output is enabled when RAS and CAS are both low and WE is high

module RAM_4164(
    input logic clk,
    input logic [15:0] A,
    input logic _CS,
    input logic _WE,
    input logic D,
    output logic Q
    );

    `ifdef SIMULATION
        (* ram_style = "block" *) logic [0:0] RAM_array [0:65535]= '{default:1'b0};
    `else 
        (* ram_style = "block" *) logic [0:0] RAM_array [0:65535];
    `endif

    always_ff @(posedge clk) begin
        if (!_WE && !_CS) begin
            RAM_array[A] <= D;
        end else begin
            Q <= RAM_array[A];
        end
    end

endmodule