// ============================================================================
// Module: clock_gating_cell
// Description: Latch-based Integrated Clock Gating (ICG) cell
// Purpose: Eliminates dynamic power consumption (P = a * C * V^2 * f)
//          by halting clock propagation to inactive sub-modules.
// ============================================================================
`timescale 1ns / 1ps

module clock_gating_cell (
    input  wire clk_in,       // Master clock input
    input  wire enable,       // Gate enable control (active high)
    input  wire test_mode,    // Scan / bypass mode for DFT
    output wire clk_out       // Gated clock output to target block
);

    reg latch_en;

    // Negative-latch based gating prevents glitches and hazards on clk_out
    always @(clk_in or enable or test_mode) begin
        if (!clk_in) begin
            latch_en <= enable | test_mode;
        end
    end

    // Clock is only propagated when latch_en is HIGH
    assign clk_out = clk_in & latch_en;

endmodule
