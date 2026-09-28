# BioprocessHardware.jl

**BioprocessHardware.jl** is the Hardware Abstraction Layer (HAL) and I/O communication engine for pilot-scale bioreactors and electrodialysis systems.

---

## Supported hardware and modules

| Module | Protocol / Interface | Target Hardware | Description |
| :--- | :--- | :--- | :--- |
| `MCUSerial` | USB Serial (115200 baud) | ESP32-S3 Microcontroller | 30-field ASCII telemetry decoding, `PC,...` setpoint command formatter |
| `BioFloModbus` | Modbus TCP (Port 502) | Eppendorf BioFlo 120 / 320 | Float32 Big-Endian holding registers, PV reading, SP writing |
| `YoctoSensor` | TCP Socket Daemon Bridge | Yoctopuce 4-20mA Sensor Bridge | Continuous current loop monitoring for dissolved $\text{CO}_2$ probe |
| `NumatoRelay` | USB Serial CDC | Numato 1-Channel USB Relay | Optical/mechanical relay control and 10-bit ADC voltage reading |
| `TelemetryLogger` | SQLite (WAL) & CSV | SQLite3 / Flat CSV | High-throughput telemetry batching, crash recovery, metadata tagging |
| `ConfigManager` | JSON / Comments / PnP | System Configuration | Dynamic Windows COM anti-swapping, atomic defaults injection |
| `CO2Doser` | USB Serial + Relay | Standalone $\text{CO}_2$ Dosing Rig | Two-point calibration and low-frequency PWM gas valve cycling |

---

## Installation

```julia
using Pkg
Pkg.develop(path="packages/BioprocessHardware.jl")
```

---

## Quick example

### 1. MCU telemetry parsing and command formatting

```julia
using BioprocessHardware

# Parse live 30-field telemetry frame from ESP32
line = "2026-08-25 14:00:00,7.15,7.35,0.2,0.0,0.0,0.0,0.0,0.0,25.4,15.0,45.0,20.0,0.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
reading = parse_mcu_line(line, true)

println("Fermenter pH: ", reading.pH_ferm)
println("Extraction pH: ", reading.pH_extr)

# Format command to MCU (Current = 3.5 A, CO2 = 50 %, Pump = 60 %)
cmd = format_mcu_actuator_command(3.5, 50.0, 60.0)
println("Formatted Command: ", repr(cmd))
```

### 2. High-throughput SQLite WAL logging

```julia
using BioprocessHardware
using SQLite

# Initialize experiment telemetry database
db_path = "experiments/Lab_Experiments.sqlite"
exp_id = "test_hardware_run"
(db, log_stmt) = init_telemetry_db(db_path, exp_id, false)

# Store active control parameters
insert_params_to_db!(db, exp_id, Dict("target_pH" => 6.2, "Kp" => 0.1), "initial")
println("Telemetry database initialized with WAL journaling.")
```

---

## Operational boundaries and hardware deployment status (DOC3_HW)

### 1. Actuator deployment modes and physical plant architecture
The LUCRA pilot plant supports three distinct actuation pathways configurable via `control_parameters.json` (`co2_actuation_mode`):

1. **`"mcu"` (Primary Active Pilot Plant Mode)**:
   - Closed-loop gas sparging, current dosing, and recirculation pumping are coordinated through the **ESP32-S3 microcontroller** serial interface (`MCUSerial`, `/dev/ttyACM0` at 115200 baud).
   - Formatted ASCII commands (`PC,<current_A>,<co2_sp>,<pump_sp>\r`) command high-speed digital drivers and solid-state actuators directly.
2. **`"local_pwm"` (Auxiliary / Bench Standalone Testing Mode)**:
   - Uses the **Numato Lab USB 1-Channel Relay Module** (`NumatoRelay` / `CO2Doser`) as an auxiliary standalone rig or offline gas bench test unit.
   - Mechanical relay switches the solenoid gas valve via low-frequency slow PWM.
3. **`"bioflo_pwm"` (BioFlo Modbus TCP Mode)**:
   - Commands peristaltic Pumps 1 and 3 on Eppendorf BioFlo 120 / 320 controllers via Modbus TCP holding registers 76 and 80.

> **Operator Precaution**: On the active pilot fermentation facility, ensure `co2_actuation_mode = "mcu"` is set. The Numato USB relay module is intended for auxiliary bench testing and standalone gas dosing rigs.

---

### 2. Mechanical relay dwell time constraints and anti-chatter protection (Finding F27)
Mechanical relays (e.g., Numato Lab USB relay) have a rated contact endurance of $\sim 10^5$ operations under load and are susceptible to arc erosion and contact bounce during rapid switching:

- Enforce a minimum dwell time of **$t_{\text{on}} \ge 1.0\text{ s}$** and **$t_{\text{off}} \ge 1.0\text{ s}$** in `compute_pwm_times`, `execute_guarded_relay_pwm`, and `run_pwm_cycle`.
- Suppress pulses below the minimum dwell ($t_{\text{on}} < 1.0\text{ s}$) to $0.0\text{ s}$, keeping the relay continuously off to prevent chatter.
- Clamp to continuous full-on ($t_{\text{on}} = t_{\text{window}}$, $t_{\text{off}} = 0.0\text{ s}$, relay remains continuous on) whenever the computed off-time violates the minimum dwell ($t_{\text{off}} < 1.0\text{ s}$).
- Enforce these hardware limits strictly; passing `min_on_s = 0.0` or `min_off_s = 0.0` does not bypass the dwell bound ($\max(t_{\text{dwell}}, 1.0\text{ s})$).

| Duty Cycle ($t_{\text{window}} = 10.0\text{ s}$) | Raw $t_{\text{on}}$ | Guarded $t_{\text{on}}$ | Guarded $t_{\text{off}}$ | Relay Contact State |
| :--- | :--- | :--- | :--- | :--- |
| $0.0\%$ | $0.0\text{ s}$ | $0.0\text{ s}$ | $10.0\text{ s}$ | Continuous OFF |
| $0.5\%$ | $0.05\text{ s}$ | $0.0\text{ s}$ | $10.0\text{ s}$ | Suppressed (Chatter Prevention) |
| $5.0\%$ | $0.50\text{ s}$ | $0.0\text{ s}$ | $10.0\text{ s}$ | Suppressed (Chatter Prevention) |
| $10.0\%$ | $1.00\text{ s}$ | $1.00\text{ s}$ | $9.00\text{ s}$ | Modulated Pulse |
| $50.0\%$ | $5.00\text{ s}$ | $5.00\text{ s}$ | $5.00\text{ s}$ | Modulated Pulse |
| $90.0\%$ | $9.00\text{ s}$ | $9.00\text{ s}$ | $1.00\text{ s}$ | Modulated Pulse |
| $95.0\%$ | $9.50\text{ s}$ | $10.00\text{ s}$ | $0.00\text{ s}$ | Clamped to Full-ON |
| $100.0\%$ | $10.00\text{ s}$ | $10.00\text{ s}$ | $0.00\text{ s}$ | Continuous ON |

---

### 3. Burden resistor ADC saturation limits and calibration (Finding F26)
The Numato Lab ADC module uses a 10-bit Successive Approximation Register (SAR) ADC referenced to the USB 5.0 V rail ($V_{\text{ref}} = 5.000\text{ V}$, $0 - 1023\text{ counts}$). A $4 - 20\text{ mA}$ industrial current loop is terminated across an on-board $R_{\text{burden}} = 263.0\,\Omega$ resistor:

#### Circuit analysis and saturation boundary
- Input voltage to ADC:
  $$V_{\text{in}} = I \times R_{\text{burden}}$$
- At $I = 4.0\text{ mA}$:
  $$V_{\text{in}} = 0.004\text{ A} \times 263.0\,\Omega = 1.052\text{ V} \implies \text{Counts} = \frac{1.052}{5.0} \times 1023 = 215.35\text{ counts}$$
- At $I = 20.0\text{ mA}$:
  $$V_{\text{in}} = 0.020\text{ A} \times 263.0\,\Omega = 5.260\text{ V} > 5.000\text{ V}$$

Because the rail reference is strictly $5.000\text{ V}$, the ADC saturates at maximum counts ($1023\text{ counts}$) at current:
$$I_{\text{sat}} = \frac{V_{\text{ref}}}{R_{\text{burden}}} = \frac{5.000\text{ V}}{263.0\,\Omega} = \mathbf{19.011\text{ mA}}$$

- Clipped span: the upper $6.18\%$ of the sensor current span ($19.01\text{ to } 20.00\text{ mA}$) cannot be digitized and is clipped to 1023 counts.
- Runtime saturation guard: in `counts_to_mA(adc, counts)`, a defensive `@warn "ADC input saturated!"` assertion is triggered whenever counts reach $\ge 1023.0$, alerting the operator to over-ranging.
- Hardware upgrade recommendation: to measure the full $4 - 20\text{ mA}$ range up to 20.0 mA without saturation ($V_{\text{in}} \le 4.98\text{ V} < 5.0\text{ V}$), replace the $263\,\Omega$ resistor with a standard precision $249.0\,\Omega \pm 0.1\%$ burden resistor.

#### Conversion formulas
- Current from counts:
  $$I\,[\text{mA}] = \left(\frac{\text{counts}}{1023.0}\right) \times \frac{V_{\text{ref}}}{R_{\text{burden}}} \times 1000.0$$
- Linear dissolved $\text{CO}_2$ concentration:
  $$\text{CO}_2\,[\%] = \left(\frac{I\,[\text{mA}] - 4.0}{16.0}\right) \times 100.0\%$$
  (At saturation $1023\text{ counts}$, $\text{CO}_2 = 93.82\%$).

---

### 4. BioFlo Modbus TCP frame handling and pump actuator scaling (Findings F28, F29)

#### Packet fragmentation protection (F28)
- Modbus TCP frames across Ethernet or Wi-Fi can fragment into multiple TCP segments.
- `read_with_timeout(socket, n_bytes, timeout_s)` accumulates packet segments until exactly `n_bytes` are received.
- If a connection closes prematurely before all header (9 bytes) or body bytes arrive, the buffer is strictly truncated to actual bytes read, preventing uninitialized memory (`undef`) from corrupting downstream IEEE 754 Big-Endian `Float32` decoding.

#### Pump actuator calibration and traceability (F29)
- Holding registers 76 and 80 set the rotational speed setpoint [rpm] for BioFlo peristaltic Pumps 1 and 3 (Watson-Marlow 114DV heads).
- With standard Masterflex #16 silicone tubing (inner diameter 3.1 mm), the nominal displacement factor is $k_{\text{pump}} \approx 1.00\text{ mL/(min}\cdot\text{rpm)}$:
  $$Q_{\text{pump}}\,[\text{mL/min}] = k_{\text{pump}} \times \omega_{\text{pump}}\,[\text{rpm}]$$
- The default pump command `Float32(18.8)` (`BIOFLO_PUMP_DEFAULT_RPM`) corresponds to $18.8\text{ rpm} = 18.8\text{ mL/min} = 0.3133\text{ mL/s}$, matching the dosing rate parameter `co2_pump_dosing_rate = 18.8 / 60.0` in `BioprocessControl.jl` and `src/types.jl`.

---

## Project context and affiliations

Developed by **Gaétan Herold** in the framework of the European Union Horizon project **[LUCRA](https://lucra-project.eu)** (*Converting bio-waste into bio-based products for a sustainable chemical industry*).

### Academic affiliations:
- **[Traslab](https://www.traslab.ugent.be/)** & **[BioMath](https://biomath.ugent.be/)**, Department of Data Analysis and Mathematical Modelling, Ghent University (UGent), Ghent, Belgium
- **[modelEAU](https://modeleau.fsg.ulaval.ca/)**, Département de génie civil et de génie des eaux, Université Laval (ULaval), Québec, Canada

