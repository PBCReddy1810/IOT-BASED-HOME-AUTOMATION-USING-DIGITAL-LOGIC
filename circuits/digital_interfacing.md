# Digital Logic Truth Tables & Boolean Formulations

This document details the digital logic structures, Boolean equations, and truth tables governing the hardware blocks used in the IoT Home Automation system.

---

## 1. 74HC148 / 8-to-3 Priority Encoder

The priority encoder resolves simultaneous sensor events by identifying the highest-priority active sensor input. Input 7 has highest priority, Input 0 lowest.

### Truth Table

| $\text{EI}$ | $I_7$ (Gas) | $I_6$ (Fire) | $I_5$ (Door) | $I_4$ (PIR) | $I_3$ (Water) | $I_2$ (LDR) | $I_1$ (Sw1) | $I_0$ (Sw0) | $A_2$ | $A_1$ | $A_0$ | $/GS$ (Wake IRQ) | $/EO$ | Event Triggered |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|
| 1 | X | X | X | X | X | X | X | X | 1 | 1 | 1 | 1 | 1 | Chip Disabled |
| 0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 0 | None (Idle Standby) |
| 0 | **0** | X | X | X | X | X | X | X | **0** | **0** | **0** | **0** | 1 | **MQ-2 Gas Leak (P7)** |
| 0 | 1 | **0** | X | X | X | X | X | X | **0** | **0** | **1** | **0** | 1 | **Flame / Fire (P6)** |
| 0 | 1 | 1 | **0** | X | X | X | X | X | **0** | **1** | **0** | **0** | 1 | **Door Perimeter (P5)** |
| 0 | 1 | 1 | 1 | **0** | X | X | X | X | **0** | **1** | **1** | **0** | 1 | **PIR Occupancy (P4)** |
| 0 | 1 | 1 | 1 | 1 | **0** | X | X | X | **1** | **0** | **0** | **0** | 1 | **Water Leak (P3)** |
| 0 | 1 | 1 | 1 | 1 | 1 | **0** | X | X | **1** | **0** | **1** | **0** | 1 | **LDR Twilight (P2)** |
| 0 | 1 | 1 | 1 | 1 | 1 | 1 | **0** | X | **1** | **1** | **0** | **0** | 1 | **Manual Switch 1 (P1)**|
| 0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | **0** | **1** | **1** | **1** | **0** | 1 | **Manual Switch 0 (P0)**|

*Note: The standard 74HC148 uses active-low logic. In our top-level Verilog IP module (`priority_encoder_8to3.v`), signals are normalized to active-high for modern CMOS design flow.*

---

## 2. 74HC138 / 3-to-8 Line Actuator Decoder

Allows the ESP32 microcontroller to address 1 of 8 distinct actuators using only 3 GPIO pins ($A_0, A_1, A_2$) and 1 Enable line ($E$), conserving 5 micro-controller GPIO pins for other IoT functions.

### Truth Table (Active-High Output Representation)

| $E$ (Enable) | $A_2$ | $A_1$ | $A_0$ | $Y_7$ | $Y_6$ | $Y_5$ | $Y_4$ | $Y_3$ | $Y_2$ | $Y_1$ | $Y_0$ | Selected Actuator Device |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|
| 0 | X | X | X | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | All Disabled (Quiescent) |
| 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **1** | Relay 0: Living Room Light |
| 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | **1** | 0 | Relay 1: Ceiling Fan |
| 1 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | **1** | 0 | 0 | Relay 2: Kitchen Exhaust Fan |
| 1 | 0 | 1 | 1 | 0 | 0 | 0 | 0 | **1** | 0 | 0 | 0 | Relay 3: Alarm Siren / Buzzer |
| 1 | 1 | 0 | 0 | 0 | 0 | 0 | **1** | 0 | 0 | 0 | 0 | Relay 4: Bedroom Lights |
| 1 | 1 | 0 | 1 | 0 | 0 | **1** | 0 | 0 | 0 | 0 | 0 | Relay 5: Security Floodlights |
| 1 | 1 | 1 | 0 | 0 | **1** | 0 | 0 | 0 | 0 | 0 | 0 | Relay 6: Smart Door Solenoid |
| 1 | 1 | 1 | 1 | **1** | 0 | 0 | 0 | 0 | 0 | 0 | 0 | Relay 7: Aux Outlet / Pump |

### Boolean Equations for Decoder Outputs

$$Y_0 = E \cdot \overline{A_2} \cdot \overline{A_1} \cdot \overline{A_0}$$
$$Y_1 = E \cdot \overline{A_2} \cdot \overline{A_1} \cdot A_0$$
$$Y_2 = E \cdot \overline{A_2} \cdot A_1 \cdot \overline{A_0}$$
$$Y_3 = E \cdot \overline{A_2} \cdot A_1 \cdot A_0$$
$$Y_4 = E \cdot A_2 \cdot \overline{A_1} \cdot \overline{A_0}$$
$$Y_5 = E \cdot A_2 \cdot \overline{A_1} \cdot A_0$$
$$Y_6 = E \cdot A_2 \cdot A_1 \cdot \overline{A_0}$$
$$Y_7 = E \cdot A_2 \cdot A_1 \cdot A_0$$

---

## 3. 74HC151 / 8-to-1 Multiplexer (Sensor Bus Multiplexing)

Enables scanning 8 sensor lines across a single GPIO pin (`PIN_MUX_SIG` on GPIO 34).

### Boolean Expression for Multiplexed Output $Y$:

$$Y = \overline{S_2} \cdot \overline{S_1} \cdot \overline{S_0} \cdot D_0 + \overline{S_2} \cdot \overline{S_1} \cdot S_0 \cdot D_1 + \overline{S_2} \cdot S_1 \cdot \overline{S_0} \cdot D_2 + \overline{S_2} \cdot S_1 \cdot S_0 \cdot D_3 + S_2 \cdot \overline{S_1} \cdot \overline{S_0} \cdot D_4 + S_2 \cdot \overline{S_1} \cdot S_0 \cdot D_5 + S_2 \cdot S_1 \cdot \overline{S_0} \cdot D_6 + S_2 \cdot S_1 \cdot S_0 \cdot D_7$$

---

## 4. Hardware Safety Interlock Combinational Logic

To ensure absolute safety in mission-critical gas leaks or fire emergencies, the digital circuit features hardwired combinatorial gates that override MCU software instructions instantaneously:

1. **Gas Emergency Exhaust Override**:
   $$\text{Exhaust\_Fan\_Drive} = \text{MCU\_Exhaust\_Cmd} + \text{Gas\_Alert}$$
   *The exhaust fan activates whenever the MCU requests it OR when the gas sensor detects hazardous gas, regardless of microcontroller operational state.*

2. **Electrical Arc Spark Prevention**:
   $$\text{Room\_Light\_Drive} = \text{MCU\_Light\_Cmd} \cdot \overline{\text{Gas\_Alert}}$$
   *During a gas leak, all room lights are forced OFF at the hardware gate level to eliminate contact arcing that could ignite ambient gas.*

3. **Intruder Alarm Siren Drive**:
   $$\text{Alarm\_Siren\_Drive} = \text{Gas\_Alert} + \text{Fire\_Alert} + (\text{Security\_Armed} \cdot \text{Door\_Breached}) + \text{MCU\_Siren\_Cmd}$$
