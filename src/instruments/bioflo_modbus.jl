# ============================================================================
# BIOFLO MODBUS TCP CLIENT & BIOREACTOR CONTROLLER DRIVER
# ============================================================================
# Driver for Eppendorf BioFlo 120 / 320 bioprocess controllers over Modbus TCP.
# Implements robust MBAP header validation, non-blocking exception frames,
# readback verification on actuator setpoints, and safe-off on close.
# ============================================================================

module BioFloModbus

using Sockets
using Dates
using Printf

using ..BioprocessHardware: AbstractActuator, AbstractTransport, SerialTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_FAULT, STATUS_OVERRANGE, STATUS_UNDERRANGE, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_FAULT
using ..BioprocessHardware: SetpointResult, DeviceError, DeviceTimeout, DeviceProtocolError, DeviceFault, DeviceNotConnected
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, write_setpoint!, safe_state!, close_device!

export BioFloConn, BioFloDevice, open_bioflo, close_bioflo!
export float32_to_bytes, bytes_to_float32, read_float_register, write_float_register
export bioflo_close!, read_bioflo_measurements
export run_bioflo_monitor_task!, run_bioflo_pwm_task!, run_mock_pump2_task!
export read_with_timeout, BIOFLO_PUMP_DEFAULT_RPM, BIOFLO_PUMP_CALIBRATION_ML_PER_REV
export pump_rpm_to_flow_ml_min, pump_flow_ml_min_to_rpm
export REG_TEMP, REG_PH, REG_DCO2, REG_PUMP1, REG_PUMP2, REG_PUMP3
export ModbusException, ModbusTimeout

# ----------------------------------------------------------------------------
# 1. Modbus Register Map Constants (Finding H8)
# ----------------------------------------------------------------------------

const REG_TEMP   = UInt16(2)   # Float32: Bioreactor Temperature (°C)
const REG_PH     = UInt16(4)   # Float32: Fermenter pH
const REG_DCO2   = UInt16(48)  # Float32: Dissolved CO2 reading
const REG_PUMP1  = UInt16(76)  # Float32: Peristaltic Pump 1 setpoint (rpm)
const REG_PUMP2  = UInt16(78)  # Float32: Peristaltic Pump 2 setpoint (rpm)
const REG_PUMP3  = UInt16(80)  # Float32: Peristaltic Pump 3 setpoint (rpm)

const BIOFLO_PUMP_DEFAULT_RPM = Float32(18.8)
const BIOFLO_PUMP_CALIBRATION_ML_PER_REV = 1.0

# ----------------------------------------------------------------------------
# 2. Typed Exceptions (Finding H9)
# ----------------------------------------------------------------------------

struct ModbusTimeout <: DeviceError
    device::String
    operation::String
    timeout_s::Float64
end
Base.showerror(io::IO, e::ModbusTimeout) =
    print(io, "ModbusTimeout: $(e.device) timed out during $(e.operation) after $(e.timeout_s) s")

struct ModbusException <: DeviceError
    function_code::UInt8
    exception_code::UInt8
    message::String
end
function ModbusException(fc::UInt8, code::UInt8)
    msg = code == 0x01 ? "ILLEGAL_FUNCTION" :
          code == 0x02 ? "ILLEGAL_DATA_ADDRESS" :
          code == 0x03 ? "ILLEGAL_DATA_VALUE" :
          code == 0x04 ? "SLAVE_DEVICE_FAILURE" : "UNKNOWN_EXCEPTION"
    return ModbusException(fc, code, msg)
end
Base.showerror(io::IO, e::ModbusException) =
    print(io, "ModbusException: FC=0x$(string(e.function_code, base=16)) code=0x$(string(e.exception_code, base=16)) ($(e.message))")

# ----------------------------------------------------------------------------
# 3. Connection & Framing
# ----------------------------------------------------------------------------

mutable struct BioFloConn
    ip::String
    port::Int
    unit_id::UInt8
    socket::Union{TCPSocket, Nothing}
    tid::UInt16
    lock::ReentrantLock
    connected::Bool
end

function BioFloConn(ip::String="127.0.0.1", port::Int=502, unit_id::Int=1)
    return BioFloConn(ip, port, UInt8(unit_id), nothing, UInt16(0), ReentrantLock(), false)
end

function _bioflo_connect!(conn::BioFloConn; timeout_s::Float64=2.0)::Bool
    try
        if conn.socket !== nothing
            try close(conn.socket) catch; end
        end
        # Finding H7: Connect with timeout to prevent thread hangs
        t_start = time()
        sock = TCPSocket()
        connect_task = @async connect(sock, conn.ip, conn.port)
        while !istaskdone(connect_task)
            if (time() - t_start) > timeout_s
                try close(sock) catch; end
                @warn "BioFlo TCP connection timed out after $(timeout_s)s" ip=conn.ip port=conn.port
                conn.socket = nothing
                conn.connected = false
                return false
            end
            sleep(0.01)
        end
        sock = fetch(connect_task)
        conn.socket = sock
        conn.connected = true
        return true
    catch e
        conn.socket = nothing
        conn.connected = false
        @warn "BioFlo TCP connection failed" ip=conn.ip port=conn.port exception=e
        return false
    end
end

function bioflo_close!(conn::BioFloConn)
    conn.connected = false
    if conn.socket !== nothing
        try close(conn.socket) catch; end
        conn.socket = nothing
    end
end

@inline function _next_tid!(conn::BioFloConn)::UInt16
    conn.tid = UInt16((UInt32(conn.tid) + UInt32(1)) & 0xFFFF)
    return conn.tid
end

function bytes_to_float32(b::Vector{UInt8})
    length(b) == 4 || error("Requires exactly 4 bytes")
    u = (UInt32(b[1]) << 24) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 8) | UInt32(b[4])
    return reinterpret(Float32, u)
end

function float32_to_bytes(f::Float32)
    buf = IOBuffer()
    write(buf, hton(f))
    return take!(buf)
end

"""
    read_with_timeout(socket::IO, n_bytes::Int, timeout_s::Float64=5.0)::Vector{UInt8}
"""
function read_with_timeout(socket::IO, n_bytes::Int, timeout_s::Float64=5.0)::Vector{UInt8}
    buf = Vector{UInt8}(undef, n_bytes)
    t_start = time()
    bytes_read = 0
    while bytes_read < n_bytes
        remaining = n_bytes - bytes_read
        task = @async readbytes!(socket, view(buf, (bytes_read + 1):n_bytes), remaining)
        while !istaskdone(task)
            if (time() - t_start) > timeout_s
                try
                    close(socket)
                catch
                end
                error("Socket read timeout ($timeout_s seconds) after receiving $bytes_read/$n_bytes bytes")
            end
            sleep(0.005)
        end
        istaskfailed(task) && throw(TaskFailedException(task))
        n = fetch(task)
        if n == 0
            return buf[1:bytes_read]
        end
        bytes_read += n
    end
    return buf
end

# ----------------------------------------------------------------------------
# 4. Modbus Protocol Logic (Finding B3 & H7)
# ----------------------------------------------------------------------------

function _modbus_read_regs!(conn::BioFloConn, start_addr::UInt16, count::UInt16)::Union{Vector{UInt8}, Nothing}
    if !conn.connected || conn.socket === nothing
        if !_bioflo_connect!(conn)
            return nothing
        end
    end
    tid = _next_tid!(conn)
    req = UInt8[
        (tid >> 8) & 0xFF, tid & 0xFF,
        0x00, 0x00,
        0x00, 0x06,
        conn.unit_id,
        0x03,
        (start_addr >> 8) & 0xFF, start_addr & 0xFF,
        (count >> 8) & 0xFF, count & 0xFF,
    ]
    try
        write(conn.socket, req)

        # Read 7-byte MBAP header: [tid(2), proto(2), len(2), unit_id(1)]
        mbap = read_with_timeout(conn.socket, 7)
        length(mbap) < 7 && error("Incomplete Modbus MBAP header")

        resp_tid = (UInt16(mbap[1]) << 8) | UInt16(mbap[2])
        resp_proto = (UInt16(mbap[3]) << 8) | UInt16(mbap[4])
        resp_len = (UInt16(mbap[5]) << 8) | UInt16(mbap[6])
        resp_unit = mbap[7]

        # Header validation (Finding H7)
        resp_tid != tid && error("Modbus TID mismatch: expected $tid, got $resp_tid")
        resp_proto != 0x0000 && error("Modbus Protocol ID error: expected 0x0000, got $resp_proto")
        resp_unit != conn.unit_id && error("Modbus Unit ID mismatch")

        # Read remaining body: resp_len - 1 bytes (since unit_id was already read)
        body_len = Int(resp_len) - 1
        body = read_with_timeout(conn.socket, body_len)
        length(body) < body_len && error("Incomplete Modbus response body")

        fc = body[1]
        # Check exception response (Finding B3)
        if (fc & 0x80) != 0
            exc_code = length(body) >= 2 ? body[2] : 0x00
            @warn "Modbus FC03 exception response" fc=fc code=exc_code
            throw(ModbusException(fc, exc_code))
        end

        byte_count = Int(body[2])
        expected_bytes = Int(count) * 2
        byte_count != expected_bytes && error("Modbus byte count mismatch: expected $expected_bytes, got $byte_count")

        data = body[3:end]
        length(data) < byte_count && error("Incomplete register data")
        return data
    catch e
        @warn "Modbus read error — will reconnect" exception=e
        bioflo_close!(conn)
        return nothing
    end
end

function _modbus_write_regs!(conn::BioFloConn, start_addr::UInt16, count::UInt16, data::Vector{UInt8})::Bool
    if !conn.connected || conn.socket === nothing
        if !_bioflo_connect!(conn)
            return false
        end
    end
    byte_count = UInt8(length(data))
    tid = _next_tid!(conn)
    req = UInt8[
        (tid >> 8) & 0xFF, tid & 0xFF,
        0x00, 0x00,
        (6 + byte_count) >> 8 & 0xFF, (6 + byte_count) & 0xFF,
        conn.unit_id,
        0x10,
        (start_addr >> 8) & 0xFF, start_addr & 0xFF,
        (count >> 8) & 0xFF, count & 0xFF,
        byte_count,
    ]
    append!(req, data)
    try
        write(conn.socket, req)

        # Read 7-byte MBAP header
        mbap = read_with_timeout(conn.socket, 7)
        length(mbap) < 7 && error("Incomplete Modbus write MBAP header")

        resp_len = (UInt16(mbap[5]) << 8) | UInt16(mbap[6])
        body_len = Int(resp_len) - 1
        body = read_with_timeout(conn.socket, body_len)
        length(body) < body_len && error("Incomplete Modbus write response body")

        fc = body[1]
        if (fc & 0x80) != 0
            exc_code = length(body) >= 2 ? body[2] : 0x00
            @warn "Modbus write exception response" fc=fc code=exc_code
            return false
        end
        return true
    catch e
        @warn "Modbus write error — will reconnect" exception=e
        bioflo_close!(conn)
        return false
    end
end

function read_float_register(conn::BioFloConn, start_addr::UInt16)
    lock(conn.lock) do
        bytes = _modbus_read_regs!(conn, start_addr, UInt16(2))
        if bytes === nothing
            error("Failed to read float register at $start_addr")
        end
        return bytes_to_float32(bytes)
    end
end

function write_float_register(conn::BioFloConn, start_addr::UInt16, val::Float32)
    lock(conn.lock) do
        bytes = float32_to_bytes(val)
        return _modbus_write_regs!(conn, start_addr, UInt16(2), bytes)
    end
end

function read_bioflo_measurements(conn::BioFloConn)
    lock(conn.lock) do
        bytes1 = _modbus_read_regs!(conn, REG_TEMP, UInt16(4))
        if bytes1 === nothing
            error("Failed to read Temp and pH registers")
        end
        T_ferm  = bytes_to_float32(bytes1[1:4])
        pH_ferm = bytes_to_float32(bytes1[5:8])
        
        bytes2 = _modbus_read_regs!(conn, REG_DCO2, UInt16(2))
        if bytes2 === nothing
            error("Failed to read dCO2 register")
        end
        dco2_ferm = bytes_to_float32(bytes2)
        
        return Float64(pH_ferm), Float64(T_ferm), Float64(dco2_ferm)
    end
end

# ----------------------------------------------------------------------------
# 5. High-Level BioFloDevice Driver (implements AbstractActuator)
# ----------------------------------------------------------------------------

mutable struct BioFloDevice <: AbstractActuator
    conn::BioFloConn
    is_mock::Bool
    mock_connected::Bool
    mock_registers::Dict{UInt16, Float32}
    info::DeviceInfo
    lock::ReentrantLock
end

function BioFloDevice(ip::String="127.0.0.1", port::Int=502; unit_id::Int=1, mock::Bool=false)
    info = DeviceInfo(vendor="Eppendorf", model="BioFlo 120/320", serial="$ip:$port",
                      firmware="1.0", port="$ip:$port", driver="BioFloModbus")
    mock_regs = Dict{UInt16, Float32}(
        REG_TEMP => 37.0f0,
        REG_PH => 7.0f0,
        REG_DCO2 => 50.0f0,
        REG_PUMP1 => 0.0f0,
        REG_PUMP2 => 0.0f0,
        REG_PUMP3 => 0.0f0
    )
    conn = BioFloConn(ip, port, unit_id)
    return BioFloDevice(conn, mock, mock, mock_regs, info, ReentrantLock())
end

isconnected(dev::BioFloDevice) = dev.is_mock ? dev.mock_connected : dev.conn.connected

identify(dev::BioFloDevice) = dev.info

function healthcheck(dev::BioFloDevice)
    isconnected(dev) || return Health(HEALTH_FAULT, "BioFlo not connected")
    return Health(HEALTH_OK)
end

function read_measurement(dev::BioFloDevice)::Reading
    isconnected(dev) || throw(DeviceNotConnected(dev.info.port))
    if dev.is_mock
        p1 = Float64(get(dev.mock_registers, REG_PUMP1, 0.0f0))
        p2 = Float64(get(dev.mock_registers, REG_PUMP2, 0.0f0))
        p3 = Float64(get(dev.mock_registers, REG_PUMP3, 0.0f0))
        pH = Float64(get(dev.mock_registers, REG_PH, 7.0f0))
        T  = Float64(get(dev.mock_registers, REG_TEMP, 37.0f0))
        dco2 = Float64(get(dev.mock_registers, REG_DCO2, 50.0f0))
        val = (pump1_rpm=p1, pump2_rpm=p2, pump3_rpm=p3, pH=pH, temp_C=T, dco2_val=dco2)
        units = (pump1_rpm="rpm", pump2_rpm="rpm", pump3_rpm="rpm", pH="", temp_C="°C", dco2_val="%")
        return Reading(val; units=units, status=STATUS_OK, source=dev.info)
    end

    pH, T, dco2 = read_bioflo_measurements(dev.conn)
    p1 = Float64(read_float_register(dev.conn, REG_PUMP1))
    p2 = Float64(read_float_register(dev.conn, REG_PUMP2))
    p3 = Float64(read_float_register(dev.conn, REG_PUMP3))
    val = (pump1_rpm=p1, pump2_rpm=p2, pump3_rpm=p3, pH=pH, temp_C=T, dco2_val=dco2)
    units = (pump1_rpm="rpm", pump2_rpm="rpm", pump3_rpm="rpm", pH="", temp_C="°C", dco2_val="%")
    return Reading(val; units=units, status=STATUS_OK, source=dev.info)
end

function write_setpoint!(dev::BioFloDevice, rpm::Real)
    isconnected(dev) || throw(DeviceNotConnected(dev.info.port))
    val = Float64(rpm)
    if val < 0.0 || val > 100.0
        cur = dev.is_mock ? Float64(get(dev.mock_registers, REG_PUMP1, 0.0f0)) : 0.0
        return SetpointResult(false, val, cur, 0, "pump rpm out of bounds [0, 100]")
    end

    if dev.is_mock
        dev.mock_registers[REG_PUMP1] = Float32(val)
        return SetpointResult(true, val, val, 1, "applied")
    end

    # Write and read back to verify (Finding S3)
    ok = write_float_register(dev.conn, REG_PUMP1, Float32(val))
    if !ok
        return SetpointResult(false, val, 0.0, 1, "write failed")
    end
    # Read-back verification
    readback = Float64(read_float_register(dev.conn, REG_PUMP1))
    verified = isapprox(readback, val; atol=0.1)
    return SetpointResult(verified, val, readback, 1, verified ? "applied" : "readback mismatch")
end

function safe_state!(dev::BioFloDevice)
    if dev.is_mock
        dev.mock_registers[REG_PUMP1] = 0.0f0
        dev.mock_registers[REG_PUMP2] = 0.0f0
        dev.mock_registers[REG_PUMP3] = 0.0f0
        return nothing
    end

    if isconnected(dev)
        try
            write_float_register(dev.conn, REG_PUMP1, 0.0f0)
            write_float_register(dev.conn, REG_PUMP2, 0.0f0)
            write_float_register(dev.conn, REG_PUMP3, 0.0f0)
        catch e
            @warn "Failed to set BioFlo pumps to safe 0 rpm" exception=e
        end
    end
    return nothing
end

function close_device!(dev::BioFloDevice)
    safe_state!(dev)
    if dev.is_mock
        dev.mock_connected = false
    else
        bioflo_close!(dev.conn)
    end
    return nothing
end

close_bioflo!(dev::BioFloDevice) = close_device!(dev)

function open_bioflo(ip::String="127.0.0.1", port::Int=502; unit_id::Int=1, mock::Bool=false)::BioFloDevice
    dev = BioFloDevice(ip, port; unit_id=unit_id, mock=mock)
    if !mock
        _bioflo_connect!(dev.conn)
    end
    return dev
end

# ----------------------------------------------------------------------------
# 6. Background Tasks & Utilities
# ----------------------------------------------------------------------------

function run_bioflo_monitor_task!(
    keep_running::Ref{Bool},
    params::Dict{String,Any},
    conn::BioFloConn,
    latest_bioflo_data_ref::Ref
)
    sleep(2.0)
    while keep_running[]
        try
            pH, T, dCO2 = read_bioflo_measurements(conn)
            latest_bioflo_data_ref[] = (pH_ferm=pH, T_ferm=T, dco2_measured=dCO2, last_update=now())
        catch e
            if !occursin("timeout", string(e))
                @warn "BioFlo monitor unexpected error" exception=e
            end
        end
        sleep(2.0)
    end
end

function pump_rpm_to_flow_ml_min(rpm::Real; k_pump::Real=BIOFLO_PUMP_CALIBRATION_ML_PER_REV)::Float64
    return Float64(rpm) * Float64(k_pump)
end

function pump_flow_ml_min_to_rpm(flow_ml_min::Real; k_pump::Real=BIOFLO_PUMP_CALIBRATION_ML_PER_REV)::Float32
    return Float32(flow_ml_min / k_pump)
end

function run_bioflo_pwm_task!(
    duty_ref::Ref{Float64},
    keep_running::Ref{Bool},
    params::Dict{String,Any},
    conn::BioFloConn;
    window_ref::Ref{Float64}=Ref(120.0),
    min_on_ref::Ref{Float64}=Ref(20.0),
    min_off_ref::Ref{Float64}=Ref(20.0)
)
    pump_rpm = Float32(get(params, "bioflo_pump_rpm", BIOFLO_PUMP_DEFAULT_RPM))

    function set_bioflo_pumps(state::Bool)
        val = state ? pump_rpm : Float32(0.0)
        try
            write_float_register(conn, REG_PUMP1, val)
            sleep(0.1)
            write_float_register(conn, REG_PUMP3, val)
        catch e
            @warn "Failed to write CO2 pumps on BioFlo Modbus TCP" exception=e
        end
    end
    
    try
        set_bioflo_pumps(false)
        while keep_running[]
            duty = clamp(duty_ref[], 0.0, 100.0)
            window_s = max(window_ref[], 1.0)
            min_on_s = clamp(min_on_ref[], 0.0, window_s)
            min_off_s = clamp(min_off_ref[], 0.0, window_s - min_on_s)
            
            on_s = (duty / 100.0) * window_s
            off_s = window_s - on_s
            if on_s < min_on_s
                on_s = 0.0
                off_s = window_s
            elseif off_s < min_off_s
                on_s = window_s
                off_s = 0.0
            end
            
            if on_s > 0.0
                set_bioflo_pumps(true)
                t0 = time()
                while (time() - t0) < on_s && keep_running[]
                    sleep(0.5)
                end
            end
            
            set_bioflo_pumps(false)
            t0 = time()
            while (time() - t0) < off_s && keep_running[]
                sleep(0.5)
            end
        end
    catch e
        @warn "BioFlo CO2 PWM task error" exception=(e, catch_backtrace())
    finally
        set_bioflo_pumps(false)
    end
end

function run_mock_pump2_task!(
    keep_running::Ref{Bool},
    params::Dict{String,Any},
    conn::BioFloConn
)
    function set_pump2_value(val::Float64)
        try
            write_float_register(conn, REG_PUMP2, Float32(val))
        catch e
            @warn "Failed to write Pump 2 setpoint on BioFlo Modbus TCP" exception=e
        end
    end

    try
        set_pump2_value(0.0)
        while keep_running[]
            set_pump2_value(5.0)
            t0 = time()
            while (time() - t0) < 30.0 && keep_running[]
                sleep(0.5)
            end
            
            set_pump2_value(0.0)
            t0 = time()
            while (time() - t0) < 270.0 && keep_running[]
                sleep(0.5)
            end
        end
    catch e
        @warn "Mock Pump 2 task error" exception=(e, catch_backtrace())
    finally
        try
            set_pump2_value(0.0)
        catch; end
    end
end

end # module BioFloModbus
