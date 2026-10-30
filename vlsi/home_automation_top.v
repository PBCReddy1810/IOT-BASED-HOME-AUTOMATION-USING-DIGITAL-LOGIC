// ============================================================================
// Top Module: home_automation_top
// Description: Complete Digital Logic & VLSI IP Core for Home Automation
// Interfaces:
//   - Sensors: Conditioned digital inputs (PIR, LDR, Gas, Fire, Reed Switch)
//   - Microcontroller (ESP32): Bus interface (Addr[2:0], Data, En, IRQ)
//   - Actuators: 8-channel relay drivers / triac signals
//   - Power Optimization: Integrated Clock Gating & Power Domain Controls
// ============================================================================
`timescale 1ns / 1ps

module home_automation_top (
    input  wire        master_clk,       // Main system clock (e.g., 32 kHz - 1 MHz)
    input  wire        rst_n,            // Asynchronous active-low reset
    input  wire        test_mode,        // Test/DFT bypass for clock gating
    
    // Physical Sensor Digital Inputs (Conditioned via Schmitt Triggers & Comparators)
    input  wire        sensor_gas,       // MQ-2 Digital Out (Threshold Comparator)
    input  wire        sensor_fire,      // Flame Sensor Digital Out
    input  wire        sensor_door,      // Magnetic Reed Switch (Door/Window)
    input  wire        sensor_pir,       // PIR Motion Sensor
    input  wire        sensor_water,     // Water level / leak detector
    input  wire        sensor_ldr,       // LDR Day/Night Comparator (1 = Dark)
    input  wire        wall_sw1,         // Physical Toggle Switch 1
    input  wire        wall_sw0,         // Physical Toggle Switch 0
    
    // Microcontroller (ESP32) Digital Bus Interface
    input  wire [2:0]  mcu_addr,         // 3-bit channel address from MCU
    input  wire        mcu_mux_en_n,     // MCU MUX enable (Active Low)
    input  wire        mcu_dec_en,       // MCU Decoder enable (Active High)
    input  wire        mcu_override_en,  // MCU takes manual override over FSM
    input  wire [7:0]  mcu_act_override, // MCU direct actuator byte
    input  wire        arm_security,     // MCU sets Security Armed state
    
    // Outputs to Microcontroller
    output wire        mcu_sensor_bit,   // Selected sensor status bit via MUX
    output wire [2:0]  irq_priority,     // Highest active sensor priority (0-7)
    output wire        mcu_wake_irq,     // Asynchronous wake-up interrupt to ESP32
    
    // Outputs to Physical Actuators (Relays / Triacs / Buzzers)
    output wire [7:0]  actuator_lines,   // Active-High actuator drive signals
    output wire [7:0]  actuator_lines_n, // Active-Low outputs (for opto-relay boards)
    output wire        sensor_pwr_gate,  // P-MOSFET gate control to cut sensor standby power
    output wire [2:0]  current_fsm_state // FSM debug state output
);

    // Pack all 8 sensors into an 8-bit bus
    // Index 7 has highest priority, Index 0 lowest
    wire [7:0] sensor_bus;
    assign sensor_bus = {
        sensor_gas,    // Bit 7: Gas/Smoke Leak (Highest Priority)
        sensor_fire,   // Bit 6: Fire / High Temp
        sensor_door,   // Bit 5: Security Reed Switch
        sensor_pir,    // Bit 4: Motion
        sensor_water,  // Bit 3: Water Leak
        sensor_ldr,    // Bit 2: LDR Dark/Light
        wall_sw1,      // Bit 1: Wall Switch 1
        wall_sw0       // Bit 0: Wall Switch 0
    };

    // ------------------------------------------------------------------------
    // 1. Priority Encoder Sub-block (Hardware Interrupt Generator)
    // ------------------------------------------------------------------------
    wire encoder_active;
    wire encoder_irq;

    priority_encoder_8to3 u_priority_enc (
        .en           (1'b1),
        .sensor_in    (sensor_bus),
        .code_out     (irq_priority),
        .active_event (encoder_active),
        .int_req      (encoder_irq)
    );

    // ------------------------------------------------------------------------
    // 2. Multiplexer Sub-block (Single-pin Sensor Polling for MCU)
    // ------------------------------------------------------------------------
    mux_8to1 u_sensor_mux (
        .en_n     (mcu_mux_en_n),
        .data_in  (sensor_bus),
        .sel      (mcu_addr),
        .mux_out  (mcu_sensor_bit),
        .mux_out_n()
    );

    // ------------------------------------------------------------------------
    // 3. Integrated Clock Gating (ICG) Sub-block for Power Optimization
    // ------------------------------------------------------------------------
    wire fsm_cg_enable;
    wire gated_clk;

    // The FSM requests clock gating when in IDLE_STANDBY.
    // If any sensor becomes active or MCU asserts override, clock wakes instantly.
    wire clock_wake_trigger;
    assign clock_wake_trigger = fsm_cg_enable | encoder_active | mcu_override_en;

    clock_gating_cell u_clock_gate (
        .clk_in    (master_clk),
        .enable    (clock_wake_trigger),
        .test_mode (test_mode),
        .clk_out   (gated_clk)
    );

    // ------------------------------------------------------------------------
    // 4. Finite State Machine (FSM) Core
    // ------------------------------------------------------------------------
    wire [7:0] fsm_actuators;
    wire       fsm_mcu_wake;

    home_fsm u_home_fsm (
        .clk             (gated_clk),
        .rst_n           (rst_n),
        .gas_alert       (sensor_gas),
        .fire_alert      (sensor_fire),
        .security_trip   (sensor_door),
        .pir_motion      (sensor_pir),
        .ldr_dark        (sensor_ldr),
        .arm_security    (arm_security),
        .remote_override (mcu_override_en),
        .remote_act_cmd  (mcu_act_override),
        .timer_expired   (1'b0), // Tied to timer or MCU strobe
        .current_state   (current_fsm_state),
        .auto_actuators  (fsm_actuators),
        .timer_start     (),
        .cg_enable       (fsm_cg_enable),
        .mcu_wake_req    (fsm_mcu_wake)
    );

    // Microcontroller Wake-Up IRQ combines priority encoder active line and FSM wake line
    assign mcu_wake_irq = encoder_irq | fsm_mcu_wake;

    // ------------------------------------------------------------------------
    // 5. Decoder Sub-block (MCU 3-bit to 8-actuator direct addressing)
    // ------------------------------------------------------------------------
    wire [7:0] dec_out_high;
    wire [7:0] dec_out_low;

    decoder_3to8 u_actuator_dec (
        .en           (mcu_dec_en),
        .addr         (mcu_addr),
        .dec_out_high (dec_out_high),
        .dec_out_low  (dec_out_low)
    );

    // ------------------------------------------------------------------------
    // 6. Actuator Arbiter & Multiplexing Logic
    // If MCU sets override, use MCU direct lines or decoded lines;
    // Otherwise, autonomous FSM safety control drives actuators.
    // Gas/Fire safety always overrides any non-emergency setting!
    // ------------------------------------------------------------------------
    wire emergency_override;
    assign emergency_override = sensor_gas | sensor_fire;

    wire [7:0] final_actuators;
    assign final_actuators = (emergency_override) ? fsm_actuators :
                             (mcu_override_en)    ? (mcu_dec_en ? dec_out_high : mcu_act_override) :
                                                    fsm_actuators;

    assign actuator_lines   = final_actuators;
    assign actuator_lines_n = ~final_actuators;

    // Sensor High-Side Power Gating control
    // When in deep standby, power to resistive sensors (LDR, MQ-2 heater) can be duty-cycled
    assign sensor_pwr_gate = (current_fsm_state == 3'b000) ? 1'b0 : 1'b1;

endmodule
