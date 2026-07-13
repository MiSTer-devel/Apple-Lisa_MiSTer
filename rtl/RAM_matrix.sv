`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: N/A
// Engineer: AlexTheCat123
// 
// Create Date: 08/30/2025 08:54:08 PM
// Design Name: Lisa Memory Board RAM Matrix (256K x 8 Bit)
// Module Name: RAM_matrix
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

`define RAM_256K // Comment this out to make the RAM board 512K instead of 256K

module RAM_matrix(
    input logic clk,
    input logic [7:0] A,
    input logic [7:0] MD,
    input logic PI,
    input logic R_W,
    input logic [3:0] _CAS,
    input logic [3:0] _RAS,
    output logic [7:0] DO,
    output logic PO
    );

    logic [7:0] row_addr; // Latched row address (from A0-A7)
    logic [7:0] col_addr; // Latched column address (from A0-A7)

    // The sim toolchain rejects an edge on a reduction expression directly;
    // name the reduced nets so the @(negedge ...) has a simple signal to
    // sensitize on. Quartus is happy with these intermediate wires too.
    wire all_ras = &_RAS;
    wire all_cas = &_CAS;

    always_ff @(negedge all_ras) begin
        row_addr <= A;
    end

    // Latch the column address on the falling edge of _CAS (if RAS is already active)
    always_ff @(negedge all_cas) begin
        if (!_RAS[0] | !_RAS[1] | !_RAS[2] | !_RAS[3]) // Only latch if RAS is already low
            col_addr <= A;
    end

    logic [3:0] _CS;
    always_ff @(posedge clk) begin
        _CS <= _RAS | _CAS; // Chip is selected when both RAS and CAS are low
    end

    logic [7:0] Q0, Q1, Q2, Q3; // Outputs from each bank
    logic PQ0, PQ1, PQ2, PQ3; // Parity outputs from each bank

    initial begin
        DO = 8'b0;
        PO = 1'b0;
        `ifdef RAM_256K
            Q2 = 8'b0;
            PQ2 = 1'b0;
            Q3 = 8'b0;
            PQ3 = 1'b0;
        `endif
    end

    //logic _total_CS;
    //assign _total_CS = _CS[0] & _CS[1] & _CS[2] & _CS[3];

    always_ff @(negedge clk) begin
        if (!_CS[0]) begin
            DO <= Q0;
            PO <= PQ0;
        end else if (!_CS[1]) begin
            DO <= Q1;
            PO <= PQ1;
        end else if (!_CS[2]) begin
            DO <= Q2;
            PO <= PQ2;
        end else if (!_CS[3]) begin
            DO <= Q3;
            PO <= PQ3;
        end
    end

    // Instantiate the first bank of RAM (8 bits plus parity)
    RAM_4164 R0B0(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[0]), .Q(Q0[0]));
    RAM_4164 R0B1(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[1]), .Q(Q0[1]));
    RAM_4164 R0B2(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[2]), .Q(Q0[2]));
    RAM_4164 R0B3(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[3]), .Q(Q0[3]));
    RAM_4164 R0B4(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[4]), .Q(Q0[4]));
    RAM_4164 R0B5(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[5]), .Q(Q0[5]));
    RAM_4164 R0B6(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[6]), .Q(Q0[6]));
    RAM_4164 R0B7(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(MD[7]), .Q(Q0[7]));
    RAM_4164 R0BP(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[0]), ._WE(R_W), .D(PI), .Q(PQ0));

    // As well as the other three banks
    // They're all very similar, just using different CS and Q signals
    RAM_4164 R1B0(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[0]), .Q(Q1[0]));
    RAM_4164 R1B1(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[1]), .Q(Q1[1]));
    RAM_4164 R1B2(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[2]), .Q(Q1[2]));
    RAM_4164 R1B3(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[3]), .Q(Q1[3]));
    RAM_4164 R1B4(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[4]), .Q(Q1[4]));
    RAM_4164 R1B5(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[5]), .Q(Q1[5]));
    RAM_4164 R1B6(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[6]), .Q(Q1[6]));
    RAM_4164 R1B7(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(MD[7]), .Q(Q1[7]));
    RAM_4164 R1BP(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[1]), ._WE(R_W), .D(PI), .Q(PQ1));

    `ifndef RAM_256K
        RAM_4164 R2B0(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[0]), .Q(Q2[0]));
        RAM_4164 R2B1(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[1]), .Q(Q2[1]));
        RAM_4164 R2B2(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[2]), .Q(Q2[2]));
        RAM_4164 R2B3(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[3]), .Q(Q2[3]));
        RAM_4164 R2B4(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[4]), .Q(Q2[4]));
        RAM_4164 R2B5(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[5]), .Q(Q2[5]));
        RAM_4164 R2B6(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[6]), .Q(Q2[6]));
        RAM_4164 R2B7(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(MD[7]), .Q(Q2[7]));
        RAM_4164 R2BP(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[2]), ._WE(R_W), .D(PI), .Q(PQ2));

        RAM_4164 R3B0(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[0]), .Q(Q3[0]));
        RAM_4164 R3B1(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[1]), .Q(Q3[1]));
        RAM_4164 R3B2(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[2]), .Q(Q3[2]));
        RAM_4164 R3B3(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[3]), .Q(Q3[3]));
        RAM_4164 R3B4(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[4]), .Q(Q3[4]));
        RAM_4164 R3B5(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[5]), .Q(Q3[5]));
        RAM_4164 R3B6(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[6]), .Q(Q3[6]));
        RAM_4164 R3B7(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(MD[7]), .Q(Q3[7]));
        RAM_4164 R3BP(.clk(clk), .A({row_addr, col_addr}), ._CS(_CS[3]), ._WE(R_W), .D(PI), .Q(PQ3));
    `endif

endmodule
