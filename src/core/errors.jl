# ============================================================================
# DEVICE ERRORS
# ============================================================================
# Typed exceptions so callers can tell a timeout from a protocol error, a
# device-reported fault or a closed connection without parsing message text.
# ============================================================================

"""
    DeviceError

Abstract supertype of every error raised by a BioprocessHardware driver.
Catch this to handle any driver failure, or a concrete subtype to be specific.
"""
abstract type DeviceError <: Exception end

"""
    DeviceTimeout(device, operation, timeout_s)

The device did not answer within `timeout_s` seconds.
"""
struct DeviceTimeout <: DeviceError
    device::String
    operation::String
    timeout_s::Float64
end

"""
    DeviceProtocolError(device, message; raw=nothing)

The device answered, but the answer was malformed, failed a checksum, or did not
match the request. `raw` optionally carries the offending bytes or text.
"""
struct DeviceProtocolError <: DeviceError
    device::String
    message::String
    raw::Any
end
DeviceProtocolError(device::AbstractString, message::AbstractString; raw=nothing) =
    DeviceProtocolError(String(device), String(message), raw)

"""
    DeviceFault(device, code, message)

The device itself reported a fault or rejected a command (for example a Modbus
exception response or a firmware `ERR` reply).
"""
struct DeviceFault <: DeviceError
    device::String
    code::Any
    message::String
end

"""
    DeviceNotConnected(device)

An operation was attempted on a closed or never-opened device.
"""
struct DeviceNotConnected <: DeviceError
    device::String
end

function Base.showerror(io::IO, e::DeviceTimeout)
    print(io, "DeviceTimeout: ", e.device, " did not answer '", e.operation,
          "' within ", e.timeout_s, " s")
end

function Base.showerror(io::IO, e::DeviceProtocolError)
    print(io, "DeviceProtocolError: ", e.device, ": ", e.message)
    e.raw === nothing || print(io, " (raw: ", repr(e.raw), ")")
end

function Base.showerror(io::IO, e::DeviceFault)
    print(io, "DeviceFault: ", e.device, " reported ", e.code, ": ", e.message)
end

Base.showerror(io::IO, e::DeviceNotConnected) =
    print(io, "DeviceNotConnected: ", e.device, " is not connected")
