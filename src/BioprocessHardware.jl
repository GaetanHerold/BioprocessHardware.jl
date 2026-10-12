module BioprocessHardware

using Dates
using Printf
using Sockets
using SQLite
using DBInterface
using LibSerialPort
using JSON
using JSON3

include("mcu_serial.jl")
include("config_manager.jl")
include("telemetry_logger.jl")
include("bioflo_modbus.jl")
include("yocto_sensor.jl")
include("numato_relay.jl")
include("co2_doser.jl")
using .CO2Doser: CalibratedADC4_20mA, counts_to_mA, mA_to_co2, counts_to_co2, execute_guarded_relay_pwm, run_pwm_cycle
include("solress_serial_driver.jl")
include("voltcraft_dpps.jl")

# Config Manager
export load_control_parameters, save_params_to_json, apply_parameter_defaults!, strip_json_comments

# Telemetry Logger
export init_telemetry_db, insert_params_to_db!, flush_telemetry_to_db!, init_csv_file, append_to_csv

# MCU Serial
export is_measurement_line, parse_mcu_line, format_mcu_actuator_command, send_mcu_command, MCUReading
export detect_windows_com_ports, open_mcu_serial_port

# SOLRESS Serial Driver & Counterpressure MCU
export SOLRESSTelemetry, SolressTelemetry
export SolressSerialDriver, MockSolressMCU
export open_solress_driver, close_solress_driver!
export set_valve_position!, home_valve!, emergency_stop!
export read_telemetry, is_healthy, reconnect_solress_driver!
export solress_crc16, format_solress_packet, parse_solress_packet, detect_solress_ports
export start_mock_mcu!, stop_mock_mcu!, step_simulation!, inject_slip_fault!, inject_overpressure_fault!
export channel_put_drop_oldest!

# BioFlo Modbus
export float32_to_bytes, bytes_to_float32, read_bioflo_holding_registers, write_bioflo_holding_register
export BioFloConn, bioflo_close!, bioflo_read_pvs, bioflo_set_co2_sp!
export start_bioflo_monitor_task!, start_bioflo_pwm_task!
export read_with_timeout, BIOFLO_PUMP_DEFAULT_RPM, BIOFLO_PUMP_CALIBRATION_ML_PER_REV, pump_rpm_to_flow_ml_min, pump_flow_ml_min_to_rpm

# Yocto Sensor
export run_yocto_monitor_task!, restart_yocto_bridge!

# Numato Relay & CO2 Doser
export read_numato_adc, set_numato_relay
export CalibratedADC4_20mA, counts_to_mA, mA_to_co2, counts_to_co2, execute_guarded_relay_pwm, run_pwm_cycle

# Submodules
export CO2Doser

# Voltcraft DPPS Power Supply Driver
export DPPSReading, DPPSDevice, open_dpps, close_dpps!
export read_dpps_telemetry, parse_dpps_telemetry, detect_dpps_ports
export set_dpps_output!, set_dpps_voltage!, set_dpps_current!, query_dpps

end # module BioprocessHardware
