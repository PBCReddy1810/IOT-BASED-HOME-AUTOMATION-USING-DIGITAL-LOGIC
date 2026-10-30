// ============================================================================
// Module: home_fsm
// Description: VLSI Finite State Machine for Smart Home Automation Controller
// Purpose: Handles autonomous safety interlocks, lighting energy conservation,
//          occupancy-driven actuation, and remote override commands.
// ============================================================================
`timescale 1ns / 1ps

module home_fsm (
    input  wire       clk,            // System Clock (e.g. 32.768 kHz RTC or 1 MHz)
    input  wire       rst_n,          // Active-low asynchronous reset
    
    // Sensor Status Inputs (Conditioned digital signals)
    input  wire       gas_alert,      // MQ-2/MQ-5 Gas Leak threshold triggered
    input  wire       fire_alert,     // Flame / Thermal threshold triggered
    input  wire       security_trip,  // Magnetic Reed Switch breach
    input  wire       pir_motion,     // PIR Motion Sensor triggered
    input  wire       ldr_dark,       // LDR comparator (1 = Night/Dark, 0 = Daylight)
    
    // Remote Control & Mode Inputs
    input  wire       arm_security,   // User armed security via Wi-Fi/BLE
    input  wire       remote_override,// Remote command active
    input  wire [7:0] remote_act_cmd, // Remote desired actuator states
    
    // Timer / Counter Expire Flags
    input  wire       timer_expired,  // Occupancy / Light timeout (e.g. 60 sec)
    
    // Outputs
    output reg  [2:0] current_state,  // Current FSM state
    output reg  [7:0] auto_actuators, // Actuator driver lines [Relay 7..0]
    output reg        timer_start,    // Trigger hardware countdown timer
    output reg        cg_enable,      // Clock Gating enable (1 = run, 0 = sleep)
    output reg        mcu_wake_req    // Wake-up line to ESP32
);

    // State Encoding
    localparam STATE_IDLE_STANDBY    = 3'b000;
    localparam STATE_DAY_OCCUPIED    = 3'b001;
    localparam STATE_NIGHT_LIGHTING  = 3'b010;
    localparam STATE_GAS_EMERGENCY   = 3'b011;
    localparam STATE_FIRE_EMERGENCY  = 3'b100;
    localparam STATE_SECURITY_BREACH = 3'b101;
    localparam STATE_REMOTE_CTRL     = 3'b110;
    localparam STATE_TIMEOUT_COOLDOWN= 3'b111;

    reg [2:0] next_state;

    // ------------------------------------------------------------------------
    // Next State Combinational Logic
    // ------------------------------------------------------------------------
    always @(*) begin
        // Default transition: maintain current state
        next_state = current_state;

        // Asynchronous emergency overrides have top priority in any state
        if (gas_alert) begin
            next_state = STATE_GAS_EMERGENCY;
        end else if (fire_alert) begin
            next_state = STATE_FIRE_EMERGENCY;
        end else if (arm_security && security_trip) begin
            next_state = STATE_SECURITY_BREACH;
        end else if (remote_override) begin
            next_state = STATE_REMOTE_CTRL;
        end else begin
            case (current_state)
                STATE_IDLE_STANDBY: begin
                    if (pir_motion) begin
                        if (ldr_dark)
                            next_state = STATE_NIGHT_LIGHTING;
                        else
                            next_state = STATE_DAY_OCCUPIED;
                    end
                end

                STATE_DAY_OCCUPIED: begin
                    if (!pir_motion)
                        next_state = STATE_TIMEOUT_COOLDOWN;
                    else if (ldr_dark)
                        next_state = STATE_NIGHT_LIGHTING;
                end

                STATE_NIGHT_LIGHTING: begin
                    if (!pir_motion)
                        next_state = STATE_TIMEOUT_COOLDOWN;
                    else if (!ldr_dark)
                        next_state = STATE_DAY_OCCUPIED;
                end

                STATE_TIMEOUT_COOLDOWN: begin
                    if (pir_motion) begin
                        next_state = (ldr_dark) ? STATE_NIGHT_LIGHTING : STATE_DAY_OCCUPIED;
                    end else if (timer_expired) begin
                        next_state = STATE_IDLE_STANDBY;
                    end
                end

                STATE_GAS_EMERGENCY: begin
                    // Remain in emergency until gas cleared by ventilation
                    if (!gas_alert)
                        next_state = STATE_IDLE_STANDBY;
                end

                STATE_FIRE_EMERGENCY: begin
                    if (!fire_alert)
                        next_state = STATE_IDLE_STANDBY;
                end

                STATE_SECURITY_BREACH: begin
                    if (!arm_security)
                        next_state = STATE_IDLE_STANDBY;
                end

                STATE_REMOTE_CTRL: begin
                    if (!remote_override)
                        next_state = STATE_IDLE_STANDBY;
                end

                default: next_state = STATE_IDLE_STANDBY;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // State Register (Sequential Logic)
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= STATE_IDLE_STANDBY;
        end else begin
            current_state <= next_state;
        end
    end

    // ------------------------------------------------------------------------
    // Output Logic (Moore/Mealy Output Conditioning)
    // Actuator mapping:
    //   Bit 0: Living Room Lights
    //   Bit 1: Ceiling Fan
    //   Bit 2: Kitchen Exhaust Fan
    //   Bit 3: Siren / Alarm Buzzer
    //   Bit 4: Bedroom Lights
    //   Bit 5: Outdoor / Security Floodlights
    //   Bit 6: Smart Door Solenoid Lock
    //   Bit 7: Safety Main Power Relay (Normally closed / active)
    // ------------------------------------------------------------------------
    always @(*) begin
        // Defaults
        auto_actuators = 8'b00000000;
        timer_start    = 1'b0;
        cg_enable      = 1'b1; // Normal clock on
        mcu_wake_req   = 1'b0;

        case (current_state)
            STATE_IDLE_STANDBY: begin
                // All non-essential loads turned OFF for max power saving
                auto_actuators = 8'b00000000;
                cg_enable      = 1'b0; // Clock gating active to save P_dynamic
                mcu_wake_req   = 1'b0;
            end

            STATE_DAY_OCCUPIED: begin
                // Fan ON, Lights OFF (Daylight sufficient)
                auto_actuators = 8'b00000010; // Fan ON
                timer_start    = 1'b1;
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b1;
            end

            STATE_NIGHT_LIGHTING: begin
                // Lights ON, Fan ON
                auto_actuators = 8'b00000011; // Lights + Fan
                timer_start    = 1'b1;
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b1;
            end

            STATE_TIMEOUT_COOLDOWN: begin
                // Maintain lights during countdown
                auto_actuators = (ldr_dark) ? 8'b00000001 : 8'b00000010;
                cg_enable      = 1'b1;
            end

            STATE_GAS_EMERGENCY: begin
                // Gas leak: Turn ON Exhaust fan (Bit 2), Siren (Bit 3),
                // Turn OFF indoor lights to prevent electrical spark ignition!
                auto_actuators = 8'b00001100; // Siren + Exhaust Fan
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b1;        // Immediate NMI to MCU
            end

            STATE_FIRE_EMERGENCY: begin
                // Siren (Bit 3) ON, Safety Main Cutoff, Floodlights ON for evacuation
                auto_actuators = 8'b00101000; // Siren + Outdoor Floodlights
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b1;
            end

            STATE_SECURITY_BREACH: begin
                // Alarm siren (Bit 3), Outdoor floodlights (Bit 5), Lock doors (Bit 6)
                auto_actuators = 8'b01101000; // Lock + Floodlights + Siren
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b1;
            end

            STATE_REMOTE_CTRL: begin
                // Directly pass through remote commands received via Wi-Fi/Bluetooth
                auto_actuators = remote_act_cmd;
                cg_enable      = 1'b1;
                mcu_wake_req   = 1'b0;
            end

            default: begin
                auto_actuators = 8'b00000000;
                cg_enable      = 1'b0;
            end
        endcase
    end

endmodule
