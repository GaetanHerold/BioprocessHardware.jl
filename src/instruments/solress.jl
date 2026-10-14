# ==============================================================================
# SOLRESS Counterpressure Valve MCU — Host Serial Driver & Mock Hardware
# ==============================================================================
# Driver for the SOLRESS counterpressure control MCU (ESP32-S3). Manages
# bidirectional serial communication, CRC-16-CCITT packet framing,
# sequence-numbered command dispatch, 10 Hz telemetry streaming, and in-memory
# high-fidelity simulation.
# ==============================================================================

module Solress

using Dates
using Printf
using LibSerialPort

using ..BioprocessHardware: AbstractActuator, AbstractTransport, SerialTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_FAULT, STATUS_OVERRANGE, STATUS_UNDERRANGE, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_FAULT
using ..BioprocessHardware: SetpointResult, DeviceError, DeviceTimeout, DeviceProtocolError, DeviceFault, DeviceNotConnected
using ..BioprocessHardware: write_bytes!, read_until, flush_input!, close!, bytes_ready, read_ready
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, write_setpoint!, safe_state!, close_device!

export SOLRESSTelemetry, SolressTelemetry
export SolressSerialDriver, SolressDevice, MockSolressMCU
export open_solress_driver, close_solress_driver!, open_solress, close_solress!
export set_valve_position!, home_valve!, emergency_stop!
export read_telemetry, is_healthy, reconnect_solress_driver!
export solress_crc16, format_solress_packet, parse_solress_packet, detect_solress_ports
export start_mock_mcu!, stop_mock_mcu!, step_simulation!, inject_slip_fault!, inject_overpressure_fault!
export channel_put_drop_oldest!

# ------------------------------------------------------------------------------
# 1. CRC-16-CCITT & Packet Codec
# ------------------------------------------------------------------------------

"""
    solress_crc16(data::Vector{UInt8})::UInt16

Calculates CRC-16-CCITT checksum (polynomial 0x1021, initial value 0xFFFF).
Matches ESP32 firmware calculation bit-for-bit.
"""
function solress_crc16(data::Vector{UInt8})::UInt16
    crc::UInt16 = 0xFFFF
    for byte in data
        crc = crc ⊻ (UInt16(byte) << 8)
        for _ in 1:8
            if (crc & 0x8000) != 0
                crc = (crc << 1) ⊻ 0x1021
            else
                crc = crc << 1
            end
        end
    end
    return crc & 0xFFFF
end

solress_crc16(str::AbstractString) = solress_crc16(Vector{UInt8}(codeunits(str)))

"""
    format_solress_packet(payload::AbstractString)::String

Frames a packet with leading `\$`, trailing `*<CRC16>` in uppercase hex, and `\\r\\n`.
"""
function format_solress_packet(payload::AbstractString)::String
    clean = strip(payload)
    if startswith(clean, "\$")
        clean = clean[2:end]
    end
    crc = solress_crc16(clean)
    return @sprintf("\$%s*%04X\r\n", clean, crc)
end

# System Configuration Constants matching ESP32 firmware config.h
const OVERPRESSURE_TRIP_BAR = 0.60
const VALVE_STROKE_STEPS = 19200
const MAX_MICROSTEPS = 19200

"""
    parse_solress_packet(line::AbstractString)::NamedTuple

Validates packet framing, body length, and CRC-16-CCITT. Returns:
`(valid=Bool, type=String, fields=Vector{String}, raw_crc=String, error=String, error_reason=String)`
"""
function parse_solress_packet(line::AbstractString)
    cleaned = strip(line)
    if !startswith(cleaned, "\$") || !occursin("*", cleaned)
        return (valid=false, type="", fields=String[], raw_crc="", error="MISSING_DELIMITERS", error_reason="MISSING_DELIMITERS")
    end

    parts = split(cleaned[2:end], "*", limit=2)
    if length(parts) != 2
        return (valid=false, type="", fields=String[], raw_crc="", error="MALFORMED_PACKET", error_reason="MALFORMED_PACKET")
    end

    body, crc_str = parts[1], parts[2]

    if isempty(body) || length(body) == 0
        return (valid=false, type="", fields=String[], raw_crc=String(crc_str), error="EMPTY_BODY", error_reason="EMPTY_BODY")
    end

    if length(crc_str) != 4
        return (valid=false, type="", fields=String[], raw_crc=String(crc_str), error="INVALID_CRC_FORMAT", error_reason="INVALID_CRC_FORMAT")
    end

    expected_crc = solress_crc16(body)
    parsed_crc = tryparse(UInt16, crc_str, base=16)

    if parsed_crc === nothing || parsed_crc != expected_crc
        return (valid=false, type="", fields=String[], raw_crc=String(crc_str), error="CRC_MISMATCH", error_reason="CRC_MISMATCH")
    end

    tokens = split(body, ",")
    pkt_type = isempty(tokens) ? "" : String(tokens[1])
    return (valid=true, type=pkt_type, fields=String.(tokens), raw_crc=String(crc_str), error="", error_reason="")
end

# ------------------------------------------------------------------------------
# 2. Telemetry Record Schema
# ------------------------------------------------------------------------------

"""
    SOLRESSTelemetry
Structured telemetry frame received from the SOLRESS ESP32 unit at 10 Hz.
"""
struct SOLRESSTelemetry
    timestamp::DateTime
    sequence::UInt32
    time_ms::UInt32
    pressure_bar::Float64
    level_mm::Float64
    valve_position_pct::Float64
    raw_angle::Int
    valve_turns::Int
    target_steps::Int
    actual_steps::Int
    motor_status::UInt8
    fault_code::UInt16
    is_homed::Bool
    is_moving::Bool
    is_slip_detected::Bool
    is_overpressure::Bool
end

const SolressTelemetry = SOLRESSTelemetry

"""
    parse_solress_telemetry(fields::Vector{String})::SOLRESSTelemetry
"""
function parse_solress_telemetry(fields::Vector{String})::SOLRESSTelemetry
    if length(fields) < 12
        error("Insufficient fields in TEL packet: expected >= 12, got $(length(fields))")
    end

    seq = parse(UInt32, fields[2])
    t_ms = parse(UInt32, fields[3])
    p_bar = parse(Float64, fields[4])
    l_mm = parse(Float64, fields[5])
    v_pct = parse(Float64, fields[6])
    raw_ang = parse(Int, fields[7])
    turns = parse(Int, fields[8])
    targ = parse(Int, fields[9])
    act = parse(Int, fields[10])
    status = parse(UInt8, fields[11])
    fault = parse(UInt16, fields[12])

    is_homed = (status & 0x02) != 0
    is_moving = (status & 0x01) != 0
    is_slip = (fault & 0x02) != 0
    is_overp = (fault & 0x01) != 0

    return SOLRESSTelemetry(
        now(UTC),
        seq,
        t_ms,
        p_bar,
        l_mm,
        v_pct,
        raw_ang,
        turns,
        targ,
        act,
        status,
        fault,
        is_homed,
        is_moving,
        is_slip,
        is_overp
    )
end

# ------------------------------------------------------------------------------
# 3. High-Fidelity Mock ESP32 MCU
# ------------------------------------------------------------------------------

function channel_put_drop_oldest!(channel::Channel{T}, item) where T
    lock(channel) do
        if !isopen(channel)
            throw(InvalidStateException("Channel is closed.", :closed))
        end
        while channel.sz_max > 0 && Base.n_avail(channel) >= channel.sz_max && isready(channel)
            take!(channel)
        end
        put!(channel, item)
    end
    return item
end

mutable struct MockSolressMCU
    target_steps::Int
    actual_steps::Int
    valve_pct::Float64
    pressure_bar::Float64
    level_mm::Float64
    raw_angle::Int
    turns::Int
    is_homed::Bool
    is_moving::Bool
    is_slip_detected::Bool
    is_estop::Bool
    is_overpressure::Bool
    motor_speed_sps::Float64
    sequence::UInt32
    start_time::Float64
    rx_channel::Channel{String}
    tx_channel::Channel{String}
    keep_running::Ref{Bool}
    sim_task::Union{Task, Nothing}
    lock::ReentrantLock

    function MockSolressMCU(; pressure_bar::Float64=0.25, level_mm::Float64=50.0)
        new(
            0,
            0,
            0.0,
            pressure_bar,
            level_mm,
            0,
            0,
            false,
            false,
            false,
            false,
            false,
            1000.0,
            UInt32(0),
            time(),
            Channel{String}(64),
            Channel{String}(128),
            Ref{Bool}(false),
            nothing,
            ReentrantLock()
        )
    end
end

function start_mock_mcu!(mock::MockSolressMCU)
    mock.keep_running[] = true
    mock.start_time = time()
    mock.sim_task = @async begin
        dt = 0.02
        telemetry_interval = 0.1
        last_telem = time()

        while mock.keep_running[]
            t_now = time()

            lock(mock.lock) do
                while isready(mock.rx_channel)
                    raw_line = take!(mock.rx_channel)
                    process_mock_command!(mock, raw_line)
                end

                step_simulation!(mock, dt)

                if (t_now - last_telem) >= telemetry_interval
                    emit_mock_telemetry!(mock)
                    last_telem = t_now
                end
            end

            sleep(dt)
        end
    end
end

function stop_mock_mcu!(mock::MockSolressMCU)
    mock.keep_running[] = false
    try
        close(mock.rx_channel)
        close(mock.tx_channel)
    catch
    end
end

function step_simulation!(mock::MockSolressMCU, dt::Float64)
    if mock.is_estop
        mock.is_moving = false
        mock.valve_pct = 100.0
        return
    end

    if mock.is_slip_detected
        mock.is_moving = false
        return
    end

    if mock.actual_steps != mock.target_steps
        mock.is_moving = true
        max_delta = round(Int, mock.motor_speed_sps * dt)
        delta = mock.target_steps - mock.actual_steps

        if abs(delta) <= max_delta
            mock.actual_steps = mock.target_steps
            mock.is_moving = false
        else
            mock.actual_steps += sign(delta) * max_delta
        end

        mock.actual_steps = clamp(mock.actual_steps, 0, VALVE_STROKE_STEPS)
        mock.valve_pct = (mock.actual_steps / VALVE_STROKE_STEPS) * 100.0

        total_encoder_counts = round(Int, mock.actual_steps * 1.28)
        mock.turns = total_encoder_counts ÷ 4096
        mock.raw_angle = mod(total_encoder_counts, 4096)
    else
        mock.is_moving = false
    end

    if !mock.is_overpressure
        mock.pressure_bar = 0.05 + (1.0 - mock.valve_pct / 100.0) * 0.45 + (rand() - 0.5) * 0.005
    end
end

function process_mock_command!(mock::MockSolressMCU, raw_line::AbstractString)
    parsed = parse_solress_packet(raw_line)
    if !parsed.valid || parsed.type != "CMD" || length(parsed.fields) < 2
        return
    end

    # Check for sequence number (Finding H3)
    # Formats: CMD,<seq>,<action>,<args...> OR CMD,<action>,<args...>
    seq_str = ""
    cmd_name = ""
    arg_idx = 3

    if length(parsed.fields) >= 3 && tryparse(Int, parsed.fields[2]) !== nothing
        seq_str = parsed.fields[2]
        cmd_name = uppercase(parsed.fields[3])
        arg_idx = 4
    else
        cmd_name = uppercase(parsed.fields[2])
        arg_idx = 3
    end

    ack_prefix = isempty(seq_str) ? "ACK,$cmd_name" : "ACK,$seq_str,$cmd_name"
    err_prefix = isempty(seq_str) ? "ERR,$cmd_name" : "ERR,$seq_str,$cmd_name"

    if cmd_name == "ID"
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,SOLRESS_MCU"))
    elseif cmd_name == "PING"
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,OK"))
    elseif cmd_name == "POS"
        if length(parsed.fields) >= arg_idx
            val_pct = tryparse(Float64, parsed.fields[arg_idx])
            if val_pct === nothing || val_pct < 0.0 || val_pct > 100.0
                channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$err_prefix,OUT_OF_RANGE"))
            else
                mock.target_steps = round(Int, (val_pct / 100.0) * 19200)
                channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,OK"))
            end
        else
            channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$err_prefix,MISSING_ARG"))
        end
    elseif cmd_name == "HOME"
        mock.actual_steps = 160
        mock.target_steps = 160
        mock.is_homed = true
        mock.is_slip_detected = false
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,SUCCESS"))
    elseif cmd_name == "ESTOP"
        mock.is_estop = true
        mock.target_steps = 19200
        mock.actual_steps = 19200
        mock.valve_pct = 100.0
        mock.is_moving = false
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,SAFE"))
        emit_mock_telemetry!(mock)
    elseif cmd_name == "CFG"
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("$ack_prefix,UPDATED"))
    else
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ERR,$cmd_name,UNKNOWN"))
    end
end

function emit_mock_telemetry!(mock::MockSolressMCU)
    mock.sequence += 1
    t_ms = round(UInt32, (time() - mock.start_time) * 1000.0)

    status_flags::UInt8 = 0
    if mock.is_moving
        status_flags |= 0x01
    end
    if mock.is_homed
        status_flags |= 0x02
    end
    if !mock.is_moving && mock.is_homed
        status_flags |= 0x04
    end
    if mock.is_slip_detected
        status_flags |= 0x08
    end

    fault_flags::UInt16 = 0
    if mock.is_overpressure || mock.is_estop
        fault_flags |= 0x01
    end
    if mock.is_slip_detected
        fault_flags |= 0x02
    end

    payload = @sprintf(
        "TEL,%d,%d,%.4f,%.2f,%.2f,%d,%d,%d,%d,%d,%d",
        mock.sequence,
        t_ms,
        mock.pressure_bar,
        mock.level_mm,
        mock.valve_pct,
        mock.raw_angle,
        mock.turns,
        mock.target_steps,
        mock.actual_steps,
        status_flags,
        fault_flags
    )

    pkt = format_solress_packet(payload)
    channel_put_drop_oldest!(mock.tx_channel, pkt)
end

function inject_slip_fault!(mock::MockSolressMCU)
    lock(mock.lock) do
        mock.is_slip_detected = true
        mock.is_moving = false
    end
end

function inject_overpressure_fault!(mock::MockSolressMCU, p_bar::Float64=0.65)
    lock(mock.lock) do
        mock.pressure_bar = p_bar
        mock.is_overpressure = true
        if p_bar >= OVERPRESSURE_TRIP_BAR
            mock.is_estop = true
            mock.target_steps = VALVE_STROKE_STEPS
            mock.actual_steps = VALVE_STROKE_STEPS
            mock.valve_pct = 100.0
            mock.is_moving = false
            total_encoder_counts = round(Int, VALVE_STROKE_STEPS * 1.28)
            mock.turns = total_encoder_counts ÷ 4096
            mock.raw_angle = mod(total_encoder_counts, 4096)
        end
    end
end

# ------------------------------------------------------------------------------
# 4. SolressSerialDriver Host Interface (implements AbstractActuator)
# ------------------------------------------------------------------------------

mutable struct SolressSerialDriver <: AbstractActuator
    port_name::String
    baudrate::Int
    port::Any
    transport::Union{AbstractTransport, Nothing}
    is_mock::Bool
    is_connected::Bool
    is_homed::Bool
    last_telemetry::Union{SOLRESSTelemetry, Nothing}
    telemetry_channel::Channel{SOLRESSTelemetry}
    lock::ReentrantLock
    keep_running::Ref{Bool}
    reader_task::Union{Task, Nothing}
    mock_mcu::Union{MockSolressMCU, Nothing}
    last_comm_time::Ref{Float64}
    error_count::Ref{Int}
    cmd_lock::ReentrantLock
    ack_cond::Threads.Condition
    pending_cmd_id::Ref{String}
    pending_seq::Ref{UInt32}
    last_ack_response::Ref{String}
    ack_received::Ref{Bool}
    cmd_seq_counter::Ref{UInt32}
    info::DeviceInfo

    function SolressSerialDriver(port_name::String, baudrate::Int=115200; is_mock::Bool=false)
        info = DeviceInfo(vendor="SOLRESS", model="Counterpressure MCU", serial=port_name,
                          firmware="1.0", port=port_name, driver="Solress")
        new(
            port_name,
            baudrate,
            nothing,
            nothing,
            is_mock,
            false,
            false,
            nothing,
            Channel{SOLRESSTelemetry}(128),
            ReentrantLock(),
            Ref{Bool}(false),
            nothing,
            nothing,
            Ref{Float64}(0.0),
            Ref{Int}(0),
            ReentrantLock(),
            Threads.Condition(ReentrantLock()),
            Ref{String}(""),
            Ref{UInt32}(0),
            Ref{String}(""),
            Ref{Bool}(false),
            Ref{UInt32}(0),
            info
        )
    end
end

const SolressDevice = SolressSerialDriver

# ------------------------------------------------------------------------------
# Driver Contract Methods
# ------------------------------------------------------------------------------

isconnected(dev::SolressSerialDriver) = dev.is_connected

identify(dev::SolressSerialDriver) = dev.info

function healthcheck(dev::SolressSerialDriver)
    isconnected(dev) || return Health(HEALTH_FAULT, "device not connected")
    is_healthy(dev) || return Health(HEALTH_FAULT, "device fault or heartbeat timeout")
    return Health(HEALTH_OK)
end

function read_measurement(dev::SolressSerialDriver)::Reading
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    tel = read_telemetry(dev)
    if tel === nothing
        val = (valve_position_pct=NaN, pressure_bar=NaN, level_mm=NaN)
        units = (valve_position_pct="%", pressure_bar="bar", level_mm="mm")
        return Reading(val; units=units, status=STATUS_FAULT, source=dev.info)
    end

    val = (valve_position_pct=tel.valve_position_pct, pressure_bar=tel.pressure_bar, level_mm=tel.level_mm)
    units = (valve_position_pct="%", pressure_bar="bar", level_mm="mm")
    status = (tel.is_slip_detected || tel.is_overpressure) ? STATUS_FAULT : STATUS_OK
    return Reading(val; units=units, status=status, source=dev.info)
end

function write_setpoint!(dev::SolressSerialDriver, pos_pct::Real)
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    val = Float64(pos_pct)
    if val < 0.0 || val > 100.0
        cur_pos = dev.last_telemetry === nothing ? 0.0 : dev.last_telemetry.valve_position_pct
        return SetpointResult(false, val, cur_pos, 0, "setpoint out of bounds [0, 100]")
    end
    ok = set_valve_position!(dev, val)
    return SetpointResult(ok, val, val, 1, ok ? "applied" : "failed")
end

function safe_state!(dev::SolressSerialDriver)
    if isconnected(dev)
        emergency_stop!(dev)
        sleep(0.05)
    end
    return nothing
end

function close_device!(dev::SolressSerialDriver)
    safe_state!(dev)
    close_solress_driver!(dev)
    return nothing
end

close_solress!(dev::SolressSerialDriver) = close_device!(dev)

# ------------------------------------------------------------------------------
# Port Discovery & Handshake (Finding H1)
# ------------------------------------------------------------------------------

"""
    detect_solress_ports()::Dict{String, String}

Dynamically identifies serial ports for ESP32 and USB-UART converters.
"""
function detect_solress_ports()::Dict{String, String}
    ports = Dict{String, String}()

    if Sys.iswindows()
        detected = detect_windows_com_ports()
        if haskey(detected, "esp32")
            ports["solress_mcu"] = detected["esp32"]
        end
        return ports
    end

    candidates = String[]
    if Sys.isapple()
        for p in ["/dev/cu.usbserial*", "/dev/cu.SLAB_USBtoUART*", "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*"]
            try
                for match in glob_ports(p)
                    push!(candidates, match)
                end
            catch
            end
        end
    else
        for p in ["/dev/ttyACM*", "/dev/ttyUSB*"]
            try
                for match in glob_ports(p)
                    push!(candidates, match)
                end
            catch
            end
        end
    end

    if !isempty(candidates)
        ports["solress_mcu"] = candidates[1]
    end
    return ports
end

function glob_ports(pattern::String)::Vector{String}
    d = dirname(pattern)
    prefix = replace(basename(pattern), "*" => "")
    matches = String[]
    if isdir(d)
        for f in readdir(d)
            if startswith(f, prefix)
                push!(matches, joinpath(d, f))
            end
        end
    end
    return matches
end

# ------------------------------------------------------------------------------
# Non-Blocking Background Reader (Finding H5)
# ------------------------------------------------------------------------------

function start_serial_reader_task!(driver::SolressSerialDriver, sp)
    driver.keep_running[] = true
    driver.reader_task = @async begin
        buf = UInt8[]
        while driver.keep_running[]
            try
                if isopen(sp) && bytesavailable(sp) > 0
                    chunk = read(sp)
                    append!(buf, chunk)
                    # Bound buffer to prevent memory exhaustion on corrupted stream
                    if length(buf) > 1024
                        idx = findlast(==(UInt8('\n')), buf)
                        buf = idx === nothing ? UInt8[] : buf[idx+1:end]
                    end
                    while true
                        idx = findfirst(==(UInt8('\n')), buf)
                        idx === nothing && break
                        line_bytes = buf[1:idx]
                        buf = buf[idx+1:end]
                        line = String(line_bytes)
                        process_incoming_line!(driver, line)
                    end
                else
                    sleep(0.01)
                end
            catch e
                if e isa EOFError || !isopen(sp)
                    driver.is_connected = false
                    @warn "SOLRESS serial connection lost: $e"
                    break
                end
                sleep(0.01)
            end
        end
    end
end

function start_mock_reader_task!(driver::SolressSerialDriver, mock_hw::MockSolressMCU)
    driver.keep_running[] = true
    driver.reader_task = @async begin
        while driver.keep_running[]
            try
                if isready(mock_hw.tx_channel)
                    line = take!(mock_hw.tx_channel)
                    process_incoming_line!(driver, line)
                else
                    sleep(0.005)
                end
            catch e
                @debug "Mock reader task exception: $e"
                sleep(0.005)
            end
        end
    end
end

"""
    open_solress_driver(; port_name::String="/dev/ttyACM0", baudrate::Int=115200,
                          mock::Bool=false, autodetect::Bool=false)::SolressSerialDriver
"""
function open_solress_driver(port_name::String="/dev/ttyACM0"; baudrate::Int=115200,
                               mock::Bool=false, autodetect::Bool=false)::SolressSerialDriver
    resolved_port = port_name
    if autodetect && !mock
        detected = detect_solress_ports()
        if haskey(detected, "solress_mcu")
            resolved_port = detected["solress_mcu"]
        end
    end

    driver = SolressSerialDriver(resolved_port, baudrate; is_mock=mock)

    if mock
        mock_hw = MockSolressMCU()
        start_mock_mcu!(mock_hw)
        driver.mock_mcu = mock_hw
        driver.is_connected = true
        driver.keep_running[] = true
        driver.last_comm_time[] = time()
        start_mock_reader_task!(driver, mock_hw)
    else
        try
            sp = LibSerialPort.open(resolved_port, baudrate)
            driver.port = sp
            driver.is_connected = true
            driver.keep_running[] = true
            driver.last_comm_time[] = time()
            start_serial_reader_task!(driver, sp)
        catch e
            @warn "Failed to open physical serial port $resolved_port: $e. Falling back to unconnected."
            driver.is_connected = false
        end
    end

    return driver
end

open_solress(args...; kwargs...) = open_solress_driver(args...; kwargs...)

function close_solress_driver!(driver::SolressSerialDriver)
    driver.keep_running[] = false
    driver.is_connected = false

    if driver.is_mock && driver.mock_mcu !== nothing
        stop_mock_mcu!(driver.mock_mcu)
    elseif driver.port !== nothing
        try
            LibSerialPort.close(driver.port)
        catch
        end
        driver.port = nothing
    end
end

# ------------------------------------------------------------------------------
# Packet Processing & Sequence-Numbered ACK Correlation (Finding H3, H6)
# ------------------------------------------------------------------------------

function process_incoming_line!(driver::SolressSerialDriver, line::AbstractString)
    parsed = parse_solress_packet(line)
    if !parsed.valid
        driver.error_count[] += 1
        return
    end

    driver.last_comm_time[] = time()

    if parsed.type == "TEL"
        try
            tel = parse_solress_telemetry(parsed.fields)
            lock(driver.lock) do
                driver.last_telemetry = tel
                # Finding H4: is_homed is strictly updated from telemetry, never blindly assumed
                driver.is_homed = tel.is_homed
            end
            channel_put_drop_oldest!(driver.telemetry_channel, tel)
        catch e
            driver.error_count[] += 1
        end
    elseif parsed.type == "ACK"
        # Check if sequence number is present: ACK,<seq>,<CMD>,<STATUS>
        ack_seq = UInt32(0)
        cmd_id = ""
        status = "OK"

        if length(parsed.fields) >= 4 && tryparse(UInt32, parsed.fields[2]) !== nothing
            ack_seq = parse(UInt32, parsed.fields[2])
            cmd_id = uppercase(parsed.fields[3])
            status = parsed.fields[4]
        elseif length(parsed.fields) >= 2
            cmd_id = uppercase(parsed.fields[2])
            status = length(parsed.fields) >= 3 ? parsed.fields[3] : "OK"
        end

        lock(driver.ack_cond) do
            # Sequence correlation takes precedence if pending_seq > 0
            match = if driver.pending_seq[] > 0
                ack_seq == driver.pending_seq[]
            else
                isempty(driver.pending_cmd_id[]) || driver.pending_cmd_id[] == cmd_id
            end

            if match
                driver.last_ack_response[] = status
                driver.ack_received[] = true
                notify(driver.ack_cond)
            end
        end
    elseif parsed.type == "ERR"
        err_seq = UInt32(0)
        cmd_id = ""
        reason = "ERROR"

        if length(parsed.fields) >= 4 && tryparse(UInt32, parsed.fields[2]) !== nothing
            err_seq = parse(UInt32, parsed.fields[2])
            cmd_id = uppercase(parsed.fields[3])
            reason = parsed.fields[4]
        elseif length(parsed.fields) >= 2
            cmd_id = uppercase(parsed.fields[2])
            reason = length(parsed.fields) >= 3 ? parsed.fields[3] : "ERROR"
        end

        driver.error_count[] += 1
        lock(driver.ack_cond) do
            match = if driver.pending_seq[] > 0
                err_seq == driver.pending_seq[]
            else
                isempty(driver.pending_cmd_id[]) || driver.pending_cmd_id[] == cmd_id
            end

            if match
                driver.last_ack_response[] = "ERR:" * reason
                driver.ack_received[] = true
                notify(driver.ack_cond)
            end
        end
    end
end

"""
    send_driver_command!(driver::SolressSerialDriver, cmd_payload::AbstractString; timeout_s::Float64=2.0)::String

Thread-safe command transmission with sequence numbers and unified ACK handling (Finding H3, H6).
"""
function send_driver_command!(driver::SolressSerialDriver, cmd_payload::AbstractString; timeout_s::Float64=2.0)::String
    if !driver.is_connected
        throw(DeviceNotConnected(driver.port_name))
    end

    # Increment command sequence counter for unambiguous ACK matching (Finding H3)
    seq = (driver.cmd_seq_counter[] += 1)
    tokens = split(strip(cmd_payload), ",")
    cmd_name = length(tokens) >= 2 ? uppercase(tokens[2]) : ""

    # Frame with sequence number: CMD,<seq>,<action>,<args...>
    seq_payload = if length(tokens) >= 2 && tokens[1] == "CMD"
        action_and_args = join(tokens[2:end], ",")
        "CMD,$seq,$action_and_args"
    else
        cmd_payload
    end

    packet = format_solress_packet(seq_payload)

    lock(driver.cmd_lock) do
        driver.pending_cmd_id[] = cmd_name
        driver.pending_seq[] = seq
        driver.last_ack_response[] = ""
        driver.ack_received[] = false

        if driver.is_mock && driver.mock_mcu !== nothing
            # Finding H6: Route mock commands through the exact same rx/tx and ACK correlation path
            channel_put_drop_oldest!(driver.mock_mcu.rx_channel, packet)
        else
            if driver.port === nothing || !isopen(driver.port)
                throw(DeviceNotConnected("Serial port is closed"))
            end
            lock(driver.lock) do
                write(driver.port, packet)
            end
        end

        t0 = time()
        tm = Timer(timeout_s) do _
            lock(driver.ack_cond) do
                notify(driver.ack_cond)
            end
        end

        lock(driver.ack_cond) do
            try
                while !driver.ack_received[] && (time() - t0) < timeout_s
                    wait(driver.ack_cond)
                end
            finally
                close(tm)
                driver.pending_cmd_id[] = ""
                driver.pending_seq[] = UInt32(0)
            end
        end

        if driver.ack_received[]
            if startswith(driver.last_ack_response[], "ERR:")
                throw(DeviceProtocolError("SOLRESS MCU command error: $(driver.last_ack_response[])"))
            end
            return driver.last_ack_response[]
        else
            throw(DeviceTimeout(driver.port_name, "command $(cmd_payload)", timeout_s))
        end
    end
end

# ------------------------------------------------------------------------------
# 5. High-Level Commands
# ------------------------------------------------------------------------------

"""
    set_valve_position!(driver::SolressSerialDriver, pos_pct::Real; timeout_s::Float64=2.0)::Bool
"""
function set_valve_position!(driver::SolressSerialDriver, pos_pct::Real; timeout_s::Float64=2.0)::Bool
    clamped = clamp(Float64(pos_pct), 0.0, 100.0)
    cmd = @sprintf("CMD,POS,%.2f", clamped)
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        return true
    catch e
        @debug "set_valve_position! failed" exception=e
        return false
    end
end

"""
    home_valve!(driver::SolressSerialDriver; timeout_s::Float64=10.0)::Bool
"""
function home_valve!(driver::SolressSerialDriver; timeout_s::Float64=10.0)::Bool
    cmd = "CMD,HOME"
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        # Note: driver.is_homed is updated from incoming telemetry or ACK, not fabricated (Finding H4)
        return true
    catch e
        @debug "home_valve! failed" exception=e
        return false
    end
end

"""
    emergency_stop!(driver::SolressSerialDriver; timeout_s::Float64=2.0)::Bool
"""
function emergency_stop!(driver::SolressSerialDriver; timeout_s::Float64=2.0)::Bool
    cmd = "CMD,ESTOP"
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        return true
    catch e
        @error "emergency_stop! failed" exception=e
        return false
    end
end

"""
    read_telemetry(driver::SolressSerialDriver)::Union{SOLRESSTelemetry, Nothing}
"""
function read_telemetry(driver::SolressSerialDriver)::Union{SOLRESSTelemetry, Nothing}
    lock(driver.lock) do
        return driver.last_telemetry
    end
end

"""
    is_healthy(driver::SolressSerialDriver)::Bool
"""
function is_healthy(driver::SolressSerialDriver)::Bool
    if !driver.is_connected
        return false
    end

    if (time() - driver.last_comm_time[]) > 5.0
        return false
    end

    tel = read_telemetry(driver)
    if tel !== nothing
        if tel.is_slip_detected || tel.is_overpressure || (tel.fault_code != 0)
            return false
        end
    end

    if driver.mock_mcu !== nothing && driver.mock_mcu.is_estop
        return false
    end

    return true
end

"""
    reconnect_solress_driver!(driver::SolressSerialDriver; max_retries::Int=3)::Bool
"""
function reconnect_solress_driver!(driver::SolressSerialDriver; max_retries::Int=3)::Bool
    if driver.is_mock
        driver.is_connected = true
        driver.keep_running[] = true
        driver.last_comm_time[] = time()
        if driver.mock_mcu !== nothing && (driver.reader_task === nothing || istaskdone(driver.reader_task))
            start_mock_reader_task!(driver, driver.mock_mcu)
        end
        return true
    end

    for _ in 1:max_retries
        try
            if driver.port !== nothing
                try LibSerialPort.close(driver.port) catch end
            end
            detected = detect_solress_ports()
            port = haskey(detected, "solress_mcu") ? detected["solress_mcu"] : driver.port_name
            sp = LibSerialPort.open(port, driver.baudrate)
            driver.port = sp
            driver.port_name = port
            driver.is_connected = true
            driver.keep_running[] = true
            driver.last_comm_time[] = time()

            if driver.reader_task === nothing || istaskdone(driver.reader_task)
                start_serial_reader_task!(driver, sp)
            end
            return true
        catch
            sleep(0.5)
        end
    end
    driver.is_connected = false
    return false
end

end # module Solress
