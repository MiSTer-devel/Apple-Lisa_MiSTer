// debug_issp.sv
// TEMPORARY bring-up instrumentation. Exposes core liveness over JTAG via the
// In-System Sources & Probes IP (read with quartus_stp), and lets us override
// the DOTCK speed-select and force the core "on" live, so hypotheses can be
// tested without recompiling. Remove once bring-up is done (see todo.md).
//
// PROBE (32-bit, read-only) layout:
//   [31:24] vsync_cnt   - increments on each _VSYNC falling edge (frame counter)
//   [23:16] hsync_cnt   - increments on each _HSYNC falling edge (line counter, low bits)
//   [15:8]  dotck_div   - high bits of a free counter clocked by dotck_en (rate proxy)
//   [7]     pll_locked
//   [6]     core_on     (ON from the COP)
//   [5]     core_on_sync
//   [4]     reset_n     (_RESET)
//   [3]     speed_override_en (echo of source)
//   [2]     force_on          (echo of source)
//   [1:0]   speed_override    (echo of source)
//
// SOURCE (8-bit, writable) layout:
//   [1:0] speed_override     - value forced onto SPEED_SEL when [2] is set
//   [2]   speed_override_en  - 1 = use speed_override instead of the OSD SPEED_SEL
//   [3]   force_on           - 1 = force the core enables on (bypass ON gating)

`timescale 1 ps / 1 ps

module debug_issp (
    input  wire        clk_sys,
    input  wire        pll_locked,
    input  wire        vsync_n,      // _VSYNC (active low)
    input  wire        hsync_n,      // _HSYNC (active low)
    input  wire        dotck_en,
    input  wire        core_on,      // ON
    input  wire        core_on_sync, // ON_sync
    input  wire        reset_n,      // _RESET
    output wire [1:0]  speed_override,
    output wire        speed_override_en,
    output wire        force_on
);

    reg [7:0]  vsync_cnt = 8'd0;
    reg [7:0]  hsync_cnt = 8'd0;
    reg [21:0] dotck_free = 22'd0;
    reg        vs_d = 1'b1, hs_d = 1'b1;

    always @(posedge clk_sys) begin
        vs_d <= vsync_n;
        hs_d <= hsync_n;
        if (vs_d && !vsync_n) vsync_cnt <= vsync_cnt + 8'd1;
        if (hs_d && !hsync_n) hsync_cnt <= hsync_cnt + 8'd1;
        if (dotck_en)         dotck_free <= dotck_free + 22'd1;
    end

    wire [7:0] src;
    assign speed_override    = src[1:0];
    assign speed_override_en = src[2];
    assign force_on          = src[3];

    wire [31:0] probe = { vsync_cnt, hsync_cnt, dotck_free[21:14],
                          pll_locked, core_on, core_on_sync, reset_n,
                          speed_override_en, force_on, speed_override };

    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("LDBG"),
        .probe_width             (32),
        .source_width            (8),
        .source_initial_value    ("0"),
        .enable_metastability    ("NO")
    ) u_issp (
        .source     (src),
        .probe      (probe),
        .source_clk (clk_sys),
        .source_ena (1'b1)
    );

endmodule
