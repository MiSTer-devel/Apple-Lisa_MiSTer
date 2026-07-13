// dotck_mmcm.v
// Generates the selectable Lisa dot clocks by dividing the 81.50016 MHz master
// clock (clk_sys) instead of using a dedicated PLL. The dot-clock speeds are
// exact sub-multiples of the master:
//     dotck_80M = 81.50016 MHz  = clk_sys / 1
//     dotck_40M = 40.75008 MHz  = clk_sys / 2
//     dotck_20M = 20.37504 MHz  = clk_sys / 4
// dotck_60M (61.12512 MHz = clk_sys * 3/4) is NOT an integer divide, so it is
// aliased to dotck_40M for now. Proper 60 MHz turbo needs the single-clock +
// clock-enable rewrite. See todo.md.

`timescale 1 ps / 1 ps

module dotck_mmcm (
    input  wire  clk_sys,    // 81.50016 MHz master clock
    output wire  dotck_20M,  // 20.37504 MHz (clk_sys / 4)
    output wire  dotck_40M,  // 40.75008 MHz (clk_sys / 2)
    output wire  dotck_60M,  // 61.12512 MHz -- aliased to 40M (see header / todo.md)
    output wire  dotck_80M   // 81.50016 MHz (clk_sys)
);

    reg [1:0] div_cnt = 2'b00;
    always @(posedge clk_sys) begin
        div_cnt <= div_cnt + 2'b01;
    end

    assign dotck_40M = div_cnt[0]; // 81.5 / 2
    assign dotck_20M = div_cnt[1]; // 81.5 / 4
    assign dotck_80M = clk_sys;    // 81.5 / 1
    assign dotck_60M = div_cnt[0]; // TODO(todo.md): 60MHz turbo not achievable by integer divide; aliased to 40M

endmodule
