/**
 * ============================================================================
 * SmartHome VLSI - Dashboard Client & Bluetooth Controller
 * Features:
 *   - Real-time ESP32 REST API polling & synchronization
 *   - Web Bluetooth API (BLE) Direct Connection & Control
 *   - Hardware Emergency Interlock Visualizer
 *   - Interactive Standalone Demo Mode
 * ============================================================================
 */

// Configuration
const CONFIG = {
  apiBase: window.location.origin.includes('http') ? window.location.origin : 'http://192.168.4.1',
  pollIntervalMs: 2000,
  bleServiceUuid: '4fafc201-1fb5-459e-8fcc-c5c9c331914b',
  bleControlCharUuid: '1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e',
  bleStatusCharUuid: 'beb5483e-36e1-4688-b7f5-ea07361b26a8'
};

// Actuators metadata (Decoded via 74HC138)
const ACTUATORS = [
  { id: 0, addr: '000', name: 'Living Room Light', powerW: 15, state: false },
  { id: 1, addr: '001', name: 'Ceiling Fan', powerW: 65, state: true },
  { id: 2, addr: '010', name: 'Kitchen Exhaust', powerW: 80, state: false },
  { id: 3, addr: '011', name: 'Alarm Siren / Buzzer', powerW: 10, state: false },
  { id: 4, addr: '100', name: 'Bedroom Lights', powerW: 20, state: false },
  { id: 5, addr: '101', name: 'Security Floodlights', powerW: 100, state: false },
  { id: 6, addr: '110', name: 'Smart Door Lock', powerW: 12, state: false },
  { id: 7, addr: '111', name: 'Aux Outlet / Pump', powerW: 150, state: false }
];

// Sensors metadata (Multiplexed via 74HC151)
const SENSORS = [
  { id: 0, ch: 'CH0', name: 'Wall Switch 0', prio: 0, critical: false, triggered: false },
  { id: 1, ch: 'CH1', name: 'Wall Switch 1', prio: 1, critical: false, triggered: false },
  { id: 2, ch: 'CH2', name: 'LDR Day/Night', prio: 2, critical: false, triggered: true },
  { id: 3, ch: 'CH3', name: 'Water Leak Sensor', prio: 3, critical: false, triggered: false },
  { id: 4, ch: 'CH4', name: 'PIR Motion Sensor', prio: 4, critical: false, triggered: true },
  { id: 5, ch: 'CH5', name: 'Door Reed Switch', prio: 5, critical: false, triggered: false },
  { id: 6, ch: 'CH6', name: 'Flame Sensor', prio: 6, critical: true, triggered: false },
  { id: 7, ch: 'CH7', name: 'MQ-2 Gas Leak', prio: 7, critical: true, triggered: false }
];

// App State
let appState = {
  powerMode: 1, // 0 = Normal, 1 = Eco, 2 = Deep Sleep
  securityArmed: false,
  demoMode: true,
  bleConnected: false,
  bleDevice: null,
  bleControlChar: null
};

// ----------------------------------------------------------------------------
// Initialization
// ----------------------------------------------------------------------------
document.addEventListener('DOMContentLoaded', () => {
  renderActuators();
  renderSensors();
  setupEventListeners();
  updateMetrics();

  // Attempt initial network sync
  fetchStatus();
  setInterval(fetchStatus, CONFIG.pollIntervalMs);
});

// ----------------------------------------------------------------------------
// Rendering Routines
// ----------------------------------------------------------------------------
function renderActuators() {
  const container = document.getElementById('actuatorGrid');
  container.innerHTML = '';

  ACTUATORS.forEach(act => {
    const card = document.createElement('div');
    card.className = `actuator-card ${act.state ? 'active' : ''}`;
    card.id = `actCard_${act.id}`;

    // Gas Emergency Lockout styling
    const gasLeak = SENSORS[7].triggered;
    if (gasLeak && (act.id === 0 || act.id === 4)) {
      card.classList.add('emergency-lock');
    }

    card.innerHTML = `
      <div class="actuator-info">
        <span class="actuator-addr">74HC138 ADDR: 0b${act.addr}</span>
        <span class="actuator-name">${act.name}</span>
        <span class="actuator-meta">${act.powerW}W Load &bull; Relay #${act.id}</span>
      </div>
      <label class="switch">
        <input type="checkbox" id="toggle_${act.id}" ${act.state ? 'checked' : ''} ${gasLeak && (act.id === 0 || act.id === 4) ? 'disabled' : ''}>
        <span class="slider"></span>
      </label>
    `;

    container.appendChild(card);

    // Event listener for switch
    const toggle = card.querySelector(`#toggle_${act.id}`);
    toggle.addEventListener('change', (e) => {
      handleActuatorToggle(act.id, e.target.checked);
    });
  });
}

function renderSensors() {
  const container = document.getElementById('sensorList');
  container.innerHTML = '';

  let highestPriority = -1;

  SENSORS.forEach(sensor => {
    if (sensor.triggered && sensor.prio > highestPriority) {
      highestPriority = sensor.prio;
    }

    const row = document.createElement('div');
    row.className = `sensor-row ${sensor.triggered ? (sensor.critical ? 'critical-triggered' : 'triggered') : ''}`;
    row.id = `sensorRow_${sensor.id}`;

    let statusText = sensor.triggered ? (sensor.critical ? 'CRITICAL TRIGGER' : 'ACTIVE') : 'IDLE';
    let statusClass = sensor.triggered ? (sensor.critical ? 'critical' : 'active') : '';

    row.innerHTML = `
      <div class="sensor-col-info">
        <span class="sensor-ch-pill">MUX ${sensor.ch}</span>
        <span class="sensor-name">${sensor.name}</span>
      </div>
      <div style="display:flex; align-items:center; gap:10px;">
        <span class="sensor-status-tag ${statusClass}">${statusText}</span>
        ${appState.demoMode ? `<button class="btn btn-sm trigger-btn" onclick="toggleSensorSim(${sensor.id})">${sensor.triggered ? 'Clear' : 'Trip'}</button>` : ''}
      </div>
    `;

    container.appendChild(row);
  });

  // Update Priority Encoder Display
  const codeEl = document.getElementById('priorityEncoderCode');
  const fillEl = document.getElementById('priorityFill');
  if (highestPriority >= 0) {
    const binCode = highestPriority.toString(2).padStart(3, '0');
    codeEl.textContent = `Code: 0b${binCode} (Pri ${highestPriority}: ${SENSORS[highestPriority].name})`;
    fillEl.style.width = `${((highestPriority + 1) / 8) * 100}%`;
  } else {
    codeEl.textContent = 'Code: 0b000 (Idle Standby)';
    fillEl.style.width = '0%';
  }
}

// ----------------------------------------------------------------------------
// Event Listeners & Mode Selection
// ----------------------------------------------------------------------------
function setupEventListeners() {
  // Power mode option selector
  document.querySelectorAll('.power-mode-option').forEach(el => {
    el.addEventListener('click', () => {
      document.querySelectorAll('.power-mode-option').forEach(c => c.classList.remove('selected'));
      el.classList.add('selected');
      const mode = parseInt(el.getAttribute('data-mode'));
      setPowerMode(mode);
    });
  });

  // All off button
  document.getElementById('allOffBtn').addEventListener('click', () => {
    ACTUATORS.forEach(a => a.state = false);
    renderActuators();
    updateMetrics();
    sendBleCommand('SET:ALL:0');
  });

  // Demo mode toggle
  document.getElementById('simToggleBtn').addEventListener('click', () => {
    appState.demoMode = !appState.demoMode;
    document.getElementById('simToggleBtn').textContent = `Demo Mode: ${appState.demoMode ? 'ON' : 'OFF'}`;
    renderSensors();
  });

  // Web Bluetooth button
  document.getElementById('bleConnectBtn').addEventListener('click', handleBleConnect);
}

// ----------------------------------------------------------------------------
// Actuator Toggling & Hardware Interlocks
// ----------------------------------------------------------------------------
function handleActuatorToggle(channel, isChecked) {
  ACTUATORS[channel].state = isChecked;

  // Visual card update
  const card = document.getElementById(`actCard_${channel}`);
  if (card) {
    card.classList.toggle('active', isChecked);
  }

  updateMetrics();

  // Send to hardware via BLE if connected
  if (appState.bleConnected) {
    sendBleCommand(`TOGGLE:${channel}`);
  }

  // Send to hardware via HTTP REST API
  if (!appState.demoMode) {
    fetch(`${CONFIG.apiBase}/api/actuator/toggle?channel=${channel}`, { method: 'POST' })
      .catch(err => console.warn('HTTP API offline, using local state.', err));
  }
}

// ----------------------------------------------------------------------------
// Simulated Sensor Triggering (Demonstrating Hardware Digital Interlock)
// ----------------------------------------------------------------------------
window.toggleSensorSim = function(sensorId) {
  SENSORS[sensorId].triggered = !SENSORS[sensorId].triggered;

  // Safety Critical Interlock: Gas Leak (Ch 7)
  if (sensorId === 7) {
    if (SENSORS[7].triggered) {
      // Hardware failsafe: Instantly trip Exhaust Fan (Ch 2) & Siren (Ch 3),
      // cut Lights (Ch 0, Ch 4) to eliminate electrical contact arc risk!
      ACTUATORS[2].state = true;  // Exhaust Fan ON
      ACTUATORS[3].state = true;  // Siren ON
      ACTUATORS[0].state = false; // Light OFF
      ACTUATORS[4].state = false; // Bedroom Light OFF
    } else {
      ACTUATORS[3].state = false; // Siren OFF
    }
  }

  // Safety Critical Interlock: Flame Sensor (Ch 6)
  if (sensorId === 6) {
    if (SENSORS[6].triggered) {
      ACTUATORS[3].state = true; // Siren ON
      ACTUATORS[5].state = true; // Outdoor floodlights ON
    } else {
      ACTUATORS[3].state = false;
    }
  }

  // Autonomous Night Motion Automation (PIR=4, LDR=2)
  if (sensorId === 4 || sensorId === 2) {
    if (SENSORS[4].triggered && SENSORS[2].triggered && !SENSORS[7].triggered) {
      ACTUATORS[0].state = true; // Night motion detected -> Auto turn ON Living room light
    }
  }

  renderActuators();
  renderSensors();
  updateMetrics();
};

// ----------------------------------------------------------------------------
// Metrics & Power Calculation Updates
// ----------------------------------------------------------------------------
function updateMetrics() {
  // Calculate total power
  let activeCount = 0;
  let totalWatts = 0;
  ACTUATORS.forEach(a => {
    if (a.state) {
      activeCount++;
      totalWatts += a.powerW;
    }
  });

  document.getElementById('activeLoadCount').textContent = `${activeCount} / 8 Active`;
  document.getElementById('estimatedPower').textContent = `${totalWatts.toFixed(1)} W`;

  // Safety Status
  const gasLeak = SENSORS[7].triggered;
  const fireAlert = SENSORS[6].triggered;
  const safetyBadge = document.getElementById('safetyStatusBadge');
  const safetyText = document.getElementById('safetyStatusText');

  if (gasLeak) {
    safetyBadge.className = 'chip chip-purple';
    safetyBadge.style.background = 'rgba(244, 63, 94, 0.25)';
    safetyBadge.style.color = '#fb7185';
    safetyBadge.textContent = 'GAS EMERGENCY';
    safetyText.className = 'metric-value text-rose';
    safetyText.style.color = '#f43f5e';
    safetyText.textContent = 'Exhaust Active';
  } else if (fireAlert) {
    safetyBadge.textContent = 'FIRE ALERT';
    safetyText.textContent = 'Evacuate!';
  } else {
    safetyBadge.className = 'chip chip-emerald';
    safetyBadge.style.background = '';
    safetyBadge.style.color = '';
    safetyBadge.textContent = 'All Secure';
    safetyText.className = 'metric-value text-emerald';
    safetyText.textContent = 'Normal';
  }
}

function setPowerMode(mode) {
  appState.powerMode = mode;
  const badge = document.getElementById('powerModeBadge');
  const savings = document.getElementById('powerSavingMetric');

  if (mode === 0) {
    badge.textContent = 'Normal Active';
    badge.className = 'chip chip-blue';
    savings.textContent = 'Baseline (160mA)';
  } else if (mode === 1) {
    badge.textContent = 'ECO Mode';
    badge.className = 'chip chip-green';
    savings.textContent = '95.3% Saved';
  } else if (mode === 2) {
    badge.textContent = 'Ultra Deep Sleep';
    badge.className = 'chip chip-purple';
    savings.textContent = '99.9% Saved (15µA)';
  }

  if (appState.bleConnected) {
    sendBleCommand(`MODE:${mode}`);
  }

  if (!appState.demoMode) {
    fetch(`${CONFIG.apiBase}/api/power_mode?mode=${mode}`, { method: 'POST' }).catch(() => {});
  }
}

// ----------------------------------------------------------------------------
// REST API Network Synchronization
// ----------------------------------------------------------------------------
async function fetchStatus() {
  if (appState.demoMode) return;

  try {
    const res = await fetch(`${CONFIG.apiBase}/api/status`);
    if (res.ok) {
      const data = await res.json();
      document.getElementById('wifiStatus').innerHTML = `
        <span class="status-dot online"></span>
        <span>Wi-Fi: Connected (AP)</span>
      `;
      // Update actuator & sensor masks
      for (let i = 0; i < 8; i++) {
        ACTUATORS[i].state = (data.actuators & (1 << i)) !== 0;
        SENSORS[i].triggered = (data.sensors & (1 << i)) !== 0;
      }
      renderActuators();
      renderSensors();
      updateMetrics();
    }
  } catch (e) {
    // Hardware unreachable, stay in demo fallback
  }
}

// ----------------------------------------------------------------------------
// Web Bluetooth API Integration
// ----------------------------------------------------------------------------
async function handleBleConnect() {
  if (!navigator.bluetooth) {
    alert('Web Bluetooth is not supported in this browser. Please use Google Chrome or Microsoft Edge on Desktop/Android.');
    return;
  }

  try {
    const device = await navigator.bluetooth.requestDevice({
      filters: [{ name: 'ESP32-SmartHome-VLSI' }],
      optionalServices: [CONFIG.bleServiceUuid]
    });

    const server = await device.gatt.connect();
    const service = await server.getPrimaryService(CONFIG.bleServiceUuid);
    appState.bleControlChar = await service.getCharacteristic(CONFIG.bleControlCharUuid);
    const statusChar = await service.getCharacteristic(CONFIG.bleStatusCharUuid);

    // Subscribe to notifications
    await statusChar.startNotifications();
    statusChar.addEventListener('characteristicvaluechanged', (e) => {
      const decoder = new TextDecoder('utf-8');
      const val = decoder.decode(e.target.value);
      try {
        const data = JSON.parse(val);
        for (let i = 0; i < 8; i++) {
          ACTUATORS[i].state = (data.actuators & (1 << i)) !== 0;
          SENSORS[i].triggered = (data.sensors & (1 << i)) !== 0;
        }
        renderActuators();
        renderSensors();
        updateMetrics();
      } catch (err) {}
    });

    appState.bleConnected = true;
    appState.bleDevice = device;
    document.getElementById('bleBtnText').textContent = 'BLE: Connected';
    document.getElementById('bleConnectBtn').classList.add('chip-green');
  } catch (err) {
    console.error('BLE connection error:', err);
  }
}

async function sendBleCommand(cmd) {
  if (!appState.bleConnected || !appState.bleControlChar) return;
  try {
    const encoder = new TextEncoder();
    await appState.bleControlChar.writeValue(encoder.encode(cmd));
  } catch (err) {
    console.error('Failed to send BLE command:', err);
  }
}
