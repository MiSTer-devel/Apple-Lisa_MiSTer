// pll.sv
// The single PLL for the Apple Lisa core on MiSTer.
// It produces only the 81.50016 MHz master clock (and its phase-shifted twin for
// the SDRAM). Every other Lisa clock (DOTCK, C16M, C5M, SCCCK, COPCK, usbclk) is
// derived from this master by division in clock_divider / dotck_mmcm, so the core
// uses exactly ONE fractional PLL. See todo.md for the follow-up work.

`timescale 1 ps / 1 ps

module pll (
    input  wire  refclk,   // 50 MHz reference input
    input  wire  rst,      // Active-high reset
    output wire  outclk_0, // 81.50016 MHz (system / master clock)
    output wire  outclk_1, // 81.50016 MHz (SDRAM clock, phase shifted)
    output wire  locked    // PLL locked signal
);

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("81.50016 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("81.50016 MHz"),
        .phase_shift1("9816 ps"), // ~-2.5ns SDRAM phase shift, snapped to legal 307ps grid step (9816 ps = -2454 ps)
        .duty_cycle1(50)
    ) altera_pll_i (
        .refclk(refclk),
        .rst(rst),
        .outclk({outclk_1, outclk_0}),
        .locked(locked)
    );

endmodule
