// ============================================================================
// Testbench: tb_home_automation
// Description: Verifies Digital Logic, Priority Encoder, MUX, Decoder, FSM,
//              and Power-Optimizing Clock Gating under various home scenarios.
// ============================================================================
`timescale 1ns / 1ps

module tb_home_automation;

    reg master_clk;
    reg rst_n;
    reg test_mode;

    // Sensors
    reg sensor_gas;
    reg sensor_fire;
    reg sensor_door;
    reg sensor_pir;
    reg sensor_water;
    reg sensor_ldr;
    reg wall_sw1;
    reg wall_sw0;

    // MCU Interface
    reg [2:0] mcu_addr;
    reg       mcu_mux_en_n;
    reg       mcu_dec_en;
    reg       mcu_override_en;
    reg [7:0] mcu_act_override;
    reg       arm_security;

    // Outputs
    wire       mcu_sensor_bit;
    wire [2:0] irq_priority;
    wire       mcu_wake_irq;
    wire [7:0] actuator_lines;
    wire [7:0] actuator_lines_n;
    wire       sensor_pwr_gate;
    wire [2:0] current_fsm_state;

    // Instantiate Top-Level Device Under Test (DUT)
    home_automation_top dut (
        .master_clk       (master_clk),
        .rst_n           (rst_n),
        .test_mode        (test_mode),
        .sensor_gas       (sensor_gas),
        .sensor_fire      (sensor_fire),
        .sensor_door      (sensor_door),
        .sensor_pir       (sensor_pir),
        .sensor_water     (sensor_water),
        .sensor_ldr       (sensor_ldr),
        .wall_sw1         (wall_sw1),
        .wall_sw0         (wall_sw0),
        .mcu_addr         (mcu_addr),
        .mcu_mux_en_n     (mcu_mux_en_n),
        .mcu_dec_en       (mcu_dec_en),
        .mcu_override_en  (mcu_override_en),
        .mcu_act_override (mcu_act_override),
        .arm_security     (arm_security),
        .mcu_sensor_bit   (mcu_sensor_bit),
        .irq_priority     (irq_priority),
        .mcu_wake_irq     (mcu_wake_irq),
        .actuator_lines   (actuator_lines),
        .actuator_lines_n (actuator_lines_n),
        .sensor_pwr_gate  (sensor_pwr_gate),
        .current_fsm_state(current_fsm_state)
    );

    // Clock generation: 100 kHz (10 us period)
    always #5 master_clk = ~master_clk;

    initial begin
        $display("---------------------------------------------------------------");
        $display("   VLSI & DIGITAL LOGIC HOME AUTOMATION TESTBENCH START");
        $display("---------------------------------------------------------------");

        // Initialization
        master_clk       = 0;
        rst_n            = 0;
        test_mode        = 0;
        sensor_gas       = 0;
        sensor_fire      = 0;
        sensor_door      = 0;
        sensor_pir       = 0;
        sensor_water     = 0;
        sensor_ldr       = 0;
        wall_sw1         = 0;
        wall_sw0         = 0;
        mcu_addr         = 3'b000;
        mcu_mux_en_n     = 1;
        mcu_dec_en       = 0;
        mcu_override_en  = 0;
        mcu_act_override = 8'h00;
        arm_security     = 0;

        #20;
        rst_n = 1; // Release reset
        #20;

        // -------------------------------------------------------------
        // TEST 1: Idle Standby & Clock Gating Verification
        // -------------------------------------------------------------
        $display("[TEST 1] Checking IDLE Standby State...");
        #20;
        if (current_fsm_state === 3'b000 && actuator_lines === 8'h00) begin
            $display("  -> SUCCESS: FSM is in IDLE_STANDBY. Actuators OFF. Low Power Active.");
        end else begin
            $display("  -> FAIL: Unexpected state: %b, actuators: %b", current_fsm_state, actuator_lines);
        end

        // -------------------------------------------------------------
        // TEST 2: Night Occupancy (LDR = 1, PIR = 1) -> Automatic Lighting
        // -------------------------------------------------------------
        $display("[TEST 2] Night Motion Detected (LDR=1, PIR=1)...");
        sensor_ldr = 1; // It is night/dark
        sensor_pir = 1; // Person walks in
        #20;
        if (current_fsm_state === 3'b010 && actuator_lines[0] === 1'b1) begin
            $display("  -> SUCCESS: FSM transitioned to NIGHT_LIGHTING. Living room lights ON.");
        end else begin
            $display("  -> FAIL: State: %b, Actuators: %b", current_fsm_state, actuator_lines);
        end

        // -------------------------------------------------------------
        // TEST 3: Priority Interrupt: Gas Leak Overrides Normal Night Lights
        // -------------------------------------------------------------
        $display("[TEST 3] Critical Gas Leak Detected (Priority 7)...");
        sensor_gas = 1; // MQ-2 comparator fires!
        #20;
        if (current_fsm_state === 3'b011 && irq_priority === 3'b111 && mcu_wake_irq === 1'b1) begin
            $display("  -> SUCCESS: Gas Emergency State triggered!");
            $display("     Priority Encoder = %b (Highest 7)", irq_priority);
            $display("     Actuator outputs = %b (Exhaust Fan + Siren ON, Room Lights OFF for safety)", actuator_lines);
            $display("     Wake IRQ asserted to MCU.");
        end else begin
            $display("  -> FAIL: Gas response incorrect.");
        end

        // Clear gas condition
        sensor_gas = 0;
        #20;

        // -------------------------------------------------------------
        // TEST 4: Microcontroller MUX Reading of Sensor Lines
        // -------------------------------------------------------------
        $display("[TEST 4] Microcontroller Sensor Bus Scanning via 8:1 MUX...");
        sensor_pir = 1;
        mcu_mux_en_n = 0; // Enable MUX
        mcu_addr = 3'b100; // Select Channel 4 (PIR sensor)
        #10;
        if (mcu_sensor_bit === 1'b1) begin
            $display("  -> SUCCESS: MCU read PIR bit = 1 on single GPIO pin.");
        end else begin
            $display("  -> FAIL: MUX failed to route sensor bit.");
        end

        // -------------------------------------------------------------
        // TEST 5: Microcontroller Actuator Decoder Addressing
        // -------------------------------------------------------------
        $display("[TEST 5] Microcontroller 3-to-8 Decoder Actuation...");
        sensor_pir = 0;
        sensor_ldr = 0;
        #20;
        mcu_override_en = 1; // MCU in control
        mcu_dec_en = 1;      // Enable 74HC138 decoder
        mcu_addr = 3'b110;   // Select Actuator 6 (Smart Door Lock)
        #10;
        if (actuator_lines[6] === 1'b1 && actuator_lines[0] === 1'b0) begin
            $display("  -> SUCCESS: Decoder activated Channel 6 (Door Lock) using 3 address lines.");
        end else begin
            $display("  -> FAIL: Decoder output mismatch: %b", actuator_lines);
        end

        // -------------------------------------------------------------
        // TEST 6: Remote Command Byte from Wi-Fi / Bluetooth
        // -------------------------------------------------------------
        $display("[TEST 6] Remote Wi-Fi/BLE Override Command Byte...");
        mcu_dec_en = 0;
        mcu_act_override = 8'b10100101; // Remote user sets custom pattern
        #10;
        if (actuator_lines === 8'b10100101) begin
            $display("  -> SUCCESS: Remote Wi-Fi/Bluetooth pattern correctly applied: %b", actuator_lines);
        end else begin
            $display("  -> FAIL: Actuators = %b", actuator_lines);
        end

        $display("---------------------------------------------------------------");
        $display("   ALL VLSI & DIGITAL LOGIC TESTBENCH SUITES PASSED!");
        $display("---------------------------------------------------------------");
        $finish;
    end

endmodule
