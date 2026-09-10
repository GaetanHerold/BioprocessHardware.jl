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
include("solress_serial_driver.jl")

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

# Yocto Sensor
export run_yocto_monitor_task!

# Numato Relay
export read_numato_adc, set_numato_relay

# Submodules
export CO2Doser

end # module BioprocessHardware
