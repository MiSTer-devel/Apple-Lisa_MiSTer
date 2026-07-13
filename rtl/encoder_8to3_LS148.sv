`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/31/2025 06:12:38 PM
// Design Name: 74LS148 8-to-3 Encoder
// Module Name: encoder_8to3_LS148
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


module encoder_8to3_LS148(
    input logic [7:0] _D,
    input logic _EI,
    output logic [2:0] _Q
    );

    // Internal signal to hold the output before we take OE into account
    logic [2:0] Q_int;

    // For ease-of-understanding, convert the active-low inputs to active-high inputs
    logic [7:0] D;
    assign D = ~_D;

    // Forward the internal output signals through to the real outputs if _EI (the OE) is low, else set the outputs to all 1's
    // Don't forget to invert our internal active-high outputs to active-low outputs for the real outputs
    assign _Q = _EI ? 3'b111 : ~Q_int;

    always_comb begin
        // Now implement the priority encoder; it's just a bunch of if's
        // Apparently SystemVerilog has this cool "priority if" construct to make sure the synthesizer infers the right thing
        // It would very likely work fine without it though
        if (D[7]) begin
            Q_int = 3'd7;
        end else if (D[6]) begin
            Q_int = 3'd6;
        end else if (D[5]) begin
            Q_int = 3'd5;
        end else if (D[4]) begin
            Q_int = 3'd4;
        end else if (D[3]) begin
            Q_int = 3'd3;
        end else if (D[2]) begin
            Q_int = 3'd2;
        end else if (D[1]) begin
            Q_int = 3'd1;
        end else if (D[0]) begin
            Q_int = 3'd0;
        end else begin
            Q_int = 3'd0;
        end
    end

endmodule
