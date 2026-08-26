# ============================================================================
# BIOFLO MODBUS TCP CLIENT & I/O DRIVER
# ============================================================================
# Manages persistent Modbus TCP socket connections, register read/write
# operations, background sensor polling, and hardware PWM pump routines.
# ============================================================================

using Sockets
using Dates

# BioFlo Connection Manager using persistent TCP socket
mutable struct BioFloConn
    ip::String
    port::Int
    unit_id::UInt8
    socket::Union{TCPSocket, Nothing}
    tid::UInt16
    lock::ReentrantLock
    connected::Bool
end

function BioFloConn(ip::String, port::Int=502, unit_id::Int=1)
    return BioFloConn(ip, port, UInt8(unit_id), nothing, UInt16(0), ReentrantLock(), false)
end

function _bioflo_connect!(conn::BioFloConn)::Bool
    try
        if conn.socket !== nothing
            try close(conn.socket) catch; end
        end
        sock = connect(conn.ip, conn.port)
        conn.socket    = sock
        conn.connected = true
        return true
    catch e
        conn.socket    = nothing
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

function read_with_timeout(socket::TCPSocket, n_bytes::Int, timeout_s::Float64=5.0)
    buf = Vector{UInt8}(undef, n_bytes)
    task = @async readbytes!(socket, buf, n_bytes)
    t_start = time()
    while !istaskdone(task)
        if (time() - t_start) > timeout_s
            close(socket)
            error("Socket read timeout ($timeout_s seconds)")
        end
        sleep(0.005)
    end
    istaskfailed(task) && throw(TaskFailedException(task))
    return buf
end

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
        hdr = read_with_timeout(conn.socket, 9)
        if length(hdr) < 9
            error("Incomplete Modbus header response")
        end
        if hdr[8] & 0x80 != 0x00
            exc_data = read_with_timeout(conn.socket, 1)
            @warn "Modbus FC03 exception response" fc=hdr[8] code=(isempty(exc_data) ? 0x00 : exc_data[1])
            return nothing
        end
        byte_count = Int(hdr[9])
        data = read_with_timeout(conn.socket, byte_count)
        if length(data) < byte_count
            error("Incomplete Modbus data body")
        end
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
        resp = read_with_timeout(conn.socket, 12)
        if length(resp) < 12
            error("Incomplete Modbus write response")
        end
        if resp[8] & 0x80 != 0x00
            @warn "Modbus write exception response" fc=resp[8]
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
        bytes1 = _modbus_read_regs!(conn, UInt16(2), UInt16(4))
        if bytes1 === nothing
            error("Failed to read Temp and pH registers")
        end
        T_ferm  = bytes_to_float32(bytes1[1:4])
        pH_ferm = bytes_to_float32(bytes1[5:8])
        
        bytes2 = _modbus_read_regs!(conn, UInt16(48), UInt16(2))
        if bytes2 === nothing
            error("Failed to read dCO2 register")
        end
        dco2_ferm = bytes_to_float32(bytes2)
        
        return Float64(pH_ferm), Float64(T_ferm), Float64(dco2_ferm)
    end
end

"""
    run_bioflo_monitor_task!(keep_running, params, conn, latest_bioflo_data_ref)

Background async task that periodically polls the BioFlo Modbus server for pH, Temp, and dCO2.
"""
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

"""
    run_bioflo_pwm_task!(duty_ref, keep_running, params, conn; window_ref, min_on_ref, min_off_ref)

Background async task for continuous slow PWM on the BioFlo Pumps 1 and 3 via Modbus TCP.
"""
function run_bioflo_pwm_task!(
    duty_ref::Ref{Float64},
    keep_running::Ref{Bool},
    params::Dict{String,Any},
    conn::BioFloConn;
    window_ref::Ref{Float64}=Ref(120.0),
    min_on_ref::Ref{Float64}=Ref(20.0),
    min_off_ref::Ref{Float64}=Ref(20.0)
)
    function set_bioflo_pumps(state::Bool)
        val = state ? Float32(18.8) : Float32(0.0)
        try
            write_float_register(conn, UInt16(76), val)
            sleep(0.1)
            write_float_register(conn, UInt16(80), val)
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
            
            # Simple PWM calculation
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

"""
    run_mock_pump2_task!(keep_running, params, conn)

Mock fermentation Pump 2 routine: sets Pump 2 (loop 7, address 78) to 5.0 ml/min
for 30 seconds every 5 minutes (300 seconds), and 0.0 ml/min for the rest of the cycle.
"""
function run_mock_pump2_task!(
    keep_running::Ref{Bool},
    params::Dict{String,Any},
    conn::BioFloConn
)
    println("[INFO] Started mock fermentation Pump 2 task (30s ON @ 5.0 ml/min every 5 min)")
    
    function set_pump2_value(val::Float64)
        try
            write_float_register(conn, UInt16(78), Float32(val))
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
