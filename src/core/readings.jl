# ============================================================================
# TYPED READINGS
# ============================================================================
# Every sensor driver returns a `Reading`: named numeric fields, a unit string
# for each field, a UTC wall-clock time, a monotonic time for intervals, and a
# status. Invalid data is NaN with a non-OK status, never an invented default.
# ============================================================================

"""
    ReadingStatus

Quality flag of a [`Reading`](@ref):
`STATUS_OK`, `STATUS_STALE` (older than expected), `STATUS_OVERRANGE`,
`STATUS_UNDERRANGE` (for example a 4-20 mA loop below 3.6 mA, i.e. broken wire),
`STATUS_FAULT` (device or communication fault, values are NaN).
"""
@enum ReadingStatus STATUS_OK STATUS_STALE STATUS_OVERRANGE STATUS_UNDERRANGE STATUS_FAULT

"""
    DeviceInfo(; vendor, model, serial, firmware, port, driver)

Static identity of a device, recorded in every log header.
Unknown fields are empty strings.
"""
Base.@kwdef struct DeviceInfo
    vendor::String = ""
    model::String = ""
    serial::String = ""
    firmware::String = ""
    port::String = ""
    driver::String = ""
end

"""
    Reading(value::NamedTuple; units, status=STATUS_OK, source=DeviceInfo(), t_utc=now(UTC))

One measurement. `value` maps field names to numbers (`Float64`, `NaN` when unavailable).
`units` maps the same field names to unit strings (for example `"V"`, `"degC"`).

- `t_utc`: UTC wall-clock time of the sample (use for logs and cross-instrument alignment).
- `t_mono_ns`: monotonic clock (`time_ns()`), use it for intervals, it never jumps.
"""
struct Reading{V<:NamedTuple}
    t_utc::DateTime
    t_mono_ns::UInt64
    value::V
    units::NamedTuple
    status::ReadingStatus
    source::DeviceInfo
end

function Reading(value::NamedTuple;
                 units::NamedTuple=NamedTuple(),
                 status::ReadingStatus=STATUS_OK,
                 source::DeviceInfo=DeviceInfo(),
                 t_utc::DateTime=Dates.now(Dates.UTC),
                 t_mono_ns::Integer=time_ns())
    for k in keys(units)
        haskey(value, k) || throw(ArgumentError("unit given for unknown field :$k"))
    end
    return Reading(t_utc, UInt64(t_mono_ns), value, units, status, source)
end

Base.getproperty(r::Reading, s::Symbol) =
    s in fieldnames(Reading) ? getfield(r, s) : getfield(r, :value)[s]
Base.propertynames(r::Reading, private::Bool=false) =
    (fieldnames(Reading)..., keys(getfield(r, :value))...)
Base.keys(r::Reading) = keys(r.value)
Base.getindex(r::Reading, k::Symbol) = r.value[k]

"""
    isvalid(reading) -> Bool

`true` when the status is `STATUS_OK`.
"""
Base.isvalid(r::Reading) = r.status == STATUS_OK

"""
    fault_reading(fields, units; source, status=STATUS_FAULT)

Reading with every field set to `NaN`, used when a sample could not be obtained.
"""
function fault_reading(fields::Tuple{Vararg{Symbol}}, units::NamedTuple=NamedTuple();
                       source::DeviceInfo=DeviceInfo(), status::ReadingStatus=STATUS_FAULT)
    vals = NamedTuple{fields}(ntuple(_ -> NaN, length(fields)))
    return Reading(vals; units=units, status=status, source=source)
end

"""
    with_units(reading)

Return the reading's values as `Unitful` quantities. Available after `using Unitful`
(package extension); without Unitful loaded this function has no methods.
"""
function with_units end

function Base.show(io::IO, r::Reading)
    print(io, "Reading(", Dates.format(r.t_utc, "yyyy-mm-ddTHH:MM:SS.sss"), "Z, ", r.status)
    for k in keys(r.value)
        u = haskey(r.units, k) ? " " * r.units[k] : ""
        print(io, ", ", k, "=", r.value[k], u)
    end
    print(io, ")")
end
