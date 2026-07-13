// -----------------------------------------------------------------------------
// Clean SystemVerilog reimplementation of the COP400 SIO unit.
//
// Faithful translation of rtl/t400_sio.vhd (Arnim Laeuger's T400 core). It
// REPLACES the GHDL-generated gate-level `t400_sio_0_0` inside t420_notri.v,
// whose combinational SO/SK output path (built from boolean-typed feedback
// signals) mis-evaluated under Verilator, leaving the COP's SK (keyboard
// reset) and SO (data-queued) outputs permanently idle in simulation while
// working fine on the FPGA. Rewriting the module in proper always_comb /
// always_ff removes that eval-order hazard.
//
// The module name and port list match the .v's `t400_sio_0_0` exactly so the
// core's `t400_sio_0_0 sio_b (...)` instantiation binds to this file, for BOTH
// Quartus and Verilator. Output type is "standard" (both VHDL generics =
// t400_opt_out_type_std_c), which reduces io_out_f/io_en_f to: out = value,
// enable = 1'b1.
//
// This is the first module of the eventual clean-SV COP conversion.
// -----------------------------------------------------------------------------

module t400_sio_0_0 (
    input        ck_i,
    input        ck_en_i,   // VHDL boolean
    input        por_i,     // VHDL boolean (async, active high)
    input        res_i,     // VHDL boolean (sync reset)
    input        phi1_i,
    input        out_en_i,  // VHDL boolean
    input        in_en_i,   // VHDL boolean
    input        op_i,      // sio_op_t: 1 = SIO_LOAD, 0 = SIO_NONE
    input        en0_i,
    input        en3_i,
    input  [3:0] a_i,
    input        c_i,
    input        si_i,
    output [3:0] sio_o,
    output       so_o,
    output       so_en_o,
    output       sk_o,
    output       sk_en_o
);

    // SI low-pass filter FSM states (VHDL si_flt_t)
    localparam logic [1:0] SI_LOW_0  = 2'd0,
                           SI_LOW_1  = 2'd1,
                           SI_HIGH_0 = 2'd2,
                           SI_HIGH_1 = 2'd3;

    logic       si_q;
    logic [1:0] si_flt_q, si_flt_s;
    logic       si_0_ok_q, si_1_ok_q, si_0_ok_s, si_1_ok_s;
    logic       dec_sio_s;
    logic [3:0] sio_q, new_sio_s;
    logic       skl_q, phi1_en_q;

    // -------------------------------------------------------------------------
    // Combinational: new SIO value (shift-register or counter mode).
    // Kept separate from the seq block so the transient new value reaches sio_o
    // when the core reads SIO (matches the VHDL new_sio process).
    // -------------------------------------------------------------------------
    always_comb begin
        new_sio_s = sio_q;                       // default: hold
        if (out_en_i) begin
            if (!en0_i)
                new_sio_s = {sio_q[2:0], si_q};  // shift-register mode
            else if (dec_sio_s)
                new_sio_s = sio_q - 4'd1;         // counter mode
        end
    end

    // -------------------------------------------------------------------------
    // Combinational: SI low-pass filter FSM (measures low/high durations and
    // asserts dec_sio_s when both were long enough).
    // -------------------------------------------------------------------------
    always_comb begin
        si_flt_s  = si_flt_q;
        si_0_ok_s = si_0_ok_q;
        si_1_ok_s = si_1_ok_q;
        dec_sio_s = 1'b0;

        unique case (si_flt_q)
            SI_LOW_0: si_flt_s = si_q ? SI_HIGH_0 : SI_LOW_1;

            SI_LOW_1: begin
                if (!si_q) begin
                    si_0_ok_s = 1'b1;                       // enough '0' on SI
                    if (!si_0_ok_q && si_1_ok_q)
                        dec_sio_s = 1'b1;                    // both phases long enough
                end else begin
                    si_flt_s  = SI_HIGH_0;
                    si_1_ok_s = 1'b0;                        // restart measuring
                end
            end

            SI_HIGH_0: begin
                si_1_ok_s = 1'b0;                            // restart marker
                si_flt_s  = si_q ? SI_HIGH_1 : SI_LOW_0;
            end

            SI_HIGH_1: begin
                if (si_q)
                    si_1_ok_s = 1'b1;                        // enough '1' on SI
                else begin
                    si_flt_s  = SI_LOW_0;
                    si_0_ok_s = 1'b0;                        // restart measuring
                end
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential elements.
    // -------------------------------------------------------------------------
    always_ff @(posedge ck_i or posedge por_i) begin
        if (por_i) begin
            sio_q     <= 4'd0;
            skl_q     <= 1'b1;
            phi1_en_q <= 1'b1;
            si_q      <= 1'b1;
            si_flt_q  <= SI_LOW_0;
            si_0_ok_q <= 1'b0;
            si_1_ok_q <= 1'b0;
        end else if (res_i) begin
            // synchronous reset upon external reset event
            skl_q     <= 1'b1;
            phi1_en_q <= 1'b1;
        end else begin
            if (in_en_i)  si_q <= si_i;            // sample async SI

            if (out_en_i) begin                    // SI filter registers
                si_flt_q  <= si_flt_s;
                si_0_ok_q <= si_0_ok_s;
                si_1_ok_q <= si_1_ok_s;
            end

            if (op_i && ck_en_i) begin             // SIO_LOAD: parallel update wins
                sio_q <= a_i;
                skl_q <= c_i;
            end else begin
                sio_q <= new_sio_s;
            end

            if (ck_en_i)                           // delay PHI1 enable one cycle
                phi1_en_q <= skl_q;                // (prevents glitches on sk_o)
        end
    end

    // -------------------------------------------------------------------------
    // Output mapping (standard output type -> *_en_o always 1).
    // -------------------------------------------------------------------------
    assign sio_o   = new_sio_s;
    assign so_o    = en3_i & (en0_i | sio_q[3]);
    assign so_en_o = 1'b1;
    assign sk_o    = phi1_en_q & (en0_i | phi1_i);
    assign sk_en_o = 1'b1;

endmodule
