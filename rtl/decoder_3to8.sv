`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/30/2025 01:46:13 PM
// Design Name: 
// Module Name: decoder_3to8
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


module decoder_3to8(
    input logic [2:0] ABC,
    input logic _G2A,
    input logic _G2B,
    input logic G1,
    output logic [7:0] _Y
    );

    always_comb begin
        if(!G1 || (_G2A || _G2B)) begin
            _Y = 8'b11111111; // All outputs high if decoder not selected
        end else begin
            case(ABC) // All possible input combinations
                3'b000: _Y = 8'b11111110;
                3'b001: _Y = 8'b11111101;
                3'b010: _Y = 8'b11111011;
                3'b011: _Y = 8'b11110111;
                3'b100: _Y = 8'b11101111;
                3'b101: _Y = 8'b11011111;
                3'b110: _Y = 8'b10111111;
                3'b111: _Y = 8'b01111111;
                default: _Y = 8'b11111111; // Default case, should never happen
            endcase
        end
    end

endmodule
