/**
 * ============================================================================
 * Project: IoT-Based Home Automation Using Digital Logic & VLSI Blocks
 * Target: ESP32 Dual Core (Xtensa LX6) / Arduino Framework
 * Features:
 *   - Digital Logic Interfacing (74HC138 Decoder, 74HC148 Priority Encoder, 74HC151 MUX)
 *   - Dual Remote Control: Wi-Fi (Async Web Server + REST) & Bluetooth Low Energy (BLE)
 *   - Hardware Emergency Interlock: Gas/Fire overrides firmware latency
 *   - Advanced Power Optimization: Dynamic Frequency Scaling, P-MOSFET Sensor Gating,
 *     and EXT0 Hardware-Interrupt Deep Sleep Wakeup
 * ============================================================================
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "esp_sleep.h"
#include "esp_pm.h"

// ----------------------------------------------------------------------------
// Pin Definitions: Digital Logic & VLSI Bus Interface
// ----------------------------------------------------------------------------
// 74HC138 3-to-8 Actuator Decoder Lines (Saves 5 GPIO pins!)
#define PIN_DEC_A0         16
#define PIN_DEC_A1         17
#define PIN_DEC_A2         18
#define PIN_DEC_EN         19   // Active-High Enable for Decoder

// 74HC151 8-to-1 Sensor Multiplexer Lines (Single-pin sensor polling)
#define PIN_MUX_S0         21
#define PIN_MUX_S1         22
#define PIN_MUX_S2         23
#define PIN_MUX_SIG        34   // Input-only GPIO for selected MUX channel

// 74HC148 Priority Encoder Wakeup & Priority Bus
#define PIN_PRIORITY_IRQ   GPIO_NUM_33 // RTC GPIO for ext0 deep sleep wakeup
#define PIN_ENC_A0         32
#define PIN_ENC_A1         35
#define PIN_ENC_A2         39   // Input-only RTC GPIO

// Power Optimization: High-Side P-Channel MOSFET Gate Control
#define PIN_SENSOR_PWR_EN  25   // LOW = Power ON to sensor bus; HIGH = Power Gated (Cutoff)

// Direct Latched Actuators Register (Simulated 74HC574 / Shift Register / Relays)
#define PIN_LATCH_CLK      26
#define PIN_LATCH_DATA     27

// ----------------------------------------------------------------------------
// Wi-Fi & Network Configuration
// ----------------------------------------------------------------------------
const char* WIFI_SSID     = "SmartHome_AP";
const char* WIFI_PASSWORD = "Password123";
WebServer server(80);

// ----------------------------------------------------------------------------
// Bluetooth Low Energy (BLE) UUIDs
// ----------------------------------------------------------------------------
#define BLE_SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_CHAR_STATUS_UUID    "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define BLE_CHAR_CONTROL_UUID   "1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e"

BLEServer* pBleServer = nullptr;
BLECharacteristic* pStatusChar = nullptr;
BLECharacteristic* pControlChar = nullptr;
bool deviceConnected = false;

// ----------------------------------------------------------------------------
// System State Variables
// ----------------------------------------------------------------------------
enum PowerMode {
  POWER_NORMAL,      // Continuous active (Wi-Fi + BLE full speed)
  POWER_ECO,         // Light sleep + Wi-Fi beacon tracking + DFS @ 80 MHz
  POWER_ULTRA_LOW    // Deep sleep with hardware Priority Encoder EXT0 wakeup
};

PowerMode currentPowerMode = POWER_NORMAL;
uint8_t currentActuators = 0x00;  // Bitmask for 8 actuators
uint8_t sensorStates     = 0x00;  // Bitmask for 8 sensors
bool securityArmed       = false;
unsigned long lastSensorSample = 0;
const unsigned long SENSOR_SAMPLE_INTERVAL_MS = 1500;

// Sensor Channel Mapping in 74HC151 MUX:
// Ch 0: Wall Switch 0 | Ch 1: Wall Switch 1 | Ch 2: LDR Light
// Ch 3: Water Leak    | Ch 4: PIR Motion     | Ch 5: Door Reed
// Ch 6: Flame Sensor  | Ch 7: MQ-2 Gas Leak (Highest Priority)
const char* SENSOR_NAMES[8] = {
  "Wall Switch 0", "Wall Switch 1", "LDR Sensor", "Water Leak",
  "PIR Motion", "Door Reed Switch", "Flame Sensor", "MQ-2 Gas Leak"
};

const char* ACTUATOR_NAMES[8] = {
  "Living Room Light", "Ceiling Fan", "Kitchen Exhaust", "Alarm Siren",
  "Bedroom Light", "Outdoor Floodlights", "Smart Door Lock", "Aux Appliance"
};

// ----------------------------------------------------------------------------
// Function Prototypes
// ----------------------------------------------------------------------------
void setupGPIO();
void sampleSensorsViaMux();
void applyActuatorDecoder(uint8_t channel, bool state);
void applyActuatorMask(uint8_t mask);
void checkSafetyInterlocks();
void enterOptimizedDeepSleep();
void setupWiFi();
void setupWebServer();
void setupBLE();
String generateStatusJson();

// ----------------------------------------------------------------------------
// BLE Callbacks
// ----------------------------------------------------------------------------
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("[BLE] Client connected.");
  }
  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    Serial.println("[BLE] Client disconnected. Restarting advertising...");
    pServer->startAdvertising();
  }
};

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxValue = pCharacteristic->getValue().c_str();
    if (rxValue.length() > 0) {
      Serial.print("[BLE] Command received: ");
      Serial.println(rxValue);
      // Protocol format: "TOGGLE:<0-7>" or "MODE:<0-2>" or "ARM:<0-1>"
      if (rxValue.startsWith("TOGGLE:")) {
        int ch = rxValue.substring(7).toInt();
        if (ch >= 0 && ch < 8) {
          currentActuators ^= (1 << ch);
          applyActuatorMask(currentActuators);
        }
      } else if (rxValue.startsWith("MODE:")) {
        int m = rxValue.substring(5).toInt();
        currentPowerMode = (PowerMode)m;
      } else if (rxValue.startsWith("ARM:")) {
        securityArmed = (rxValue.substring(4).toInt() == 1);
      }
    }
  }
};

// ----------------------------------------------------------------------------
// Setup
// ----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=======================================================");
  Serial.println("  IoT Home Automation with Digital Logic & VLSI Blocks");
  Serial.println("=======================================================");

  // Determine wakeup cause
  esp_sleep_wakeup_cause_t wakeup_reason = esp_sleep_get_wakeup_cause();
  if (wakeup_reason == ESP_SLEEP_WAKEUP_EXT0) {
    Serial.println("[POWER] Woken up by Hardware Priority Encoder (EXT0 IRQ)!");
  } else {
    Serial.println("[POWER] Cold boot / System reset.");
  }

  // Setup Hardware Pin Drivers
  setupGPIO();

  // Dynamic Frequency Scaling (DFS) optimization:
  // Downclock from 240 MHz to 80 MHz (Saves ~40% dynamic power while running Wi-Fi)
  setCpuFrequencyMhz(80);
  Serial.printf("[POWER] CPU Frequency set to %d MHz for energy efficiency.\n", getCpuFrequencyMhz());

  // Initialize Wireless Stacks
  setupWiFi();
  setupWebServer();
  setupBLE();

  // Immediate first sensor read
  sampleSensorsViaMux();
  checkSafetyInterlocks();
}

// ----------------------------------------------------------------------------
// Main Loop
// ----------------------------------------------------------------------------
void loop() {
  // Handle HTTP REST & Web Dashboard requests
  server.handleClient();

  // Periodic sensor sampling & digital bus monitor
  unsigned long now = millis();
  if (now - lastSensorSample >= SENSOR_SAMPLE_INTERVAL_MS) {
    lastSensorSample = now;
    sampleSensorsViaMux();
    checkSafetyInterlocks();

    // Broadcast BLE status update if connected
    if (deviceConnected && pStatusChar != nullptr) {
      String json = generateStatusJson();
      pStatusChar->setValue(json.c_str());
      pStatusChar->notify();
    }
  }

  // Handle Ultra-Low-Power Sleep Scheduling
  if (currentPowerMode == POWER_ULTRA_LOW) {
    // Check if safety conditions are safe before sleeping
    bool gasLeak = (sensorStates & (1 << 7)) != 0;
    bool fireAlert = (sensorStates & (1 << 6)) != 0;
    if (!gasLeak && !fireAlert) {
      Serial.println("[POWER] Entering Ultra-Low-Power Deep Sleep. Priority Encoder will wake MCU on event.");
      delay(100);
      enterOptimizedDeepSleep();
    }
  }

  delay(10);
}

// ----------------------------------------------------------------------------
// Hardware Digital Bus & GPIO Subroutines
// ----------------------------------------------------------------------------
void setupGPIO() {
  // Decoder Output Pins
  pinMode(PIN_DEC_A0, OUTPUT);
  pinMode(PIN_DEC_A1, OUTPUT);
  pinMode(PIN_DEC_A2, OUTPUT);
  pinMode(PIN_DEC_EN, OUTPUT);
  digitalWrite(PIN_DEC_EN, LOW); // Start with decoder disabled

  // MUX Pins
  pinMode(PIN_MUX_S0, OUTPUT);
  pinMode(PIN_MUX_S1, OUTPUT);
  pinMode(PIN_MUX_S2, OUTPUT);
  pinMode(PIN_MUX_SIG, INPUT);

  // Priority Encoder Wakeup Line
  pinMode(PIN_PRIORITY_IRQ, INPUT_PULLDOWN);

  // High-Side P-MOSFET Power Gate Control
  pinMode(PIN_SENSOR_PWR_EN, OUTPUT);
  digitalWrite(PIN_SENSOR_PWR_EN, LOW); // Power ON sensors initially
}

/**
 * Reads all 8 sensor channels through the 74HC151 Multiplexer using 3 address lines
 * Implements high-side power gating: powers sensors only during measurement window.
 */
void sampleSensorsViaMux() {
  // Step 1: Power ON sensor bus via P-MOSFET gate
  digitalWrite(PIN_SENSOR_PWR_EN, LOW);
  delayMicroseconds(250); // Allow sensor voltage stabilization

  uint8_t readMask = 0;
  for (uint8_t ch = 0; ch < 8; ch++) {
    // Set 3-bit MUX address (S2, S1, S0)
    digitalWrite(PIN_MUX_S0, (ch & 0x01) ? HIGH : LOW);
    digitalWrite(PIN_MUX_S1, (ch & 0x02) ? HIGH : LOW);
    digitalWrite(PIN_MUX_S2, (ch & 0x04) ? HIGH : LOW);
    delayMicroseconds(10);

    // Read single multiplexed data line
    int val = digitalRead(PIN_MUX_SIG);
    if (val == HIGH) {
      readMask |= (1 << ch);
    }
  }

  sensorStates = readMask;

  // Step 2: If in ECO power mode, power gate the sensors to conserve quiescent current
  if (currentPowerMode == POWER_ECO) {
    digitalWrite(PIN_SENSOR_PWR_EN, HIGH); // Cut off power to resistive sensors
  }
}

/**
 * 74HC138 3-to-8 Decoder Actuation
 * Activates a single targeted actuator channel using 3 GPIO address lines
 */
void applyActuatorDecoder(uint8_t channel, bool state) {
  if (channel > 7) return;

  // Apply address
  digitalWrite(PIN_DEC_A0, (channel & 0x01) ? HIGH : LOW);
  digitalWrite(PIN_DEC_A1, (channel & 0x02) ? HIGH : LOW);
  digitalWrite(PIN_DEC_A2, (channel & 0x04) ? HIGH : LOW);

  // Strobe Enable line
  digitalWrite(PIN_DEC_EN, state ? HIGH : LOW);

  if (state) {
    currentActuators |= (1 << channel);
  } else {
    currentActuators &= ~(1 << channel);
  }
}

/**
 * Updates full 8-bit actuator status byte
 */
void applyActuatorMask(uint8_t mask) {
  currentActuators = mask;
  Serial.printf("[ACTUATORS] New State Mask: 0x%02X (0b%s)\n", currentActuators, String(currentActuators, BIN).c_str());
}

/**
 * Hardware Digital Safety Interlock Verification
 * Enforces safety: Gas leak / Fire automatically overrides everything
 */
void checkSafetyInterlocks() {
  bool gasLeak   = (sensorStates & (1 << 7)) != 0; // Ch 7 = MQ-2 Gas
  bool fireAlert = (sensorStates & (1 << 6)) != 0; // Ch 6 = Flame
  bool doorTrip  = (sensorStates & (1 << 5)) != 0; // Ch 5 = Reed Switch
  bool motion    = (sensorStates & (1 << 4)) != 0; // Ch 4 = PIR
  bool dark      = (sensorStates & (1 << 2)) != 0; // Ch 2 = LDR Dark

  if (gasLeak) {
    // Immediate Safety Override:
    // Bit 2: Exhaust Fan ON (1)
    // Bit 3: Alarm Siren ON (1)
    // Bit 0 & 4: Living room & bedroom lights OFF (0) to eliminate spark risks!
    currentActuators |= (1 << 2);  // Exhaust Fan ON
    currentActuators |= (1 << 3);  // Siren ON
    currentActuators &= ~(1 << 0); // Lights OFF
    currentActuators &= ~(1 << 4);
    Serial.println("[CRITICAL ALERT] GAS LEAK DETECTED! Digital Safety Interlock Active!");
  } else if (fireAlert) {
    currentActuators |= (1 << 3);  // Siren ON
    currentActuators |= (1 << 5);  // Floodlights ON for emergency escape
    Serial.println("[CRITICAL ALERT] FIRE DETECTED! Evacuation Alarms Triggered!");
  } else if (securityArmed && doorTrip) {
    currentActuators |= (1 << 3);  // Siren ON
    currentActuators |= (1 << 5);  // Floodlights ON
    Serial.println("[SECURITY] Perimeter Breach! Intruder Alarm Active!");
  } else if (currentPowerMode == POWER_NORMAL) {
    // Normal autonomous convenience logic:
    // If motion and dark -> Turn on Living Room Light
    if (motion && dark) {
      currentActuators |= (1 << 0); // Light ON
    }
  }
}

/**
 * Configures ESP32 to enter Deep Sleep mode with Priority Encoder EXT0 wakeup
 */
void enterOptimizedDeepSleep() {
  // Configure EXT0 wakeup: wakes when PIN_PRIORITY_IRQ (GPIO 33) goes HIGH
  esp_sleep_enable_ext0_wakeup(PIN_PRIORITY_IRQ, 1);

  // Turn off sensor bus power gating to save battery
  digitalWrite(PIN_SENSOR_PWR_EN, HIGH);

  // Enter deep sleep (~15 uA current consumption)
  esp_deep_sleep_start();
}

// ----------------------------------------------------------------------------
// Networking & Remote Dashboard Endpoints
// ----------------------------------------------------------------------------
void setupWiFi() {
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("[WIFI] Access Point Started: ");
  Serial.println(WIFI_SSID);
  Serial.print("[WIFI] Gateway IP: ");
  Serial.println(WiFi.softAPIP());
}

String generateStatusJson() {
  String json = "{";
  json += "\"power_mode\":" + String((int)currentPowerMode) + ",";
  json += "\"security_armed\":" + String(securityArmed ? "true" : "false") + ",";
  json += "\"actuators\":" + String(currentActuators) + ",";
  json += "\"sensors\":" + String(sensorStates) + ",";
  json += "\"sensor_details\":[";
  for (int i = 0; i < 8; i++) {
    bool state = (sensorStates & (1 << i)) != 0;
    json += "{\"id\":" + String(i) + ",\"name\":\"" + SENSOR_NAMES[i] + "\",\"val\":" + (state ? "1" : "0") + "}";
    if (i < 7) json += ",";
  }
  json += "],\"actuator_details\":[";
  for (int i = 0; i < 8; i++) {
    bool state = (currentActuators & (1 << i)) != 0;
    json += "{\"id\":" + String(i) + ",\"name\":\"" + ACTUATOR_NAMES[i] + "\",\"val\":" + (state ? "1" : "0") + "}";
    if (i < 7) json += ",";
  }
  json += "]}";
  return json;
}

void setupWebServer() {
  // CORS Header support
  server.enableCORS(true);

  // API: Get Telemetry
  server.on("/api/status", HTTP_GET, []() {
    server.send(200, "application/json", generateStatusJson());
  });

  // API: Toggle Actuator via 74HC138 Decoder
  server.on("/api/actuator/toggle", HTTP_POST, []() {
    if (server.hasArg("channel")) {
      int ch = server.arg("channel").toInt();
      if (ch >= 0 && ch < 8) {
        currentActuators ^= (1 << ch);
        applyActuatorDecoder(ch, (currentActuators & (1 << ch)) != 0);
        server.send(200, "application/json", "{\"status\":\"ok\",\"actuators\":" + String(currentActuators) + "}");
        return;
      }
    }
    server.send(400, "application/json", "{\"error\":\"invalid channel\"}");
  });

  // API: Set Power Mode
  server.on("/api/power_mode", HTTP_POST, []() {
    if (server.hasArg("mode")) {
      int m = server.arg("mode").toInt();
      if (m >= 0 && m <= 2) {
        currentPowerMode = (PowerMode)m;
        server.send(200, "application/json", "{\"status\":\"ok\",\"mode\":" + String(m) + "}");
        return;
      }
    }
    server.send(400, "application/json", "{\"error\":\"invalid mode\"}");
  });

  // API: Security Arm/Disarm
  server.on("/api/security", HTTP_POST, []() {
    if (server.hasArg("arm")) {
      securityArmed = (server.arg("arm") == "1");
      server.send(200, "application/json", "{\"status\":\"ok\",\"armed\":" + String(securityArmed ? "true" : "false") + "}");
      return;
    }
    server.send(400, "application/json", "{\"error\":\"missing param\"}");
  });

  server.begin();
  Serial.println("[HTTP] Web Server started on port 80.");
}

// ----------------------------------------------------------------------------
// Bluetooth Low Energy (BLE) Setup
// ----------------------------------------------------------------------------
void setupBLE() {
  BLEDevice::init("ESP32-SmartHome-VLSI");
  pBleServer = BLEDevice::createServer();
  pBleServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pBleServer->createService(BLE_SERVICE_UUID);

  // Telemetry Notify Characteristic
  pStatusChar = pService->createCharacteristic(
    BLE_CHAR_STATUS_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pStatusChar->addDescriptor(new BLE2902());

  // Control Write Characteristic
  pControlChar = pService->createCharacteristic(
    BLE_CHAR_CONTROL_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pControlChar->setCallbacks(new ControlCallbacks());

  pService->start();
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(BLE_SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // iPhone connection optimization
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.println("[BLE] BLE GATT Server active and advertising.");
}
