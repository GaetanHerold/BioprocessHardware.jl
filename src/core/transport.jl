# ============================================================================
# BYTE TRANSPORTS
# ============================================================================
# Drivers talk to hardware through a transport, never directly through a serial
# port, so the same driver code runs against a real port or a scripted mock.
#
# A transport implements five primitives:
#   write_bytes!(t, data)       send bytes
#   bytes_ready(t)              number of received bytes waiting
#   read_ready(t, n)            take up to n waiting bytes, never blocks
#   flush_input!(t)             discard everything received so far
#   close!(t) / isopen(t)
# Everything else (bounded line reads, timeouts) is built on those, once.
# ============================================================================

"""
    AbstractTransport

Byte-level connection to a device. See [`SerialTransport`](@ref) and [`MockTransport`](@ref).
"""
abstract type AbstractTransport end

function write_bytes! end
function bytes_ready end
function read_ready end
function flush_input! end
function close! end

write_bytes!(t::AbstractTransport, s::AbstractString) = write_bytes!(t, Vector{UInt8}(codeunits(s)))

"""
    read_until(t, terminator; timeout_s=1.0, maxlen=4096, device="device", operation="read") -> Vector{UInt8}

Read from `t` until `terminator` (bytes or string) has been received, and return everything
read **including** the terminator. Never blocks beyond `timeout_s`.

Throws [`DeviceTimeout`](@ref) when the terminator does not arrive in time and
[`DeviceProtocolError`](@ref) when more than `maxlen` bytes arrive without it
(a runaway or noisy line cannot grow memory without bound).
"""
function read_until(t::AbstractTransport, terminator::AbstractVector{UInt8};
                    timeout_s::Real=1.0, maxlen::Int=4096,
                    device::AbstractString="device", operation::AbstractString="read")
    isempty(terminator) && throw(ArgumentError("terminator must not be empty"))
    isopen(t) || throw(DeviceNotConnected(String(device)))
    buf = UInt8[]
    t0 = time()
    nt = length(terminator)
    while true
        n = bytes_ready(t)
        if n > 0
            append!(buf, read_ready(t, n))
            if length(buf) >= nt
                # search only the region that can contain a newly completed terminator
                from = max(1, length(buf) - n - nt + 2)
                for i in from:(length(buf) - nt + 1)
                    if view(buf, i:(i + nt - 1)) == terminator
                        # keep any bytes after the terminator for the next read
                        extra = buf[(i + nt):end]
                        isempty(extra) || _unread!(t, extra)
                        return buf[1:(i + nt - 1)]
                    end
                end
            end
            length(buf) > maxlen &&
                throw(DeviceProtocolError(device, "no terminator within $maxlen bytes"; raw=first(buf, 64)))
        else
            if (time() - t0) >= timeout_s
                isempty(buf) || _unread!(t, buf)   # keep the partial line for a later read
                throw(DeviceTimeout(String(device), String(operation), Float64(timeout_s)))
            end
            sleep(0.002)
        end
    end
end
read_until(t::AbstractTransport, terminator::AbstractString; kw...) =
    read_until(t, Vector{UInt8}(codeunits(terminator)); kw...)

"""
    read_line(t; eol="\\n", timeout_s=1.0, maxlen=4096, device, operation) -> String

Like [`read_until`](@ref) but returns the text without the line terminator and without a trailing `\\r`.
"""
function read_line(t::AbstractTransport; eol::AbstractString="\n", kw...)
    raw = read_until(t, eol; kw...)
    s = String(raw[1:(end - ncodeunits(eol))])
    return endswith(s, '\r') ? s[1:prevind(s, lastindex(s))] : s
end

"""
    read_for(t, duration_s) -> Vector{UInt8}

Collect whatever arrives during `duration_s` seconds (for devices without a terminator).
"""
function read_for(t::AbstractTransport, duration_s::Real)
    buf = UInt8[]
    t0 = time()
    while (time() - t0) < duration_s
        n = bytes_ready(t)
        n > 0 ? append!(buf, read_ready(t, n)) : sleep(0.002)
    end
    n = bytes_ready(t)
    n > 0 && append!(buf, read_ready(t, n))
    return buf
end

# Transports that cannot push surplus bytes back get a generic pushback buffer.
function _unread!(t::AbstractTransport, extra::Vector{UInt8})
    pushback!(t, extra)
end
function pushback! end

# ----------------------------------------------------------------------------
# Serial transport
# ----------------------------------------------------------------------------

"""
    SerialTransport(port_name, baudrate; databits=8, parity=SP_PARITY_NONE, stopbits=1)

Transport over a physical serial port (LibSerialPort). Reads are non-blocking:
a partial line or a cut cable can never stall the Julia scheduler.
"""
mutable struct SerialTransport <: AbstractTransport
    port_name::String
    baudrate::Int
    sp::Union{LibSerialPort.SerialPort, Nothing}
    pending::Vector{UInt8}
    lock::ReentrantLock
end

function SerialTransport(port_name::AbstractString, baudrate::Integer=115200;
                         databits::Integer=8, parity=LibSerialPort.SP_PARITY_NONE,
                         stopbits::Integer=1)
    sp = LibSerialPort.open(String(port_name), Int(baudrate))
    try
        LibSerialPort.set_flow_control(sp)          # no flow control
        LibSerialPort.sp_set_bits(sp.ref, Int(databits))
        LibSerialPort.sp_set_parity(sp.ref, parity)
        LibSerialPort.sp_set_stopbits(sp.ref, Int(stopbits))
    catch e
        e isa InterruptException && rethrow()
        @debug "Could not apply extended serial settings, using library defaults" exception=e
    end
    return SerialTransport(String(port_name), Int(baudrate), sp, UInt8[], ReentrantLock())
end

Base.isopen(t::SerialTransport) = t.sp !== nothing && isopen(t.sp)

function write_bytes!(t::SerialTransport, data::Vector{UInt8})
    isopen(t) || throw(DeviceNotConnected(t.port_name))
    lock(t.lock) do
        write(t.sp, data)
    end
    return nothing
end

function bytes_ready(t::SerialTransport)
    isopen(t) || return length(t.pending)
    return length(t.pending) + Int(bytesavailable(t.sp))
end

function read_ready(t::SerialTransport, n::Integer)
    out = UInt8[]
    if !isempty(t.pending)
        k = min(n, length(t.pending))
        append!(out, t.pending[1:k])
        deleteat!(t.pending, 1:k)
    end
    remaining = n - length(out)
    if remaining > 0 && isopen(t)
        avail = Int(bytesavailable(t.sp))
        avail > 0 && append!(out, LibSerialPort.nonblocking_read(t.sp, min(remaining, avail)))
    end
    return out
end

pushback!(t::SerialTransport, extra::Vector{UInt8}) = (prepend!(t.pending, extra); nothing)

function flush_input!(t::SerialTransport)
    empty!(t.pending)
    isopen(t) && LibSerialPort.sp_flush(t.sp, LibSerialPort.SP_BUF_INPUT)
    return nothing
end

function close!(t::SerialTransport)
    if t.sp !== nothing
        try
            close(t.sp)
        catch e
            e isa InterruptException && rethrow()
            @debug "Error while closing serial port" port=t.port_name exception=e
        end
        t.sp = nothing
    end
    return nothing
end

# ----------------------------------------------------------------------------
# Mock transport
# ----------------------------------------------------------------------------

"""
    MockTransport(responder=nothing)

In-memory transport for tests and simulators. `responder(bytes)` is called for every
write and may return `nothing`, a `String` or `Vector{UInt8}` that the "device" replies with.
Use [`inject!`](@ref) to push unsolicited bytes (telemetry streams, noise, truncated frames)
and `t.sent` to inspect what the driver wrote.
"""
mutable struct MockTransport <: AbstractTransport
    responder::Union{Function, Nothing}
    rx::Vector{UInt8}
    sent::Vector{Vector{UInt8}}
    open::Bool
    lock::ReentrantLock
end
MockTransport(responder::Union{Function, Nothing}=nothing) =
    MockTransport(responder, UInt8[], Vector{UInt8}[], true, ReentrantLock())

Base.isopen(t::MockTransport) = t.open

"""
    inject!(t::MockTransport, data)

Make `data` appear as received from the device.
"""
function inject!(t::MockTransport, data::AbstractVector{UInt8})
    lock(t.lock) do
        append!(t.rx, data)
    end
    return nothing
end
inject!(t::MockTransport, s::AbstractString) = inject!(t, Vector{UInt8}(codeunits(s)))

function write_bytes!(t::MockTransport, data::Vector{UInt8})
    t.open || throw(DeviceNotConnected("mock"))
    lock(t.lock) do
        push!(t.sent, copy(data))
    end
    if t.responder !== nothing
        reply = t.responder(copy(data))
        reply === nothing || inject!(t, reply isa AbstractString ? Vector{UInt8}(codeunits(reply)) : Vector{UInt8}(reply))
    end
    return nothing
end

bytes_ready(t::MockTransport) = lock(() -> length(t.rx), t.lock)

function read_ready(t::MockTransport, n::Integer)
    lock(t.lock) do
        k = min(Int(n), length(t.rx))
        out = t.rx[1:k]
        deleteat!(t.rx, 1:k)
        return out
    end
end

pushback!(t::MockTransport, extra::Vector{UInt8}) = lock(() -> (prepend!(t.rx, extra); nothing), t.lock)
flush_input!(t::MockTransport) = lock(() -> (empty!(t.rx); nothing), t.lock)
close!(t::MockTransport) = (t.open = false; nothing)
