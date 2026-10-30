// ============================================================================
// Module: priority_encoder_8to3
// Description: 8-to-3 Priority Encoder with Group Select and Enable
// Purpose: Hardware interrupt prioritization for home sensors.
//          Highest index has highest priority (e.g., Gas Leak = 7, Fire = 6).
//          Generates an instantaneous wake-up interrupt (int_req) to MCU.
// ============================================================================
`timescale 1ns / 1ps

module priority_encoder_8to3 (
    input  wire       en,           // Active-high block enable
    input  wire [7:0] sensor_in,    // 8 digital sensor inputs [7:0]
    output reg  [2:0] code_out,     // 3-bit encoded priority address
    output wire       active_event, // Flag indicating at least one sensor is active
    output wire       int_req       // Wake-up interrupt request to microcontroller
);

    // Group Select flag
    assign active_event = en & (|sensor_in);
    
    // Interrupt is fired on any valid active event
    assign int_req = active_event;

    always @(*) begin
        if (!en) begin
            code_out = 3'b000;
        end else begin
            casez (sensor_in)
                8'b1???????: code_out = 3'b111; // Priority 7: Gas/Smoke Leak (EMERGENCY)
                8'b01??????: code_out = 3'b110; // Priority 6: Fire / Flame Detected
                8'b001?????: code_out = 3'b101; // Priority 5: Perimeter Security (Reed Switch)
                8'b0001????: code_out = 3'b100; // Priority 4: PIR Motion Detection
                8'b00001???: code_out = 3'b011; // Priority 3: Water Leakage Sensor
                8'b000001??: code_out = 3'b010; // Priority 2: LDR Day/Night Threshold
                8'b0000001?: code_out = 3'b001; // Priority 1: Manual Wall Switch 1
                8'b00000001: code_out = 3'b000; // Priority 0: Manual Wall Switch 0
                default:     code_out = 3'b000; // No event active
            endcase
        end
    end

endmodule
