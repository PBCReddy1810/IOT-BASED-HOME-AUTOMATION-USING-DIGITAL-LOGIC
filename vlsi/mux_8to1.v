// ============================================================================
// Module: mux_8to1
// Description: 8-to-1 Digital Multiplexer (74HC151 functional equivalent)
// Purpose: Aggregates 8 digital sensor status lines into 1 serial data pin
//          to the microcontroller, dynamically scanned via 3 address lines.
// ============================================================================
`timescale 1ns / 1ps

module mux_8to1 (
    input  wire       en_n,       // Active-Low Strobe / Enable
    input  wire [7:0] data_in,    // 8 digital sensor data lines
    input  wire [2:0] sel,        // 3-bit Channel Select
    output reg        mux_out,    // Selected digital output
    output wire       mux_out_n   // Inverted output
);

    always @(*) begin
        if (en_n) begin
            mux_out = 1'b0;
        end else begin
            case (sel)
                3'b000: mux_out = data_in[0];
                3'b001: mux_out = data_in[1];
                3'b010: mux_out = data_in[2];
                3'b011: mux_out = data_in[3];
                3'b100: mux_out = data_in[4];
                3'b101: mux_out = data_in[5];
                3'b110: mux_out = data_in[6];
                3'b111: mux_out = data_in[7];
                default: mux_out = 1'b0;
            endcase
        end
    end

    assign mux_out_n = ~mux_out;

endmodule
