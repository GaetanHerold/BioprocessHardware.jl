# ==============================================================================
# SOLRESS Counterpressure Valve MCU — Host Serial Driver & Mock Hardware
# ==============================================================================
# Manages bidirectional USB-serial communication with the ESP32 MCU,
# background telemetry streaming at 10 Hz, CRC-16-CCITT validation,
# thread-safe actuator dispatch, and in-memory simulated hardware.
# ==============================================================================

using LibSerialPort
using Dates
using Printf

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

    # Validate non-empty body (matching C++ firmware INVALID_BODY_LENGTH)
    if isempty(body) || length(body) == 0
        return (valid=false, type="", fields=String[], raw_crc=String(crc_str), error="EMPTY_BODY", error_reason="EMPTY_BODY")
    end

    # Validate CRC format (must be exactly 4 hex characters)
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

Decodes comma-separated fields from a validated `\$TEL` frame.
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

"""
    channel_put_drop_oldest!(channel::Channel{T}, item) where T

Thread-safe circular channel write that drops the oldest unread element
if the channel is at capacity (`Base.n_avail(channel) >= channel.sz_max`).
Guarantees that `put!` never blocks the calling thread or task, preventing
deadlocks when called while holding locks (such as `MockSolressMCU.lock`).
"""
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

"""
    MockSolressMCU

High-fidelity in-memory simulated SOLRESS ESP32 MCU.
Emulates stepper dynamics, AS5600 encoder unwrapping, gentle stall-homing,
packet decoding, CRC validation, and 10 Hz telemetry streaming.
"""
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
            0,                      # target_steps
            0,                      # actual_steps
            0.0,                    # valve_pct
            pressure_bar,           # pressure_bar
            level_mm,               # level_mm
            0,                      # raw_angle
            0,                      # turns
            false,                  # is_homed
            false,                  # is_moving
            false,                  # is_slip_detected
            false,                  # is_estop
            false,                  # is_overpressure
            1000.0,                 # motor_speed_sps
            UInt32(0),              # sequence
            time(),                 # start_time
            Channel{String}(64),    # rx_channel (NUC -> Mock)
            Channel{String}(128),   # tx_channel (Mock -> NUC)
            Ref{Bool}(false),       # keep_running
            nothing,                # sim_task
            ReentrantLock()         # lock
        )
    end
end

# Property Accessors supporting simulated_pressure_bar, target_microsteps, actual_microsteps, and max_microsteps
function Base.getproperty(mock::MockSolressMCU, s::Symbol)
    if s === :simulated_pressure_bar
        return getfield(mock, :pressure_bar)
    elseif s === :target_microsteps
        return getfield(mock, :target_steps)
    elseif s === :actual_microsteps
        return getfield(mock, :actual_steps)
    elseif s === :max_microsteps
        return VALVE_STROKE_STEPS
    else
        return getfield(mock, s)
    end
end

function Base.setproperty!(mock::MockSolressMCU, s::Symbol, val)
    if s === :simulated_pressure_bar
        return setfield!(mock, :pressure_bar, Float64(val))
    elseif s === :target_microsteps
        return setfield!(mock, :target_steps, Int(val))
    elseif s === :actual_microsteps
        return setfield!(mock, :actual_steps, Int(val))
    elseif s === :max_microsteps
        error("Property :max_microsteps is read-only")
    else
        return setfield!(mock, s, convert(fieldtype(MockSolressMCU, s), val))
    end
end

function Base.propertynames(::MockSolressMCU, private::Bool=false)
    return (fieldnames(MockSolressMCU)..., :simulated_pressure_bar, :target_microsteps, :actual_microsteps, :max_microsteps)
end

"""
    start_mock_mcu!(mock::MockSolressMCU)

Starts background 50 Hz simulation and 10 Hz telemetry streaming on mock MCU.
"""
function start_mock_mcu!(mock::MockSolressMCU)
    mock.keep_running[] = true
    emit_mock_telemetry!(mock)
    mock.sim_task = @async begin
        dt = 0.02 # 50 Hz simulation tick
        last_tel_time = time()
        while mock.keep_running[]
            t0 = time()
            try
                step_simulation!(mock, dt)

                # Emit 10 Hz telemetry
                now_t = time()
                if (now_t - last_tel_time) >= 0.10
                    last_tel_time = now_t
                    emit_mock_telemetry!(mock)
                end
            catch e
                @debug "Mock MCU loop error: $e"
            end

            elapsed = time() - t0
            sleep_time = max(0.001, dt - elapsed)
            sleep(sleep_time)
        end
    end
    return mock
end

"""
    stop_mock_mcu!(mock::MockSolressMCU)
"""
function stop_mock_mcu!(mock::MockSolressMCU)
    mock.keep_running[] = false
    if mock.sim_task !== nothing
        try
            # Yield to give task time to exit
            sleep(0.05)
        catch
        end
    end
end

"""
    step_simulation!(mock::MockSolressMCU, dt::Float64)

Executes one tick of physics, autonomous safety watchdog, and command processing for the mock MCU.
Matches ESP32 FreeRTOS dual-core tasks: Task_SensorSampling (Core 1) and Task_SafetyWatchdog (Core 0).
"""
function step_simulation!(mock::MockSolressMCU, dt::Float64)
    lock(mock.lock) do
        # 1. Process incoming commands from NUC
        while isready(mock.rx_channel)
            raw_line = take!(mock.rx_channel)
            process_mock_command!(mock, raw_line)
        end

        # 2. Autonomous Safety Watchdog: Critical Overpressure Trip (P >= 0.60 bar)
        # Directly emulates ESP32 main.cpp lines 202-210 and motor.cpp emergencyStop()
        if mock.simulated_pressure_bar >= OVERPRESSURE_TRIP_BAR
            mock.is_overpressure = true
            mock.is_estop = true
            mock.target_microsteps = mock.max_microsteps
            mock.actual_microsteps = mock.max_microsteps
            mock.valve_pct = 100.0
            mock.is_moving = false
        elseif mock.actual_steps != mock.target_steps && !mock.is_slip_detected && !mock.is_estop
            # 3. Update motor motion towards target (inhibited if slip or E-stop is latched)
            mock.is_moving = true
            max_delta = round(Int, mock.motor_speed_sps * dt)
            err = mock.target_steps - mock.actual_steps
            if abs(err) <= max_delta
                mock.actual_steps = mock.target_steps
                mock.is_moving = false
            else
                mock.actual_steps += sign(err) * max_delta
            end
        else
            mock.is_moving = false
        end

        # 4. Synchronize valve percentage and AS5600 encoder registers
        mock.valve_pct = clamp((mock.actual_steps / 19200.0) * 100.0, 0.0, 100.0)
        total_encoder_counts = round(Int, mock.actual_steps * 1.28)
        mock.turns = total_encoder_counts ÷ 4096
        mock.raw_angle = mod(total_encoder_counts, 4096)
    end
end

"""
    process_mock_command!(mock::MockSolressMCU, line::AbstractString)
"""
function process_mock_command!(mock::MockSolressMCU, line::AbstractString)
    parsed = parse_solress_packet(line)
    if !parsed.valid
        err_resp = format_solress_packet("ERR,PKT,$(parsed.error)")
        channel_put_drop_oldest!(mock.tx_channel, err_resp)
        return
    end

    if parsed.type != "CMD" || length(parsed.fields) < 2
        err_resp = format_solress_packet("ERR,PKT,UNRECOGNIZED")
        channel_put_drop_oldest!(mock.tx_channel, err_resp)
        return
    end

    cmd_name = uppercase(parsed.fields[2])
    if cmd_name == "PING"
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,PING,OK"))
    elseif cmd_name == "POS"
        if length(parsed.fields) >= 3
            val_pct = tryparse(Float64, parsed.fields[3])
            if val_pct === nothing || val_pct < 0.0 || val_pct > 100.0
                channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ERR,POS,OUT_OF_RANGE"))
            else
                mock.target_steps = round(Int, (val_pct / 100.0) * 19200)
                channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,POS,OK"))
            end
        else
            channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ERR,POS,MISSING_ARG"))
        end
    elseif cmd_name == "HOME"
        # Gentle stall-homing simulation
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,HOME,STARTED"))
        mock.actual_steps = 160 # 18 deg relief position
        mock.target_steps = 160
        mock.is_homed = true
        mock.is_slip_detected = false
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,HOME,SUCCESS"))
    elseif cmd_name == "ESTOP"
        mock.is_estop = true
        mock.target_steps = 19200
        mock.actual_steps = 19200
        mock.valve_pct = 100.0
        mock.is_moving = false
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,ESTOP,SAFE"))
    elseif cmd_name == "CFG"
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ACK,CFG,UPDATED"))
    else
        channel_put_drop_oldest!(mock.tx_channel, format_solress_packet("ERR,$(cmd_name),UNKNOWN"))
    end
end

"""
    emit_mock_telemetry!(mock::MockSolressMCU)
"""
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
# 4. SolressSerialDriver Host Interface
# ------------------------------------------------------------------------------

"""
    SolressSerialDriver

Host hardware driver managing USB-serial connection, background reader task,
thread-safe command dispatch, and auto-reconnection.
"""
mutable struct SolressSerialDriver
    port_name::String
    baudrate::Int
    port::Any
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
    last_ack_response::Ref{String}
    ack_received::Ref{Bool}

    function SolressSerialDriver(port_name::String, baudrate::Int=115200; is_mock::Bool=false)
        new(
            port_name,
            baudrate,
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
            Ref{String}(""),
            Ref{Bool}(false)
        )
    end
end

"""
    detect_solress_ports()::Dict{String, String}

Dynamically identifies serial ports for ESP32 and USB-UART converters
across macOS, Linux, and Windows to prevent port swapping.
"""
function detect_solress_ports()::Dict{String, String}
    ports = Dict{String, String}()

    if Sys.iswindows()
        # Fall back to existing Windows detection
        return detect_windows_com_ports()
    end

    # macOS & Linux dynamic scan
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
    else # Linux
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

"""
    start_serial_reader_task!(driver::SolressSerialDriver, sp)

Spawns the background serial port reader task reading from physical UART.
"""
function start_serial_reader_task!(driver::SolressSerialDriver, sp)
    driver.keep_running[] = true
    driver.reader_task = @async begin
        while driver.keep_running[]
            try
                if isopen(sp) && bytesavailable(sp) > 0
                    line = readline(sp)
                    process_incoming_line!(driver, line)
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

"""
    start_mock_reader_task!(driver::SolressSerialDriver, mock_hw::MockSolressMCU)

Spawns the background reader task reading from the in-memory mock MCU TX channel.
"""
function start_mock_reader_task!(driver::SolressSerialDriver, mock_hw::MockSolressMCU)
    driver.keep_running[] = true
    driver.reader_task = @async begin
        while driver.keep_running[]
            try
                if isready(mock_hw.tx_channel)
                    line = take!(mock_hw.tx_channel)
                    process_incoming_line!(driver, line)
                else
                    sleep(0.01)
                end
            catch e
                @debug "Mock reader task exception: $e"
                sleep(0.01)
            end
        end
    end
end

"""
    open_solress_driver(; port_name::String="/dev/ttyACM0", baudrate::Int=115200,
                          mock::Bool=false, autodetect::Bool=false)::SolressSerialDriver

Opens the SOLRESS MCU serial driver. If `mock=true`, creates an in-memory
high-fidelity simulation without requiring physical USB hardware.
"""
function open_solress_driver(; port_name::String="/dev/ttyACM0", baudrate::Int=115200,
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

"""
    close_solress_driver!(driver::SolressSerialDriver)

Gracefully closes the driver, background reader task, and underlying port/mock.
"""
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

"""
    process_incoming_line!(driver::SolressSerialDriver, line::AbstractString)

Validates CRC-16-CCITT and dispatches parsed packets to telemetry channel.
"""
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
                driver.is_homed = tel.is_homed
            end
            channel_put_drop_oldest!(driver.telemetry_channel, tel)
        catch e
            driver.error_count[] += 1
        end
    elseif parsed.type == "ACK"
        cmd_id = length(parsed.fields) >= 2 ? uppercase(parsed.fields[2]) : ""
        status = length(parsed.fields) >= 3 ? parsed.fields[3] : "OK"
        lock(driver.ack_cond) do
            if isempty(driver.pending_cmd_id[]) || driver.pending_cmd_id[] == cmd_id
                driver.last_ack_response[] = status
                driver.ack_received[] = true
                notify(driver.ack_cond)
            end
        end
    elseif parsed.type == "ERR"
        cmd_id = length(parsed.fields) >= 2 ? uppercase(parsed.fields[2]) : ""
        reason = length(parsed.fields) >= 3 ? parsed.fields[3] : "ERROR"
        driver.error_count[] += 1
        lock(driver.ack_cond) do
            if isempty(driver.pending_cmd_id[]) || driver.pending_cmd_id[] == cmd_id
                driver.last_ack_response[] = "ERR:" * reason
                driver.ack_received[] = true
                notify(driver.ack_cond)
            end
        end
    end
end

"""
    send_driver_command!(driver::SolressSerialDriver, cmd_payload::AbstractString; timeout_s::Float64=2.0)::String

Thread-safe command transmission with CRC framing and response waiting.
"""
function send_driver_command!(driver::SolressSerialDriver, cmd_payload::AbstractString; timeout_s::Float64=2.0)::String
    if !driver.is_connected
        error("SOLRESS driver is not connected to MCU")
    end

    packet = format_solress_packet(cmd_payload)

    # 1. Fast Mock Path (< 0.001s latency)
    if driver.is_mock && driver.mock_mcu !== nothing
        channel_put_drop_oldest!(driver.mock_mcu.rx_channel, packet)
        lock(driver.mock_mcu.lock) do
            while isready(driver.mock_mcu.rx_channel)
                raw_line = take!(driver.mock_mcu.rx_channel)
                process_mock_command!(driver.mock_mcu, raw_line)
            end
        end
        return "OK"
    end

    # 2. Real Hardware Path with Synchronous ACK Handling
    if driver.port === nothing || !isopen(driver.port)
        error("Serial port is closed")
    end

    tokens = split(strip(cmd_payload), ",")
    expected_id = length(tokens) >= 2 ? uppercase(tokens[2]) : ""

    lock(driver.cmd_lock) do
        driver.pending_cmd_id[] = expected_id
        driver.last_ack_response[] = ""
        driver.ack_received[] = false

        lock(driver.lock) do
            write(driver.port, packet)
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
            end
        end

        if driver.ack_received[]
            if startswith(driver.last_ack_response[], "ERR:")
                error("SOLRESS MCU command error: $(driver.last_ack_response[])")
            end
            return driver.last_ack_response[]
        else
            error("Timeout waiting for ACK response for command $(cmd_payload) after $(timeout_s)s")
        end
    end
end

"""
    set_valve_position!(driver::SolressSerialDriver, pos_pct::Real; timeout_s::Float64=2.0)::Bool

Commands valve position (0.0% = hard seated, 100.0% = fully open).
"""
function set_valve_position!(driver::SolressSerialDriver, pos_pct::Real; timeout_s::Float64=2.0)::Bool
    clamped = clamp(Float64(pos_pct), 0.0, 100.0)
    cmd = @sprintf("CMD,POS,%.2f", clamped)
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        return true
    catch
        return false
    end
end

"""
    home_valve!(driver::SolressSerialDriver; timeout_s::Float64=10.0)::Bool

Commands gentle stall-homing sequence on the MCU.
"""
function home_valve!(driver::SolressSerialDriver; timeout_s::Float64=10.0)::Bool
    cmd = "CMD,HOME"
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        driver.is_homed = true
        return true
    catch
        return false
    end
end

"""
    emergency_stop!(driver::SolressSerialDriver; timeout_s::Float64=2.0)::Bool

Commands emergency valve release (opens valve to 100% and halts movement).
"""
function emergency_stop!(driver::SolressSerialDriver; timeout_s::Float64=2.0)::Bool
    cmd = "CMD,ESTOP"
    try
        send_driver_command!(driver, cmd; timeout_s=timeout_s)
        return true
    catch
        return false
    end
end

"""
    read_telemetry(driver::SolressSerialDriver)::Union{SOLRESSTelemetry, Nothing}

Returns the latest received telemetry frame, or `nothing` if none received.
"""
function read_telemetry(driver::SolressSerialDriver)::Union{SOLRESSTelemetry, Nothing}
    lock(driver.lock) do
        return driver.last_telemetry
    end
end

"""
    is_healthy(driver::SolressSerialDriver)::Bool

Evaluates driver health: verified connection, recent heartbeat (< 5.0 s),
and absence of fatal hardware faults.
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

Attempts auto-reconnection if serial connection is dropped. Restarts the
background reader task to ensure telemetry streaming resumes immediately.
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

    for attempt in 1:max_retries
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

            # Restart reader_task if dead/done
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
