# ============================================================================
# MCU SERIAL TELEMETRY STREAM DRIVER
# ============================================================================
# Generic ASCII/CSV serial stream parser and driver for microcontroller units
# (such as the standalone ESP32-S3). Reads periodic measurement frames with
# range verification and no fabricated fallback values.
# ============================================================================

module MCUStream

using Dates
using Printf
using LibSerialPort

using ..BioprocessHardware: AbstractSensor, AbstractTransport, SerialTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_FAULT, STATUS_OVERRANGE, STATUS_UNDERRANGE, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_FAULT
using ..BioprocessHardware: DeviceError, DeviceTimeout, DeviceProtocolError, DeviceNotConnected
using ..BioprocessHardware: write_bytes!, read_until, read_line, flush_input!, close!, bytes_ready, inject!
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, safe_state!, close_device!

export MCUStreamDevice, open_mcu_stream, close_mcu_stream!
export MCUTelemetry, parse_mcu_line, is_measurement_line, format_mcu_actuator_command
export detect_windows_com_ports

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
                    elseif contains(device_id, "VID_303A&PID_1001")
                        WINDOWS_DETECTED_PORTS["esp32"] = com_port
                    end
                end
            end
        end
    catch e
        @warn "Windows COM port dynamic detection failed" exception=e
    end
    return WINDOWS_DETECTED_PORTS
end

""" 
    is_measurement_line(line::String)

Check if a line contains a valid timestamp in standard ISO/ASCII format.
Returns true if line begins with a valid 'yyyy-mm-dd HH:MM:SS' pattern.
"""
function is_measurement_line(line::AbstractString)::Bool
    s = strip(line)
    length(s) < 19 && return false
    # Fast prefix check
    prefix = s[1:19]
    return try
        DateTime(prefix, "yyyy-mm-dd HH:MM:SS")
        true
    catch
        false
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
    parse_mcu_line(line::String, use_new_unit::Bool=true)::Union{MCUTelemetry, Nothing}

Parse comma-separated telemetry frame received from the MCU:
Format: `DTM,pH1,pH2,PS(V),PS(A),LVL1(%),LVL2(%),LVL3(%),LVL4(%),T(°C),DOS set(%),FLO set(%),lim. volt.(V),fixed curr.(A),...`

Conforms strictly to Findings S9 and S11:
- S9: Never invents fallback defaults (e.g., 25°C or 0.0V); missing fields default to `NaN`.
- S11: If `T_extr` is not independently measured by hardware, it is reported as `NaN`.
- Adds range plausibility validation: pH in [0, 14], temperature in [-10, 120] °C.
"""
function parse_mcu_line(line::AbstractString, use_new_unit::Bool=true)::Union{MCUTelemetry, Nothing}
    s = strip(line)
    parts = split(s, ',')
    if length(parts) < 10 || parts[1] == "DTM"
        return nothing
    end

    timestamp = try
        DateTime(strip(parts[1]), "yyyy-mm-dd HH:MM:SS")
    catch
        return nothing
    end

    function safe_parse(idx::Int, min_val::Float64, max_val::Float64)::Float64
        if length(parts) < idx
            return NaN
        end
        val = tryparse(Float64, strip(parts[idx]))
        if val === nothing
            return NaN
        end
        if val < min_val || val > max_val
            return NaN
        end
        return val
    end

    function safe_float(idx::Int)::Float64
        if length(parts) < idx
            return NaN
        end
        val = tryparse(Float64, strip(parts[idx]))
        return val === nothing ? NaN : val
    end

    if use_new_unit
        pH_ferm      = safe_parse(2, 0.0, 14.0)
        pH_extr      = safe_parse(3, 0.0, 14.0)
        ps_voltage   = safe_float(4)
        current_meas = safe_float(5)
        T_ferm       = safe_parse(10, -10.0, 120.0)
        T_extr       = NaN # S11: Not measured by hardware in this unit, do not duplicate T_ferm
        co2_sp_meas  = safe_float(11)
        pump_sp_meas = safe_float(12)
        volt_lim     = safe_float(13)
        curr_control = safe_float(14)
    else
        pH_ferm      = NaN
        pH_extr      = safe_parse(2, 0.0, 14.0)
        ps_voltage   = safe_float(4)
        current_meas = safe_float(5)
        T_ferm       = NaN
        T_extr       = safe_parse(10, -10.0, 120.0)
        co2_sp_meas  = safe_float(11)
        pump_sp_meas = safe_float(12)
        volt_lim     = safe_float(13)
        curr_control = safe_float(14)
    end

    return MCUTelemetry(
        timestamp, pH_ferm, pH_extr, ps_voltage, current_meas,
        volt_lim, curr_control, co2_sp_meas, pump_sp_meas, T_ferm, T_extr
    )
end

"""
    format_mcu_actuator_command(current_A::Real, co2_pct::Real, pump_pct::Real)::String

Format setpoints into the standard ASCII serial command recognized by the MCU firmware:
`PC,<current_A>,<co2_pct>,<pump_pct>\\r`
"""
function format_mcu_actuator_command(current_A::Real, co2_pct::Real, pump_pct::Real)::String
    return @sprintf("PC,%.1f,%.1f,%.1f\r", Float64(current_A), Float64(co2_pct), Float64(pump_pct))
end

"""
    mutable struct MCUStreamDevice <: AbstractSensor
Sensor driver for streaming ASCII/CSV telemetry over a serial transport.
"""
mutable struct MCUStreamDevice <: AbstractSensor
    port_name::String
    baudrate::Int
    transport::Union{AbstractTransport, Nothing}
    is_mock::Bool
    mock_line::String
    info::DeviceInfo
    sp::Union{SerialPort, Nothing}
    lock::ReentrantLock
end

function MCUStreamDevice(port_name::String="COM5";
                         baudrate::Int=115200,
                         mock::Bool=false)
    info = DeviceInfo(vendor="Custom ESP32", model="MCU Stream", serial=port_name,
                      firmware="1.0", port=port_name, driver="MCUStream")
    default_line = "2026-08-25 14:00:00,7.15,7.35,0.2,0.0,0.0,0.0,0.0,0.0,25.4,15.0,45.0,20.0,0.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n"
    return MCUStreamDevice(port_name, baudrate, nothing, mock, default_line, info, nothing, ReentrantLock())
end

# ----------------------------------------------------------------------------
# Driver Interface Implementations
# ----------------------------------------------------------------------------

isconnected(dev::MCUStreamDevice) = dev.transport !== nothing && isopen(dev.transport)

identify(dev::MCUStreamDevice) = dev.info

function healthcheck(dev::MCUStreamDevice)
    isconnected(dev) || return Health(HEALTH_FAULT, "device not connected")
    return Health(HEALTH_OK)
end

function read_measurement(dev::MCUStreamDevice)::Reading
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))

    raw_line = ""
    lock(dev.lock) do
        if dev.is_mock
            # In mock mode, if transport buffer is empty, inject mock line
            if bytes_ready(dev.transport) == 0
                inject!(dev.transport, dev.mock_line)
            end
        end
        raw_bytes = read_until(dev.transport, "\n"; timeout_s=1.0, device=dev.port_name, operation="read_telemetry")
        raw_line = String(raw_bytes)
    end

    mcu = parse_mcu_line(raw_line, true)
    if mcu === nothing
        # Corrupted line or header
        val = (pH_ferm=NaN, pH_extr=NaN, ps_voltage=NaN, current_measured=NaN,
               T_ferm=NaN, T_extr=NaN, co2_sp_measured=NaN, pump_sp_measured=NaN)
        units = (pH_ferm="", pH_extr="", ps_voltage="V", current_measured="A",
                 T_ferm="°C", T_extr="°C", co2_sp_measured="%", pump_sp_measured="%")
        return Reading(val; units=units, status=STATUS_FAULT, source=dev.info)
    end

    if isfinite(mcu.T_extr)
        val = (pH_ferm=mcu.pH_ferm, pH_extr=mcu.pH_extr, ps_voltage=mcu.ps_voltage,
               current_measured=mcu.current_measured, T_ferm=mcu.T_ferm, T_extr=mcu.T_extr,
               co2_sp_measured=mcu.co2_sp_measured, pump_sp_measured=mcu.pump_sp_measured)
        units = (pH_ferm="", pH_extr="", ps_voltage="V", current_measured="A",
                 T_ferm="°C", T_extr="°C", co2_sp_measured="%", pump_sp_measured="%")
    else
        val = (pH_ferm=mcu.pH_ferm, pH_extr=mcu.pH_extr, ps_voltage=mcu.ps_voltage,
               current_measured=mcu.current_measured, T_ferm=mcu.T_ferm,
               co2_sp_measured=mcu.co2_sp_measured, pump_sp_measured=mcu.pump_sp_measured)
        units = (pH_ferm="", pH_extr="", ps_voltage="V", current_measured="A",
                 T_ferm="°C", co2_sp_measured="%", pump_sp_measured="%")
    end

    # Determine status based on finite validity of critical measurements
    status = (isnan(mcu.pH_ferm) || isnan(mcu.pH_extr)) ? STATUS_FAULT : STATUS_OK
    return Reading(val; units=units, status=status, source=dev.info)
end

safe_state!(dev::MCUStreamDevice) = nothing

function close_device!(dev::MCUStreamDevice)
    if dev.transport !== nothing
        close!(dev.transport)
        dev.transport = nothing
    end
    dev.sp = nothing
    return nothing
end

close_mcu_stream!(dev::MCUStreamDevice) = close_device!(dev)

"""
    open_mcu_stream(port_name::String="COM5"; baudrate::Int=115200, mock::Bool=false)::MCUStreamDevice
"""
function open_mcu_stream(port_name::String="COM5"; baudrate::Int=115200, mock::Bool=false)::MCUStreamDevice
    dev = MCUStreamDevice(port_name; baudrate=baudrate, mock=mock)
    if mock
        t = MockTransport()
        inject!(t, dev.mock_line)
        dev.transport = t
        return dev
    end

    sp = SerialTransport(port_name, baudrate)
    dev.transport = sp
    dev.sp = sp.sp
    return dev
end

end # module MCUStream
