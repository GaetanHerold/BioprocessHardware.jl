# ============================================================================
# MCU SERIAL HARDWARE INTERFACE
# ============================================================================
# Manages serial communication, frame parsing, port detection, and actuator
# command formatting for the standalone ESP32-S3 microcontroller unit.
# ============================================================================

using LibSerialPort
using Dates
using Printf

const WINDOWS_DETECTED_PORTS = Dict{String,String}()

"""
    detect_windows_com_ports()

Query Windows PnP system via PowerShell to dynamically detect and resolve 
the COM ports for ESP32 and Numato USB devices, preventing COM port swapping.
"""
function detect_windows_com_ports()
    if !isempty(WINDOWS_DETECTED_PORTS)
        return WINDOWS_DETECTED_PORTS
    end

    if !Sys.iswindows()
        return WINDOWS_DETECTED_PORTS
    end

    try
        println("[INFO] Querying Windows PnP system for active serial COM ports (Anti-Swapping Mode)...")
        cmd = `powershell -Command "Get-CimInstance Win32_PnPEntity -Filter \"Name like '%(COM%)'\" | ForEach-Object { \$_.Name + '|' + \$_.DeviceID }"`
        output = read(cmd, String)
        
        for line in split(output, '\n')
            line = strip(line)
            if isempty(line) || !contains(line, '|')
                continue
            end
            parts = split(line, '|')
            if length(parts) == 2
                name, device_id = parts[1], parts[2]
                m = match(r"\(COM(\d+)\)", name)
                if !isnothing(m)
                    com_port = "COM" * m.captures[1]
                    if contains(device_id, "VID_2A19&PID_0C05")
                        WINDOWS_DETECTED_PORTS["numato"] = com_port
                        println("[INFO] Dynamic Anti-Swapping: Detected Numato ADC/Relay on $com_port (VID_2A19&PID_0C05)")
                    elseif contains(device_id, "VID_303A&PID_1001")
                        WINDOWS_DETECTED_PORTS["esp32"] = com_port
                        println("[INFO] Dynamic Anti-Swapping: Detected ESP32 MCU on $com_port (VID_303A&PID_1001)")
                    end
                end
            end
        end
    catch e
        @warn "[WARNING] Windows COM port dynamic detection failed, falling back to static config" exception=e
    end
    return WINDOWS_DETECTED_PORTS
end

""" 
    is_measurement_line(line::String)

Check if a line from the MCU contains a valid timestamp (measurement data).
Returns true if line starts with "YYYY-MM-DD HH:MM:SS" pattern.
"""
function is_measurement_line(line::String)
    if length(line) < 19
        return false
    end

    try
        DateTime(line[1:19], "yyyy-mm-dd HH:MM:SS")
        return true
    catch
        return false
    end
end

"""
    struct MCUTelemetry
Container for decoded sensor measurements from the MCU frame.
"""
struct MCUTelemetry
    timestamp::DateTime
    pH_ferm::Float64
    pH_extr::Float64
    ps_voltage::Float64
    current_measured::Float64
    volt_lim::Float64
    curr_control::Float64
    co2_sp_measured::Float64
    pump_sp_measured::Float64
    T_ferm::Float64
    T_extr::Float64
end

"""
    parse_mcu_line(line::String, use_new_unit::Bool=true)

Parse comma-separated telemetry frame received from the MCU:
Format: `DTM,pH1,pH2,PS(V),PS(A),LVL1(%),LVL2(%),LVL3(%),LVL4(%),T(°C),DOS set(%),FLO set(%),lim. volt.(V),fixed curr.(A),...`

Returns `MCUTelemetry` on success, or `nothing` if corrupted/incomplete.
"""
function parse_mcu_line(line::String, use_new_unit::Bool=true)
    parts = split(line, ',')
    if length(parts) < 11 || parts[1] == "DTM"
        return nothing
    end

    try
        timestamp = DateTime(parts[1], "yyyy-mm-dd HH:MM:SS")

        if use_new_unit
            pH_ferm           = parse(Float64, parts[2])   # pH1: Fermenter pH
            pH_extr           = parse(Float64, parts[3])   # pH2: Extraction buffer pH
            ps_voltage        = length(parts) >= 4 ? parse(Float64, parts[4]) : 0.0
            current_meas      = length(parts) >= 5 ? parse(Float64, parts[5]) : 0.0
            T_ferm            = length(parts) >= 10 ? parse(Float64, parts[10]) : 25.0
            T_extr            = T_ferm
            co2_sp_meas       = length(parts) >= 11 ? parse(Float64, parts[11]) : 0.0
            pump_sp_meas      = length(parts) >= 12 ? parse(Float64, parts[12]) : 0.0
            volt_lim          = length(parts) >= 13 ? parse(Float64, parts[13]) : 0.0
            curr_control      = length(parts) >= 14 ? parse(Float64, parts[14]) : 0.0
        else
            # Legacy BioFlo mode
            pH_ferm           = NaN
            pH_extr           = parse(Float64, parts[2])
            ps_voltage        = length(parts) >= 4 ? parse(Float64, parts[4]) : 0.0
            current_meas      = length(parts) >= 5 ? parse(Float64, parts[5]) : 0.0
            T_ferm            = NaN
            T_extr            = length(parts) >= 10 ? parse(Float64, parts[10]) : 25.0
            co2_sp_meas       = length(parts) >= 11 ? parse(Float64, parts[11]) : 0.0
            pump_sp_meas      = length(parts) >= 12 ? parse(Float64, parts[12]) : 0.0
            volt_lim          = length(parts) >= 13 ? parse(Float64, parts[13]) : 0.0
            curr_control      = length(parts) >= 14 ? parse(Float64, parts[14]) : 0.0
        end

        return MCUTelemetry(
            timestamp, pH_ferm, pH_extr, ps_voltage, current_meas,
            volt_lim, curr_control, co2_sp_meas, pump_sp_meas, T_ferm, T_extr
        )
    catch e
        isa(e, InterruptException) && rethrow()
        return nothing
    end
end

"""
    format_mcu_actuator_command(current_A::Float64, co2_pct::Float64, pump_pct::Float64)::String

Format setpoints into the standard ASCII serial command recognized by the MCU firmware:
`PC,<current_A>,<co2_pct>,<pump_pct>\\r`
"""
function format_mcu_actuator_command(current_A::Float64, co2_pct::Float64, pump_pct::Float64)::String
    return @sprintf("PC,%.1f,%.1f,%.1f\r", current_A, co2_pct, pump_pct)
end
