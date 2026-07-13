`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 09/23/2025 10:23:17 PM
// Design Name: 74LS323 Universal 8-Bit Shift Register
// Module Name: LS323_shiftreg
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


module LS323_shiftreg(
    input logic clk,
    input logic clk_en,
    input logic _CLR,
    input logic _OE1,
    input logic _OE2,
    input logic S0,
    input logic S1,
    input logic SR,
    input logic SL, 
    input logic [7:0] D,
    output wire [7:0] Q,
    output logic QA,
    output logic QH
    );

    // The LS323 is an 8-bit shift register that can be parallel loaded, shifted left, or shifted right
    // And cleared of course
    // It also has two OE pins, which need to be low to enable the outputs, but the chip internals still work if they're high
    // S0 and S1 select the mode of operation
    // QA and QH are just the most and least significant bits of the register; they aren't gated by the OE pins
    // SR is the serial input for shifting right, SL is the serial input for shifting left

    // Internal version of Q that's not gated by OE
    logic [7:0] Q_int;

    // Make sure that Q_int starts at 0 on power-up
    // This is really only necessary for simulation, just so that it doesn't start at X and propagate X's everywhere
    initial begin
        Q_int = 8'b0;
    end

    // On the rising edge of the clock, do whatever operation is selected by S0 and S1
    always_ff @(posedge clk) begin
        // But only do anything if clk_en (our clock gate) is high
        if (clk_en) begin
            // If _CLR is low, clear the register synchronously instead of doing anything else
            if (!_CLR) begin
                Q_int <= 8'b0;
            end else begin
                // Otherwise do one of the four following operatios:
                case ({S1, S0})
                    2'b00: Q_int <= Q_int; // Hold state
                    2'b01: Q_int <= {SR, Q_int[7:1]}; // Shift right, put SR into MSB
                    2'b10: Q_int <= {Q_int[6:0], SL}; // Shift left, put SL into LSB
                    2'b11: Q_int <= D; // Parallel load from D
                endcase
            end
        end
    end

    // Set Q to Q_int if both OE pins are low, otherwise high-z
    assign Q = (!_OE1 && !_OE2) ? Q_int : 8'bz;
    // And QA/QH are always just the MSB and LSB of Q_int regardless of OE, as I said earlier
    assign QA = Q_int[7];
    assign QH = Q_int[0];

endmodule