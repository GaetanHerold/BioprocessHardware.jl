# ============================================================================
# COMMON DRIVER INTERFACE
# ============================================================================
# Every instrument driver implements the subset of these functions that makes
# sense for it. Other packages (control, analytics, UIs) program against this
# interface only, so a mock device can replace real hardware without code changes.
# ============================================================================

"""
    AbstractDevice

Root of all instrument types.
"""
abstract type AbstractDevice end

"""
    AbstractSensor <: AbstractDevice

A device that produces measurements: implements [`read_measurement`](@ref).
"""
abstract type AbstractSensor <: AbstractDevice end

"""
    AbstractActuator <: AbstractDevice

A device that accepts setpoints: implements [`write_setpoint!`](@ref) and [`safe_state!`](@ref).
"""
abstract type AbstractActuator <: AbstractDevice end

"""
    HealthLevel

`HEALTH_OK`, `HEALTH_DEGRADED` (working but with warnings) or `HEALTH_FAULT`.
"""
@enum HealthLevel HEALTH_OK HEALTH_DEGRADED HEALTH_FAULT

"""
    Health(level, reason="")

Result of [`healthcheck`](@ref).
"""
struct Health
    level::HealthLevel
    reason::String
end
Health(level::HealthLevel) = Health(level, "")
Base.isequal(a::Health, b::Health) = a.level == b.level && a.reason == b.reason
Base.:(==)(a::Health, b::Health) = isequal(a, b)

"""
    ishealthy(h::Health) -> Bool
"""
ishealthy(h::Health) = h.level == HEALTH_OK

"""
    SetpointResult(ok, requested, applied, attempts, message)

Outcome of [`write_setpoint!`](@ref). `applied` is the value read back from the device
(or `nothing` if the device cannot be read back); `ok` is `false` if the write or
verification failed.
"""
struct SetpointResult
    ok::Bool
    requested::Any
    applied::Any
    attempts::Int
    message::String
end

"""
    isconnected(dev) -> Bool

Whether the device connection is open. Does not talk to the device.
"""
function isconnected end

"""
    identify(dev) -> DeviceInfo

Vendor, model, serial and firmware of the connected device. May query the device.
"""
function identify end

"""
    healthcheck(dev) -> Health

Cheap check that the device is connected and answering. Never throws a [`DeviceError`](@ref);
failures are reported in the returned [`Health`](@ref).
"""
function healthcheck end

"""
    read_measurement(sensor) -> Reading

Take one measurement. Throws a [`DeviceError`](@ref) if the device cannot be read;
returns a `Reading` with a non-`STATUS_OK` status and `NaN` values for readable-but-invalid data.
"""
function read_measurement end

"""
    write_setpoint!(actuator, args...) -> SetpointResult

Apply a setpoint, read it back where the device supports it, and report the outcome.
"""
function write_setpoint! end

"""
    safe_state!(dev)

Put outputs into their safe state (relay off, pump stopped, valve open, power supply output off,
depending on the instrument). Must be idempotent and must not throw if the device is already gone.
"""
function safe_state! end

"""
    close_device!(dev)

Release the device. Actuators are put into their safe state first. Idempotent.
"""
function close_device! end

# Defaults -------------------------------------------------------------------

safe_state!(::AbstractSensor) = nothing

function close_device!(dev::AbstractActuator)
    try
        safe_state!(dev)
    catch e
        e isa InterruptException && rethrow()
        @warn "safe_state! failed while closing device" device=typeof(dev) exception=e
    end
    return nothing
end
close_device!(::AbstractSensor) = nothing

function healthcheck(dev::AbstractDevice)
    isconnected(dev) || return Health(HEALTH_FAULT, "not connected")
    return Health(HEALTH_OK)
end

"""
    with_device(f, dev)

Call `f(dev)` and always run [`close_device!`](@ref) afterwards, even if `f` throws.

```julia
with_device(open_dpps("/dev/ttyUSB0")) do dev
    println(read_measurement(dev))
end
```
"""
function with_device(f::Function, dev::AbstractDevice)
    try
        return f(dev)
    finally
        close_device!(dev)
    end
end
