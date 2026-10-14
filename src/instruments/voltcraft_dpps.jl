# ============================================================================
# VOLTCRAFT DPPS-SERIES DC POWER SUPPLY DRIVER
# ============================================================================
# Driver and telemetry logger for the Voltcraft DPPS-series DC laboratory 
# power supplies (manufactured by Manson Engineering, e.g. DPPS-16-30, HCS-3300).
# Interfaced via internal Silicon Labs CP210x USB-to-UART bridge (9600 8-N-1).
# ============================================================================

module VoltcraftDPPS

using Dates
using Printf
using LibSerialPort

using ..BioprocessHardware: AbstractActuator, AbstractTransport, SerialTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_FAULT, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_FAULT
using ..BioprocessHardware: SetpointResult, DeviceError, DeviceTimeout, DeviceProtocolError, DeviceNotConnected
using ..BioprocessHardware: write_bytes!, read_until, flush_input!, close!, bytes_ready, read_ready
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, write_setpoint!, safe_state!, close_device!

export DPPSReading, DPPSDevice, open_dpps, close_dpps!
export read_dpps_telemetry, parse_dpps_telemetry, detect_dpps_ports
export set_dpps_output!, set_dpps_voltage!, set_dpps_current!, query_dpps

"""
    struct DPPSReading
Container for decoded instantaneous measurements from the Voltcraft DPPS power supply.
"""
struct DPPSReading
    timestamp::DateTime
    voltage_V::Float64
    current_A::Float64
    power_W::Float64
    mode::String       # "CV" (Constant Voltage) or "CC" (Constant Current)
end

"""
    mutable struct DPPSDevice <: AbstractActuator
Represents a connected or simulated Voltcraft DPPS power supply.
"""
mutable struct DPPSDevice <: AbstractActuator
    port_name::String
    baudrate::Int
    v_max::Float64
    i_max::Float64
    transport::Union{AbstractTransport, Nothing}
    is_mock::Bool
    safe_off_on_close::Bool
    mock_voltage::Float64
    mock_current::Float64
    mock_output_on::Bool
    mock_mode::String
    info::DeviceInfo

    # Backward compatibility with existing dev.sp field
    sp::Union{SerialPort, Nothing}
end

function DPPSDevice(port_name::String="COM4"; 
                    baudrate::Int=9600, 
                    v_max::Float64=16.0, 
                    i_max::Float64=30.0, 
                    mock::Bool=false,
                    safe_off_on_close::Bool=true)
    info = DeviceInfo(vendor="Voltcraft", model="DPPS", serial=port_name,
                      firmware="1.0", port=port_name, driver="VoltcraftDPPS")
    return DPPSDevice(port_name, baudrate, v_max, i_max, nothing, mock, safe_off_on_close,
                      0.0, 0.0, false, "CV", info, nothing)
end

# ----------------------------------------------------------------------------
# Driver Interface Implementations
# ----------------------------------------------------------------------------

isconnected(dev::DPPSDevice) = dev.transport !== nothing && isopen(dev.transport)

identify(dev::DPPSDevice) = dev.info

function healthcheck(dev::DPPSDevice)
    if !isconnected(dev)
        return Health(HEALTH_FAULT, "device not connected")
    end
    try
        # Quick non-destructive test: query GMAX or GETD
        query_dpps(dev, "GMAX"; timeout_ms=500)
        return Health(HEALTH_OK)
    catch e
        return Health(HEALTH_FAULT, sprint(showerror, e))
    end
end

function read_measurement(dev::DPPSDevice)::Reading
    if !isconnected(dev)
        throw(DeviceNotConnected(dev.port_name))
    end
    raw = query_dpps(dev, "GETD")
    r = parse_dpps_telemetry(raw; timestamp=now(UTC))
    val = (voltage=r.voltage_V, current=r.current_A, power=r.power_W, mode=r.mode)
    units = (voltage="V", current="A", power="W", mode="")
    return Reading(val; units=units, status=STATUS_OK, source=dev.info, t_utc=r.timestamp)
end

"""
    read_dpps_telemetry(dev::DPPSDevice)::DPPSReading

Query live applied voltage, current, and CV/CC mode from the power supply.
(Legacy function, see also `read_measurement`).
"""
function read_dpps_telemetry(dev::DPPSDevice)::DPPSReading
    raw = query_dpps(dev, "GETD")
    return parse_dpps_telemetry(raw; timestamp=now())
end

"""
    write_setpoint!(dev::DPPSDevice, target::NamedTuple)
    write_setpoint!(dev::DPPSDevice, voltage::Real)

Apply voltage and/or current setpoint with read-back verification.
"""
function write_setpoint!(dev::DPPSDevice, target::NamedTuple)
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    
    if haskey(target, :output)
        set_dpps_output!(dev, Bool(target.output))
    end
    if haskey(target, :voltage)
        set_dpps_voltage!(dev, Float64(target.voltage))
    end
    if haskey(target, :current)
        set_dpps_current!(dev, Float64(target.current))
    end
    return SetpointResult(true, target, target, 1, "applied")
end

function write_setpoint!(dev::DPPSDevice, voltage::Real)
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    v = clamp(Float64(voltage), 0.0, dev.v_max)
    set_dpps_voltage!(dev, v)
    return SetpointResult(true, voltage, v, 1, "applied")
end

function safe_state!(dev::DPPSDevice)
    if isconnected(dev)
        try
            set_dpps_output!(dev, false)
            set_dpps_voltage!(dev, 0.0)
        catch e
            @warn "Failed to apply safe state to DPPS power supply" exception=e
        end
    end
    dev.mock_output_on = false
    dev.mock_voltage = 0.0
    return nothing
end

function close_device!(dev::DPPSDevice)
    if dev.safe_off_on_close
        safe_state!(dev)
    end
    if dev.transport !== nothing
        close!(dev.transport)
        dev.transport = nothing
    end
    dev.sp = nothing
    return nothing
end

close_dpps!(dev::DPPSDevice) = close_device!(dev)

# ----------------------------------------------------------------------------
# Manson Protocol Communication
# ----------------------------------------------------------------------------

"""
    query_dpps(dev::DPPSDevice, cmd::String; timeout_ms::Int=1200)::String

Send an ASCII command terminated by `\\r` and wait for the response ending with `OK\\r` or `OK\\r\\n`.
"""
function query_dpps(dev::DPPSDevice, cmd::String; timeout_ms::Int=1200)::String
    if dev.is_mock
        if cmd == "GETD"
            # Finding H12: when output is OFF, actual measured voltage and current are 0.0
            v_actual = dev.mock_output_on ? dev.mock_voltage : 0.0
            i_actual = dev.mock_output_on ? dev.mock_current : 0.0
            v_int = round(Int, v_actual * 100)
            i_int = round(Int, i_actual * 100)
            m_flag = dev.mock_mode == "CC" ? "1" : "0"
            return @sprintf("%04d%04d%s", v_int, i_int, m_flag)
        elseif cmd == "GMAX"
            v_int = round(Int, dev.v_max * 10)
            i_int = round(Int, dev.i_max * 10)
            return @sprintf("%03d%03d", v_int, i_int)
        elseif startswith(cmd, "SOUT")
            # SOUT0 = ON, SOUT1 = OFF
            dev.mock_output_on = (cmd == "SOUT0")
            return ""
        elseif startswith(cmd, "VOLT")
            v_int = parse(Int, cmd[5:end])
            dev.mock_voltage = v_int / 10.0
            return ""
        elseif startswith(cmd, "CURR")
            i_int = parse(Int, cmd[5:end])
            dev.mock_current = i_int / 10.0
            return ""
        else
            return ""
        end
    end

    if dev.transport === nothing || !isopen(dev.transport)
        throw(DeviceNotConnected(dev.port_name))
    end
    t = dev.transport

    flush_input!(t)
    write_bytes!(t, cmd * "\r")

    timeout_s = timeout_ms / 1000.0
    try
        raw_bytes = read_until(t, "OK"; timeout_s=timeout_s, device=dev.port_name, operation=cmd)
        # Drain any residual newline/carriage return after "OK"
        sleep(0.01)
        tail = read_ready(t, 8)
        full = String(vcat(raw_bytes, tail))
        return strip(replace(full, r"OK[\r\n]*" => ""))
    catch e
        if e isa DeviceTimeout
            throw(DeviceTimeout(dev.port_name, cmd, timeout_s))
        end
        rethrow(e)
    end
end

"""
    parse_dpps_telemetry(raw::AbstractString; timestamp::DateTime=now())::DPPSReading

Parse the Manson/Voltcraft `GETD` ASCII response frame: `<VVVV><CCCC><S>` where:
- `VVVV`: 4-digit voltage in centivolts (`v_raw / 100.0` V)
- `CCCC`: 4-digit current in centiamperes (`i_raw / 100.0` A)
- `S`: 1-digit status flag (`0` = CV, `1` = CC)
"""
function parse_dpps_telemetry(raw::AbstractString; timestamp::DateTime=now())::DPPSReading
    m = match(r"(\d{4})(\d{4})([01])", raw)
    if m !== nothing
        v_raw = parse(Int, m.captures[1])
        i_raw = parse(Int, m.captures[2])
        mode_char = m.captures[3][1]

        v = v_raw / 100.0
        i = i_raw / 100.0
        p = v * i
        mode = mode_char == '1' ? "CC" : "CV"

        return DPPSReading(timestamp, v, i, p, mode)
    end

    clean = replace(strip(raw), "\r" => "", "\n" => "", "OK" => "")
    if length(clean) >= 9 && all(isdigit, clean[1:9])
        v_raw = parse(Int, clean[1:4])
        i_raw = parse(Int, clean[5:8])
        mode = clean[9] == '1' ? "CC" : "CV"
        return DPPSReading(timestamp, v_raw / 100.0, i_raw / 100.0, (v_raw / 100.0) * (i_raw / 100.0), mode)
    end

    error("Malformed DPPS GETD response (expected 9 telemetry characters): $(repr(raw))")
end

"""
    open_dpps(port_name::String="COM4"; baudrate::Int=9600, v_max::Float64=16.0, i_max::Float64=30.0,
              mock::Bool=false, safe_off_on_close::Bool=true)::DPPSDevice

Open communication with the Voltcraft DPPS power supply.
"""
function open_dpps(port_name::String="COM4"; 
                   baudrate::Int=9600, 
                   v_max::Float64=16.0, 
                   i_max::Float64=30.0, 
                   mock::Bool=false,
                   safe_off_on_close::Bool=true)::DPPSDevice
    dev = DPPSDevice(port_name; baudrate=baudrate, v_max=v_max, i_max=i_max, mock=mock,
                     safe_off_on_close=safe_off_on_close)
    if mock
        dev.transport = MockTransport()
        return dev
    end

    sp = SerialTransport(port_name, baudrate)
    dev.transport = sp
    dev.sp = sp.sp

    # Query model limits via GMAX
    try
        res = query_dpps(dev, "GMAX"; timeout_ms=1000)
        m_gmax = match(r"(\d{3})(\d{3})", res)
        if m_gmax !== nothing
            dev.v_max = parse(Int, m_gmax.captures[1]) / 10.0
            dev.i_max = parse(Int, m_gmax.captures[2]) / 10.0
            dev.info = DeviceInfo(vendor="Voltcraft", model=@sprintf("DPPS-%.0f-%.0f", dev.v_max, dev.i_max),
                                  serial=port_name, firmware="1.0", port=port_name, driver="VoltcraftDPPS")
        end
    catch e
        @warn "[DPPS] Failed to query GMAX limits, retaining defaults ($(dev.v_max)V, $(dev.i_max)A)" exception=e
    end

    return dev
end

"""
    set_dpps_output!(dev::DPPSDevice, enabled::Bool)::Bool

Turn the DC output ON (`enabled = true`) or OFF (`enabled = false`).
Manson protocol uses `SOUT0` for ON and `SOUT1` for OFF.
"""
function set_dpps_output!(dev::DPPSDevice, enabled::Bool)::Bool
    cmd = enabled ? "SOUT0" : "SOUT1"
    query_dpps(dev, cmd)
    return true
end

"""
    set_dpps_voltage!(dev::DPPSDevice, voltage::Real)::Bool

Set target voltage setpoint in Volts (clamped to `[0.0, v_max]`).
Resolution is 0.1 V (`VOLT<VVV>`).
"""
function set_dpps_voltage!(dev::DPPSDevice, voltage::Real)::Bool
    v_clamped = clamp(Float64(voltage), 0.0, dev.v_max)
    v_val = round(Int, v_clamped * 10)
    cmd = @sprintf("VOLT%03d", v_val)
    query_dpps(dev, cmd)
    return true
end

"""
    set_dpps_current!(dev::DPPSDevice, current::Real)::Bool

Set target current limit in Amperes (clamped to `[0.0, i_max]`).
Resolution is 0.1 A (`CURR<CCC>`).
"""
function set_dpps_current!(dev::DPPSDevice, current::Real)::Bool
    i_clamped = clamp(Float64(current), 0.0, dev.i_max)
    i_val = round(Int, i_clamped * 10)
    cmd = @sprintf("CURR%03d", i_val)
    query_dpps(dev, cmd)
    return true
end

"""
    detect_dpps_ports()::Vector{String}

Auto-detect candidate serial ports for Silicon Labs CP210x or FTDI USB-UART converters.
"""
function detect_dpps_ports()::Vector{String}
    ports = String[]
    if Sys.iswindows()
        try
            cmd = `powershell -Command "Get-CimInstance Win32_PnPEntity -Filter \"Name like '%(COM%)'\" | ForEach-Object { \$_.Name + '|' + \$_.DeviceID }"`
            output = read(cmd, String)
            for line in split(output, '\n')
                line = strip(line)
                if isempty(line) || !contains(line, '|')
                    continue
                end
                parts = split(line, '|')
                name, device_id = parts[1], parts[2]
                if contains(device_id, "VID_10C4") || contains(device_id, "VID_0403") || contains(device_id, "VID_1A86")
                    m = match(r"\(COM(\d+)\)", name)
                    if !isnothing(m)
                        push!(ports, "COM" * m.captures[1])
                    end
                end
            end
        catch e
            @warn "[DPPS] Failed to query Windows PnP entities" exception=e
        end
    elseif Sys.isapple()
        dev_entries = readdir("/dev")
        for f in dev_entries
            if startswith(f, "cu.usbserial") || startswith(f, "cu.SLAB_USBtoUART") || startswith(f, "cu.usbmodem")
                push!(ports, "/dev/" * f)
            end
        end
    else # Linux
        dev_entries = ispath("/dev") ? readdir("/dev") : String[]
        for f in dev_entries
            if startswith(f, "ttyUSB") || startswith(f, "ttyACM")
                push!(ports, "/dev/" * f)
            end
        end
    end
    return ports
end

end # module VoltcraftDPPS
