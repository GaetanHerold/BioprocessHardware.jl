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

# Config Manager
export load_control_parameters, save_params_to_json, apply_parameter_defaults!, strip_json_comments

# Telemetry Logger
export init_telemetry_db, insert_params_to_db!, flush_telemetry_to_db!, init_csv_file, append_to_csv

# MCU Serial
export is_measurement_line, parse_mcu_line, format_mcu_actuator_command, send_mcu_command, MCUReading
export detect_windows_com_ports, open_mcu_serial_port

# BioFlo Modbus
export float32_to_bytes, bytes_to_float32, read_bioflo_holding_registers, write_bioflo_holding_register

# Yocto Sensor
export read_yocto_co2, start_yocto_bridge_if_needed

# Numato Relay
export init_numato_port, set_relay_state, read_adc_voltage

# Submodules
export CO2Doser

end # module BioprocessHardware
