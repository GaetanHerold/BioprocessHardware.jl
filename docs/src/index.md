# BioprocessHardware.jl

*Production Hardware Abstraction Layer (HAL) for Serial MCUs, Modbus TCP Bioreactors, Sensors, and Telemetry Storage.*

---

## 1. Overview

**BioprocessHardware.jl** isolates physical communication protocols from higher-level control algorithms:
- ESP32-S3 serial framing: bidirectional `PC,<current>,<co2>,<pump>\r` packet protocol with timeout detection and watchdog recovery.
- BioFlo 120/320 Modbus TCP driver: polling of process values (pH, agitation, temperature, sparge rates) and Float32 word-swapping.
- Yoctopuce 4-20mA and Numato relays: industrial sensor current loops and USB dosing actuators.
- SQLite WAL telemetry logger: high-throughput time-series recording without controller blocking.

---

## 2. Quick start

```julia
using BioprocessHardware

# Example: format packet for ESP32 MCU
frame = format_actuator_packet(1.25, 20.0, 50.0)
println("Formatted frame: ", strip(frame))

# Example: initialize logger
logger = TelemetryLogger("pilot_run.sqlite")
log_telemetry!(logger, Dict("pH_fermenter" => 6.21, "current_A" => 1.25))
```
