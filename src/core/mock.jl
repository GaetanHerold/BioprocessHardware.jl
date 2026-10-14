# ============================================================================
# MOCK DEVICES
# ============================================================================
# Simulated devices that implement the full driver interface. They let control,
# analytics and UI code be developed and tested without hardware, and they are the
# reference implementation used by the driver contract tests.
# ============================================================================

"""
    MockSensor(; fields=(:signal,), units=(signal="",), generator=nothing, name="mock", info=...)

Simulated sensor. `generator(i)` (called with the sample index, starting at 1) must return a
`NamedTuple` with the keys in `fields`; the default produces a smooth sine per field.
Use `fail_next!(sensor)` to make the next read throw a [`DeviceTimeout`](@ref), and
`set_status!(sensor, status)` to simulate over/under-range data.
"""
mutable struct MockSensor <: AbstractSensor
    name::String
    fields::Tuple{Vararg{Symbol}}
    units::NamedTuple
    generator::Function
    info::DeviceInfo
    connected::Bool
    samples::Int
    fail_next::Bool
    status::ReadingStatus
end

function MockSensor(; fields::Tuple{Vararg{Symbol}}=(:signal,),
                    units::NamedTuple=NamedTuple{fields}(ntuple(_ -> "", length(fields))),
                    generator::Union{Function, Nothing}=nothing,
                    name::AbstractString="mock",
                    info::DeviceInfo=DeviceInfo(vendor="BioprocessHardware", model="MockSensor",
                                                serial=String(name), firmware="1", driver="MockSensor"))
    gen = generator === nothing ?
        (i -> NamedTuple{fields}(ntuple(k -> sin(0.1 * i + k), length(fields)))) : generator
    return MockSensor(String(name), fields, units, gen, info, true, 0, false, STATUS_OK)
end

isconnected(s::MockSensor) = s.connected
identify(s::MockSensor) = s.info
fail_next!(s::MockSensor) = (s.fail_next = true; nothing)
set_status!(s::MockSensor, status::ReadingStatus) = (s.status = status; nothing)

function read_measurement(s::MockSensor)
    s.connected || throw(DeviceNotConnected(s.name))
    if s.fail_next
        s.fail_next = false
        throw(DeviceTimeout(s.name, "read_measurement", 0.0))
    end
    s.samples += 1
    vals = s.generator(s.samples)
    vals = s.status == STATUS_OK ? vals : NamedTuple{keys(vals)}(map(_ -> NaN, values(vals)))
    return Reading(vals; units=s.units, status=s.status, source=s.info)
end

close_device!(s::MockSensor) = (s.connected = false; nothing)

"""
    MockActuator(; name="mock", lo=0.0, hi=100.0, unit="%")

Simulated actuator with a single clamped setpoint. `safe_state!` sets it to `lo`.
`fail_next!(actuator)` makes the next write throw; `drop_writes!(actuator, true)` makes it
silently ignore writes (so read-back verification fails, as it would for a stuck device).
"""
mutable struct MockActuator <: AbstractActuator
    name::String
    lo::Float64
    hi::Float64
    unit::String
    value::Float64
    connected::Bool
    fail_next::Bool
    drop::Bool
    info::DeviceInfo
end

MockActuator(; name::AbstractString="mock", lo::Real=0.0, hi::Real=100.0, unit::AbstractString="%") =
    MockActuator(String(name), Float64(lo), Float64(hi), String(unit), Float64(lo), true, false, false,
                 DeviceInfo(vendor="BioprocessHardware", model="MockActuator", serial=String(name),
                            firmware="1", driver="MockActuator"))

isconnected(a::MockActuator) = a.connected
identify(a::MockActuator) = a.info
fail_next!(a::MockActuator) = (a.fail_next = true; nothing)
drop_writes!(a::MockActuator, on::Bool=true) = (a.drop = on; nothing)

function write_setpoint!(a::MockActuator, value::Real)
    a.connected || throw(DeviceNotConnected(a.name))
    return verified_write(
        v -> begin
            if a.fail_next
                a.fail_next = false
                throw(DeviceTimeout(a.name, "write_setpoint!", 0.0))
            end
            a.drop || (a.value = clamp(Float64(v), a.lo, a.hi))
        end,
        () -> a.value,
        clamp(Float64(value), a.lo, a.hi);
        tol=1e-9, delay_s=0.0, device=a.name)
end

function safe_state!(a::MockActuator)
    a.value = a.lo
    return nothing
end

function close_device!(a::MockActuator)
    safe_state!(a)
    a.connected = false
    return nothing
end

"""
    read_measurement(a::MockActuator)

Reading of the current output (`:output`), so actuators can be logged like sensors.
"""
function read_measurement(a::MockActuator)
    a.connected || throw(DeviceNotConnected(a.name))
    return Reading((output=a.value,); units=(output=a.unit,), source=a.info)
end
