#!/usr/bin/env python3
"""
===============================================================================
VLSI & Digital Logic Home Automation Cycle-Accurate Simulator & Power Analyzer
===============================================================================
This simulator models:
 1. 8-to-3 Priority Encoder (74HC148 equivalent)
 2. 8-to-1 Multiplexer (74HC151 equivalent)
 3. 3-to-8 Decoder (74HC138 equivalent)
 4. Finite State Machine (FSM) state transitions
 5. Integrated Clock Gating (ICG) power analysis:
    P_dynamic = alpha * C_L * V_dd^2 * f_clk
 6. Static Leakage & Power Gating calculations
===============================================================================
"""

import sys

class PriorityEncoder8to3:
    @staticmethod
    def encode(sensors, en=True):
        if not en or sensors == 0:
            return {'code': 0, 'active': False, 'int_req': False}
        # Priority order: bit 7 (highest) down to bit 0 (lowest)
        for bit in range(7, -1, -1):
            if (sensors >> bit) & 1:
                return {'code': bit, 'active': True, 'int_req': True}
        return {'code': 0, 'active': False, 'int_req': False}

class Mux8to1:
    @staticmethod
    def select(data_in, sel, en_n=False):
        if en_n:
            return 0
        return (data_in >> (sel & 0x7)) & 1

class Decoder3to8:
    @staticmethod
    def decode(addr, en=True):
        if not en:
            return 0x00
        return 1 << (addr & 0x7)

class HomeAutomationFSM:
    STATE_IDLE_STANDBY     = 0b000
    STATE_DAY_OCCUPIED     = 0b001
    STATE_NIGHT_LIGHTING   = 0b010
    STATE_GAS_EMERGENCY    = 0b011
    STATE_FIRE_EMERGENCY   = 0b100
    STATE_SECURITY_BREACH  = 0b101
    STATE_REMOTE_CTRL      = 0b110
    STATE_TIMEOUT_COOLDOWN = 0b111

    STATE_NAMES = {
        0b000: "IDLE_STANDBY",
        0b001: "DAY_OCCUPIED",
        0b010: "NIGHT_LIGHTING",
        0b011: "GAS_EMERGENCY",
        0b100: "FIRE_EMERGENCY",
        0b101: "SECURITY_BREACH",
        0b110: "REMOTE_CTRL",
        0b111: "TIMEOUT_COOLDOWN"
    }

    def __init__(self):
        self.state = self.STATE_IDLE_STANDBY

    def step(self, gas, fire, security_trip, arm_sec, pir, ldr_dark, remote_en, remote_cmd):
        # Emergency priority overrides
        if gas:
            self.state = self.STATE_GAS_EMERGENCY
        elif fire:
            self.state = self.STATE_FIRE_EMERGENCY
        elif arm_sec and security_trip:
            self.state = self.STATE_SECURITY_BREACH
        elif remote_en:
            self.state = self.STATE_REMOTE_CTRL
        else:
            if self.state == self.STATE_IDLE_STANDBY:
                if pir:
                    self.state = self.STATE_NIGHT_LIGHTING if ldr_dark else self.STATE_DAY_OCCUPIED
            elif self.state in (self.STATE_DAY_OCCUPIED, self.STATE_NIGHT_LIGHTING):
                if not pir:
                    self.state = self.STATE_TIMEOUT_COOLDOWN
            elif self.state == self.STATE_TIMEOUT_COOLDOWN:
                if pir:
                    self.state = self.STATE_NIGHT_LIGHTING if ldr_dark else self.STATE_DAY_OCCUPIED
                else:
                    self.state = self.STATE_IDLE_STANDBY
            elif self.state in (self.STATE_GAS_EMERGENCY, self.STATE_FIRE_EMERGENCY, self.STATE_SECURITY_BREACH, self.STATE_REMOTE_CTRL):
                self.state = self.STATE_IDLE_STANDBY

        # Actuator output mapping
        # Bit 0: Light, Bit 1: Fan, Bit 2: Exhaust, Bit 3: Siren, Bit 5: Floodlight, Bit 6: Lock
        if self.state == self.STATE_IDLE_STANDBY:
            actuators = 0x00
            cg_enable = 0  # Clock gating enabled (clock turned OFF to save power)
            wake_mcu = 0
        elif self.state == self.STATE_DAY_OCCUPIED:
            actuators = 0b00000010  # Fan ON, Lights OFF
            cg_enable = 1
            wake_mcu = 1
        elif self.state == self.STATE_NIGHT_LIGHTING:
            actuators = 0b00000011  # Lights ON, Fan ON
            cg_enable = 1
            wake_mcu = 1
        elif self.state == self.STATE_GAS_EMERGENCY:
            actuators = 0b00001100  # Exhaust Fan (Bit 2) + Siren (Bit 3) ON
            cg_enable = 1
            wake_mcu = 1
        elif self.state == self.STATE_FIRE_EMERGENCY:
            actuators = 0b00101000  # Siren (Bit 3) + Floodlights (Bit 5)
            cg_enable = 1
            wake_mcu = 1
        elif self.state == self.STATE_SECURITY_BREACH:
            actuators = 0b01101000  # Lock (Bit 6) + Floodlight (Bit 5) + Siren (Bit 3)
            cg_enable = 1
            wake_mcu = 1
        elif self.state == self.STATE_REMOTE_CTRL:
            actuators = remote_cmd
            cg_enable = 1
            wake_mcu = 0
        else:
            actuators = 0x00
            cg_enable = 1
            wake_mcu = 0

        return self.state, actuators, cg_enable, wake_mcu


def calculate_cmos_power(v_dd, f_clk, c_load, alpha_ungated, alpha_gated, i_leak_ungated, i_leak_gated):
    """
    Calculates CMOS Dynamic and Static Power Dissipation:
    P_dynamic = alpha * C_load * V_dd^2 * f_clk
    P_static  = I_leak * V_dd
    """
    p_dyn_ungated = alpha_ungated * c_load * (v_dd ** 2) * f_clk
    p_dyn_gated   = alpha_gated * c_load * (v_dd ** 2) * f_clk
    
    p_stat_ungated = i_leak_ungated * v_dd
    p_stat_gated   = i_leak_gated * v_dd

    total_ungated = p_dyn_ungated + p_stat_ungated
    total_gated   = p_dyn_gated + p_stat_gated
    savings_pct   = ((total_ungated - total_gated) / total_ungated) * 100.0

    return {
        'p_dyn_ungated_uW': p_dyn_ungated * 1e6,
        'p_dyn_gated_uW': p_dyn_gated * 1e6,
        'p_stat_ungated_uW': p_stat_ungated * 1e6,
        'p_stat_gated_uW': p_stat_gated * 1e6,
        'total_ungated_uW': total_ungated * 1e6,
        'total_gated_uW': total_gated * 1e6,
        'savings_pct': savings_pct
    }


def main():
    print("=" * 72)
    print("  IOT BASED HOME AUTOMATION - DIGITAL LOGIC & VLSI SIMULATOR")
    print("=" * 72)

    # 1. Test Priority Encoder
    print("\n--- [1] TESTING 8-to-3 PRIORITY ENCODER (74HC148 Equivalent) ---")
    test_vectors = [
        (0b00000000, "All Idle"),
        (0b00000001, "Wall Switch 0 Active"),
        (0b00010000, "PIR Motion Active (Bit 4)"),
        (0b00010100, "PIR + LDR Active (Priority -> PIR Bit 4)"),
        (0b10010000, "PIR + GAS LEAK (Priority -> Gas Bit 7 OVERRIDE)"),
        (0b01100000, "Door Reed + Fire (Priority -> Fire Bit 6 OVERRIDE)"),
    ]
    for s_bus, desc in test_vectors:
        res = PriorityEncoder8to3.encode(s_bus)
        print(f"  Input: 0b{s_bus:08b} ({desc}) => Code: {res['code']} | Active: {res['active']} | Wake IRQ: {res['int_req']}")

    # 2. Test 8-to-1 Multiplexer
    print("\n--- [2] TESTING 8-to-1 MULTIPLEXER (74HC151 Single-Pin Sensor Bus) ---")
    sensor_sample = 0b10010100  # Gas (7)=1, PIR (4)=1, LDR (2)=1
    print(f"  Sensor Bus State: 0b{sensor_sample:08b}")
    for ch in range(8):
        bit_val = Mux8to1.select(sensor_sample, ch)
        sensor_names = ["WallSw0", "WallSw1", "LDR", "Water", "PIR", "Door", "Fire", "Gas"]
        print(f"  Select Sel={ch} ({sensor_names[ch]:8s}) => MUX Output: {bit_val}")

    # 3. Test 3-to-8 Actuator Decoder
    print("\n--- [3] TESTING 3-to-8 LINE DECODER (74HC138 Pin-Saving Actuation) ---")
    actuator_names = [
        "Relay 0 (Living Room Light)",
        "Relay 1 (Ceiling Fan)",
        "Relay 2 (Kitchen Exhaust Fan)",
        "Relay 3 (Emergency Siren)",
        "Relay 4 (Bedroom Light)",
        "Relay 5 (Outdoor Floodlights)",
        "Relay 6 (Door Solenoid Lock)",
        "Relay 7 (Water Pump / Aux)"
    ]
    for addr in range(8):
        dec_out = Decoder3to8.decode(addr)
        print(f"  Addr: {addr} (0b{addr:03b}) => 8-bit Output: 0b{dec_out:08b} -> Activating: {actuator_names[addr]}")

    # 4. Test Finite State Machine (FSM)
    print("\n--- [4] TESTING FINITE STATE MACHINE (FSM) WORKFLOW ---")
    fsm = HomeAutomationFSM()
    scenarios = [
        {"desc": "Initial Power On (Idle)", "gas": 0, "fire": 0, "sec": 0, "arm": 0, "pir": 0, "ldr": 0, "rem": 0, "cmd": 0},
        {"desc": "Daytime Motion Detected", "gas": 0, "fire": 0, "sec": 0, "arm": 0, "pir": 1, "ldr": 0, "rem": 0, "cmd": 0},
        {"desc": "Nighttime Motion Detected", "gas": 0, "fire": 0, "sec": 0, "arm": 0, "pir": 1, "ldr": 1, "rem": 0, "cmd": 0},
        {"desc": "CRITICAL: Gas Leak Overrides Normal Night Lights!", "gas": 1, "fire": 0, "sec": 0, "arm": 0, "pir": 1, "ldr": 1, "rem": 0, "cmd": 0},
        {"desc": "Gas Cleared, Returned to Standby", "gas": 0, "fire": 0, "sec": 0, "arm": 0, "pir": 0, "ldr": 1, "rem": 0, "cmd": 0},
        {"desc": "Security Armed + Intruder Door Opened", "gas": 0, "fire": 0, "sec": 1, "arm": 1, "pir": 0, "ldr": 1, "rem": 0, "cmd": 0},
        {"desc": "Remote Wi-Fi/BLE Override Active (Fan + Bedroom Light)", "gas": 0, "fire": 0, "sec": 0, "arm": 0, "pir": 0, "ldr": 0, "rem": 1, "cmd": 0b00010010},
    ]

    for s in scenarios:
        st, act, cg, wake = fsm.step(s["gas"], s["fire"], s["sec"], s["arm"], s["pir"], s["ldr"], s["rem"], s["cmd"])
        print(f"  Scenario: {s['desc']}")
        print(f"    -> State: {HomeAutomationFSM.STATE_NAMES[st]} | Actuators: 0b{act:08b} | Clock Gate: {'ACTIVE (Sleep)' if cg==0 else 'DISABLED (Clock RUN)'} | Wake MCU: {wake}")

    # 5. VLSI & Microcontroller Power Optimization Calculations
    print("\n" + "=" * 72)
    print("  POWER OPTIMIZATION ANALYSIS & CMOS DISSIPATION MODEL")
    print("=" * 72)
    v_dd = 3.3            # 3.3 Volts
    f_clk = 1_000_000     # 1 MHz VLSI IP Clock
    c_load = 50e-12       # 50 pF equivalent total switching capacitance
    alpha_ungated = 0.25  # 25% average toggle rate without clock gating
    alpha_gated = 0.01    # 1% toggle rate with clock gating cell
    i_leak_ungated = 5e-6 # 5 uA static leakage
    i_leak_gated = 0.5e-6 # 0.5 uA with power gating sleep transistor

    pwr = calculate_cmos_power(v_dd, f_clk, c_load, alpha_ungated, alpha_gated, i_leak_ungated, i_leak_gated)
    print(f"  Operating Voltage (V_dd)       : {v_dd} V")
    print(f"  Clock Frequency (f_clk)        : {f_clk / 1e3:.1f} kHz")
    print(f"  CMOS Dynamic Power (Ungated)   : {pwr['p_dyn_ungated_uW']:.2f} uW")
    print(f"  CMOS Dynamic Power (Gated)     : {pwr['p_dyn_gated_uW']:.2f} uW")
    print(f"  CMOS Static Leakage (Ungated)  : {pwr['p_stat_ungated_uW']:.2f} uW")
    print(f"  CMOS Static Leakage (Power-G)  : {pwr['p_stat_gated_uW']:.2f} uW")
    print(f"  TOTAL Power (Ungated)          : {pwr['total_ungated_uW']:.2f} uW")
    print(f"  TOTAL Power (Gated & Power-G)  : {pwr['total_gated_uW']:.2f} uW")
    print(f"  >> VLSI Energy Reduction       : {pwr['savings_pct']:.2f} % Power Saved! <<")

    # ESP32 Battery Life Comparison
    print("\n--- ESP32 SYSTEM BATTERY LONGEVITY MODEL (2500 mAh Li-ion Cell) ---")
    batt_mah = 2500.0
    # Case A: Always Active Wi-Fi polling
    i_active_ma = 180.0 # Active Wi-Fi RX/TX
    hours_ungated = batt_mah / i_active_ma
    # Case B: Event-Driven with Priority Interrupt Deep Sleep (99% deep sleep at 15 uA, 1% active at 180 mA)
    i_deep_sleep_ma = 0.015  # 15 uA
    duty_cycle = 0.005       # 0.5% active duty cycle
    i_avg_optimized = (duty_cycle * i_active_ma) + ((1.0 - duty_cycle) * i_deep_sleep_ma)
    hours_optimized = batt_mah / i_avg_optimized
    days_optimized = hours_optimized / 24.0

    print(f"  Battery Capacity               : {batt_mah:.0f} mAh (3.7V 18650 Cell)")
    print(f"  Continuous Active Polling Current: {i_active_ma:.1f} mA -> Battery Life: {hours_ungated:.1f} Hours ({hours_ungated/24.0:.1f} Days)")
    print(f"  Power-Optimized Average Current: {i_avg_optimized:.3f} mA ({i_avg_optimized*1000:.1f} uA)")
    print(f"  >> Power-Optimized Battery Life: {hours_optimized:.1f} Hours ({days_optimized:.1f} Days / {days_optimized/365.25:.2f} Years!) <<")
    print(f"  >> Battery Life Extension Factor: {hours_optimized / hours_ungated:.1f}x Longer Runtime! <<\n")

if __name__ == "__main__":
    main()
