# ============================================================================
# VOLTCRAFT DPPS-16-30 SERIAL HARDWARE DRIVER
# ============================================================================
# Driver and telemetry logger for the Voltcraft DPPS-series DC laboratory 
# power supplies (manufactured by Manson Engineering, e.g. DPPS-16-30, HCS-3300).
# Interfaced via internal Silicon Labs CP210x USB-to-UART bridge (9600 8-N-1).
# ============================================================================

using LibSerialPort
using Dates
using Printf

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
    mutable struct DPPSDevice
Represents a connected or simulated Voltcraft DPPS power supply.
"""
mutable struct DPPSDevice
    port_name::String
    baudrate::Int
    v_max::Float64
    i_max::Float64
    sp::Union{SerialPort, Nothing}
    is_mock::Bool
    mock_voltage::Float64
    mock_current::Float64
    mock_output_on::Bool
    mock_mode::String

    function DPPSDevice(port_name::String="COM4"; 
                        baudrate::Int=9600, 
                        v_max::Float64=16.0, 
                        i_max::Float64=30.0, 
                        mock::Bool=false)
        new(port_name, baudrate, v_max, i_max, nothing, mock, 0.0, 0.0, false, "CV")
    end
end

"""
    detect_dpps_ports()::Vector{String}

Auto-detect candidate serial ports for Silicon Labs CP210x or FTDI USB-UART converters.
Supports Windows PnP CIM query, macOS /dev/cu.usb*, and Linux /dev/ttyUSB*.
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
                # CP210x VID=10C4 PID=EA60, FTDI VID=0403 PID=6001, CH340 VID=1A86
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

"""
    parse_dpps_telemetry(raw::String; timestamp::DateTime=now())::DPPSReading

Parse the Manson/Voltcraft `GETD` ASCII response frame: `<VVVV><CCCC><S>` where:
- `VVVV`: 4-digit voltage in centivolts (`v_raw / 100.0` V)
- `CCCC`: 4-digit current in centiamperes (`i_raw / 100.0` A)
- `S`: 1-digit status flag (`0` = CV, `1` = CC)
"""
function parse_dpps_telemetry(raw::AbstractString; timestamp::DateTime=now())::DPPSReading
    # Robust regex extraction of 4-digit V, 4-digit I, and 1-digit mode flag.
    # Handles command echoes (e.g. "GETD\r120005000\rOK\r"), varied line endings (\r, \r\n, \n),
    # and any leading/trailing status bytes.
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
    query_dpps(dev::DPPSDevice, cmd::String; timeout_ms::Int=1200)::String

Send an ASCII command terminated by `\\r` and wait for the response ending with `OK\\r` or `OK\\r\\n`.
"""
function query_dpps(dev::DPPSDevice, cmd::String; timeout_ms::Int=1200)::String
    if dev.is_mock
        if cmd == "GETD"
            v_int = round(Int, dev.mock_voltage * 100)
            i_int = round(Int, dev.mock_current * 100)
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

    dev.sp !== nothing || error("DPPS device is not connected")
    sp = dev.sp

    LibSerialPort.sp_flush(sp, LibSerialPort.SP_BUF_BOTH)
    write(sp, cmd * "\r")

    t0 = time()
    buf = UInt8[]
    while (time() - t0) * 1000.0 < timeout_ms
        if bytesavailable(sp) > 0
            b = read(sp, 1)
            append!(buf, b)
            s = String(buf)
            # Break as soon as "OK" followed by any whitespace or newline is received
            if occursin("OK", s)
                # Drain any remaining bytes in flight (up to 20ms)
                sleep(0.02)
                while bytesavailable(sp) > 0
                    append!(buf, read(sp, 1))
                end
                break
            end
        else
            sleep(0.005)
        end
    end
    raw = String(buf)
    if !occursin("OK", raw)
        error("DPPS command '$cmd' timed out on port '$(dev.port_name)' after $(timeout_ms)ms. Raw bytes received: $(repr(raw))")
    end
    return strip(replace(raw, r"OK[\r\n]*" => ""))
end

"""
    open_dpps(port_name::String="COM4"; baudrate::Int=9600, v_max::Float64=16.0, i_max::Float64=30.0, mock::Bool=false)::DPPSDevice

Open communication with the Voltcraft DPPS power supply.
"""
function open_dpps(port_name::String="COM4"; 
                   baudrate::Int=9600, 
                   v_max::Float64=16.0, 
                   i_max::Float64=30.0, 
                   mock::Bool=false)::DPPSDevice
    dev = DPPSDevice(port_name; baudrate=baudrate, v_max=v_max, i_max=i_max, mock=mock)
    if mock
        println("[INFO] [DPPS] Initialized Mock Voltcraft DPPS-16-30.")
        return dev
    end

    println("[INFO] [DPPS] Opening serial connection to $port_name at $baudrate baud...")
    sp = LibSerialPort.open(port_name, baudrate)
    LibSerialPort.set_read_timeout(sp, 1000)

    # Force 8-N-1 and disable hardware flow control
    try
        LibSerialPort.sp_set_flowcontrol(sp.ref, LibSerialPort.SP_FLOWCONTROL_NONE)
        LibSerialPort.sp_set_bits(sp.ref, 8)
        LibSerialPort.sp_set_parity(sp.ref, LibSerialPort.SP_PARITY_NONE)
        LibSerialPort.sp_set_stopbits(sp.ref, 1)
    catch
    end
    dev.sp = sp

    # Query model limits via GMAX
    try
        res = query_dpps(dev, "GMAX"; timeout_ms=1000)
        m_gmax = match(r"(\d{3})(\d{3})", res)
        if m_gmax !== nothing
            dev.v_max = parse(Int, m_gmax.captures[1]) / 10.0
            dev.i_max = parse(Int, m_gmax.captures[2]) / 10.0
            println("[INFO] [DPPS] Connected. Limits: V_max = $(dev.v_max) V, I_max = $(dev.i_max) A")
        end
    catch e
        @warn "[DPPS] Failed to query GMAX limits, retaining defaults ($(dev.v_max)V, $(dev.i_max)A)" exception=e
    end

    return dev
end

"""
    close_dpps!(dev::DPPSDevice)

Safely close the serial connection to the power supply.
"""
function close_dpps!(dev::DPPSDevice)
    if !dev.is_mock && dev.sp !== nothing
        try
            close(dev.sp)
        catch e
            @warn "[DPPS] Error while closing serial port" exception=e
        end
        dev.sp = nothing
    end
    return nothing
end

"""
    read_dpps_telemetry(dev::DPPSDevice)::DPPSReading

Query live applied voltage, current, and CV/CC mode from the power supply.
"""
function read_dpps_telemetry(dev::DPPSDevice)::DPPSReading
    raw = query_dpps(dev, "GETD")
    return parse_dpps_telemetry(raw; timestamp=now())
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
