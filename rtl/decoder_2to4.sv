`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/30/2025 01:45:35 PM
// Design Name: 
// Module Name: decoder_2to4
// Project Name: 
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


module decoder_2to4(
    input logic [1:0] AB,
    input logic _G,
    output logic [3:0] _Y
    );

    always_comb begin
        if(_G) begin
            _Y = 4'b1111; // All outputs high if decoder not selected
        end else begin
            case(AB) // All possible input combinations
                2'b00: _Y = 4'b1110;
                2'b01: _Y = 4'b1101;
                2'b10: _Y = 4'b1011;
                2'b11: _Y = 4'b0111;
                default: _Y = 4'b1111; // Default case, should never happen
            endcase
        end
    end

endmodule
