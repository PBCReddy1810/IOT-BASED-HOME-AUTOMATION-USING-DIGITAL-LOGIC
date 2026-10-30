// ============================================================================
// Module: decoder_3to8
// Description: 3-to-8 Line Decoder / Demultiplexer (74HC138 functional model)
// Purpose: Enables the microcontroller to select 1-of-8 actuator channels
//          (Relay 1..8, Triac dimmer, Alarm Buzzer, Exhaust Fan) using only
//          3 GPIO address bits and an Enable strobe.
// ============================================================================
`timescale 1ns / 1ps

module decoder_3to8 (
    input  wire       en,            // Active-high Master Enable
    input  wire [2:0] addr,          // 3-bit channel address input
    output reg  [7:0] dec_out_high,  // Active-High decoded outputs (e.g., driver transistors)
    output wire [7:0] dec_out_low    // Active-Low decoded outputs (standard relay boards)
);

    always @(*) begin
        if (!en) begin
            dec_out_high = 8'b00000000;
        end else begin
            case (addr)
                3'b000: dec_out_high = 8'b00000001; // Channel 0: Living Room Main Lights
                3'b001: dec_out_high = 8'b00000010; // Channel 1: Ceiling Fan / HVAC
                3'b010: dec_out_high = 8'b00000100; // Channel 2: Kitchen Exhaust Fan
                3'b011: dec_out_high = 8'b00001000; // Channel 3: Emergency Siren / Buzzer
                3'b100: dec_out_high = 8'b00010000; // Channel 4: Bedroom Lights
                3'b101: dec_out_high = 8'b00100000; // Channel 5: Outdoor / Security Floodlights
                3'b110: dec_out_high = 8'b01000000; // Channel 6: Smart Door Solenoid Lock
                3'b111: dec_out_high = 8'b10000000; // Channel 7: Water Pump / Auxiliary Outlet
                default: dec_out_high = 8'b00000000;
            endcase
        end
    end

    // Active-Low outputs for standard optocoupler-isolated relay boards
    assign dec_out_low = ~dec_out_high;

endmodule
