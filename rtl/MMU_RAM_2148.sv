`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/01/2025 05:16:49 PM
// Design Name: Lisa 2148 MMU RAM Chip
// Module Name: MMU_RAM_2148
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


module MMU_RAM_2148(
    input logic clk,
    input logic [9:0] A_MMU,
    input logic _CS,
    input logic _WE,
    input logic [3:0] D_in,
    output logic [3:0] D_out
    );

    // The RAM array itself; 1024 x 4 Bits
    // Must be filled with 1s on startup or else the Lisa will hang when accessing the MMU regs
    logic [3:0] RAM_array [0:1023] = '{default:4'b1111};

    // If the chip is selected and it's not a write, then forward the data on to the output, else set it to all 1's
    // Really we should set it to high-z, but the Lisa expects a pull-up to 1's when the chip isn't selected
    // And a tri1 signal doesn't work here on the actual hardware for some reason
    assign D_out = (!_CS & _WE) ? RAM_array[A_MMU] : 4'b1111;

    always_ff @(posedge clk) begin
        // If the chip is selected and it is a write, then read the 4 bits off the data bus and save them into the RAM array
        if (!_CS & !_WE) begin
            RAM_array[A_MMU] <= D_in;
        end
    end

endmodule
