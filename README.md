# BioprocessHardware.jl

**BioprocessHardware.jl** is the Hardware Abstraction Layer (HAL) and I/O communication engine for pilot-scale bioreactors and electrodialysis systems.

---

## Supported Hardware & Modules

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

## Quick Example

### 1. MCU Telemetry Parsing & Command Formatting

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

### 2. High-Throughput SQLite WAL Logging

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

## Project Context & Affiliations

Developed by **Gaétan Herold** in the framework of the European Union Horizon project **[LUCRA](https://lucra-project.eu)** (*Converting bio-waste into bio-based products for a sustainable chemical industry*).

### Academic Affiliations:
- **[Traslab](https://www.traslab.ugent.be/)** & **[BioMath](https://biomath.ugent.be/)** — Department of Data Analysis and Mathematical Modelling, Ghent University (UGent), Ghent, Belgium
- **[modelEAU](https://modeleau.fsg.ulaval.ca/)** — Département de génie civil et de génie des eaux, Université Laval (ULaval), Québec, Canada

