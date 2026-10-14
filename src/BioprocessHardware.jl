module BioprocessHardware

using Dates
using Printf
using Sockets
using SQLite
using DBInterface
using LibSerialPort
using JSON
using JSON3

# Driver core: errors, typed readings, common interface, transports, mocks, logging
include("core/errors.jl")
include("core/readings.jl")
include("core/interface.jl")
include("core/transport.jl")
include("core/safety.jl")
include("core/mock.jl")
include("core/discovery.jl")
include("core/logging.jl")

# Instrument drivers (being ported to the core interface instrument by instrument)
include("instruments/mcu_stream.jl")
using .MCUStream: MCUStreamDevice, open_mcu_stream, close_mcu_stream!,
                  MCUTelemetry, parse_mcu_line, is_measurement_line,
                  format_mcu_actuator_command, detect_windows_com_ports
include("config_manager.jl")
include("telemetry_logger.jl")
include("instruments/bioflo_modbus.jl")
using .BioFloModbus: BioFloConn, BioFloDevice, open_bioflo, close_bioflo!,
                     float32_to_bytes, bytes_to_float32, read_float_register, write_float_register,
                     bioflo_close!, read_bioflo_measurements,
                     run_bioflo_monitor_task!, run_bioflo_pwm_task!, run_mock_pump2_task!,
                     read_with_timeout, BIOFLO_PUMP_DEFAULT_RPM, BIOFLO_PUMP_CALIBRATION_ML_PER_REV,
                     pump_rpm_to_flow_ml_min, pump_flow_ml_min_to_rpm,
                     REG_TEMP, REG_PH, REG_DCO2, REG_PUMP1, REG_PUMP2, REG_PUMP3,
                     ModbusException, ModbusTimeout
include("instruments/yocto_4_20ma.jl")
using .Yocto4to20mA: YoctoDevice, open_yocto, close_yocto!,
                     run_yocto_monitor_task!, restart_yocto_bridge!
include("loops/slow_pwm.jl")
using .SlowPWM: compute_pwm_times, execute_guarded_pwm, RelayWearTracker, record_switch!
include("loops/adc_4_20ma.jl")
using .ADC4_20mA
include("instruments/numato.jl")
using .Numato: NumatoDevice, open_numato, close_numato!, read_numato_adc, set_numato_relay, read_adc, set_relay!
include("co2_doser.jl")
using .CO2Doser: CalibratedADC4_20mA, counts_to_mA, mA_to_co2, counts_to_co2, execute_guarded_relay_pwm, run_pwm_cycle
include("instruments/solress.jl")
using .Solress: SOLRESSTelemetry, SolressTelemetry,
                SolressSerialDriver, SolressDevice, MockSolressMCU,
                open_solress_driver, close_solress_driver!, open_solress, close_solress!,
                set_valve_position!, home_valve!, emergency_stop!,
                read_telemetry, is_healthy, reconnect_solress_driver!,
                solress_crc16, format_solress_packet, parse_solress_packet, detect_solress_ports,
                start_mock_mcu!, stop_mock_mcu!, step_simulation!, inject_slip_fault!, inject_overpressure_fault!,
                channel_put_drop_oldest!
include("instruments/voltcraft_dpps.jl")
using .VoltcraftDPPS: DPPSReading, DPPSDevice, open_dpps, close_dpps!,
                      read_dpps_telemetry, parse_dpps_telemetry, detect_dpps_ports,
                      set_dpps_output!, set_dpps_voltage!, set_dpps_current!, query_dpps

# --- Driver core (stable 0.2 interface) ---------------------------------------
# Errors
export DeviceError, DeviceTimeout, DeviceProtocolError, DeviceFault, DeviceNotConnected
# Readings
export Reading, ReadingStatus, STATUS_OK, STATUS_STALE, STATUS_OVERRANGE, STATUS_UNDERRANGE, STATUS_FAULT
export DeviceInfo, fault_reading, with_units
# Interface
export AbstractDevice, AbstractSensor, AbstractActuator
export Health, HealthLevel, HEALTH_OK, HEALTH_DEGRADED, HEALTH_FAULT, ishealthy
export SetpointResult, isconnected, identify, healthcheck, read_measurement, write_setpoint!
export safe_state!, close_device!, with_device
# Transports
export AbstractTransport, SerialTransport, MockTransport, inject!
export write_bytes!, bytes_ready, read_ready, flush_input!, close!, read_until, read_line, read_for
# Safety, mocks, discovery, logging
export verified_write, RateLimiter, ready!
export MockSensor, MockActuator, fail_next!, set_status!, drop_writes!
export list_serial_ports, probe_ports, find_unique_port
export log_device, write_log_header

# --- Legacy flat API (kept until each instrument is ported) -------------------
# Config Manager
export load_control_parameters, save_params_to_json, apply_parameter_defaults!

# Telemetry Logger
export init_telemetry_db, insert_params_to_db!, flush_telemetry_to_db!, init_csv_file

# MCU Serial Stream
export is_measurement_line, parse_mcu_line, format_mcu_actuator_command, MCUTelemetry
export detect_windows_com_ports
export MCUStreamDevice, open_mcu_stream, close_mcu_stream!

# SOLRESS Serial Driver & Counterpressure MCU
export SOLRESSTelemetry, SolressTelemetry
export SolressSerialDriver, SolressDevice, MockSolressMCU
export open_solress_driver, close_solress_driver!, open_solress, close_solress!
export set_valve_position!, home_valve!, emergency_stop!
export read_telemetry, is_healthy, reconnect_solress_driver!
export solress_crc16, format_solress_packet, parse_solress_packet, detect_solress_ports
export start_mock_mcu!, stop_mock_mcu!, step_simulation!, inject_slip_fault!, inject_overpressure_fault!
export channel_put_drop_oldest!

# BioFlo Modbus
export float32_to_bytes, bytes_to_float32, read_float_register, write_float_register
export BioFloConn, BioFloDevice, open_bioflo, close_bioflo!, bioflo_close!, read_bioflo_measurements
export run_bioflo_monitor_task!, run_bioflo_pwm_task!, run_mock_pump2_task!
export read_with_timeout, BIOFLO_PUMP_DEFAULT_RPM, BIOFLO_PUMP_CALIBRATION_ML_PER_REV, pump_rpm_to_flow_ml_min, pump_flow_ml_min_to_rpm
export REG_TEMP, REG_PH, REG_DCO2, REG_PUMP1, REG_PUMP2, REG_PUMP3
export ModbusException, ModbusTimeout

# Yocto Sensor
export run_yocto_monitor_task!, restart_yocto_bridge!
export YoctoDevice, open_yocto, close_yocto!

# Numato Relay & CO2 Doser
export NumatoDevice, open_numato, close_numato!
export read_numato_adc, set_numato_relay, read_adc, set_relay!
export RelayWearTracker, record_switch!
export CalibratedADC4_20mA, counts_to_mA, mA_to_co2, counts_to_co2, execute_guarded_relay_pwm, run_pwm_cycle

# Submodules
export CO2Doser, VoltcraftDPPS, Numato, SlowPWM, ADC4_20mA, MCUStream, Solress, BioFloModbus, Yocto4to20mA

# Voltcraft DPPS Power Supply Driver
export DPPSReading, DPPSDevice, open_dpps, close_dpps!
export read_dpps_telemetry, parse_dpps_telemetry, detect_dpps_ports
export set_dpps_output!, set_dpps_voltage!, set_dpps_current!, query_dpps

end # module BioprocessHardware
