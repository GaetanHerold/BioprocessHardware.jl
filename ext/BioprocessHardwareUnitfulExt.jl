module BioprocessHardwareUnitfulExt

# Optional Unitful support: `with_units(reading)` returns the values as Quantities.
# Loaded automatically after `using Unitful`.

using BioprocessHardware
using Unitful

# Unit strings used by the drivers -> Unitful units. Unknown or empty strings give dimensionless values.
const _UNIT_TABLE = Dict{String, Any}(
    "V" => u"V", "A" => u"A", "mA" => u"mA", "W" => u"W",
    "degC" => u"°C", "K" => u"K",
    "bar" => u"bar", "mbar" => u"mbar", "Pa" => u"Pa", "kPa" => u"kPa",
    "L/min" => u"L/minute", "mL/min" => u"mL/minute", "L/h" => u"L/hr",
    "mg/L" => u"mg/L", "g/L" => u"g/L", "mol/L" => u"mol/L",
    "rpm" => u"1/minute", "s" => u"s", "mm" => u"mm", "%" => u"percent",
    "pH" => Unitful.NoUnits, "" => Unitful.NoUnits,
)

function _unit(name::AbstractString)
    haskey(_UNIT_TABLE, name) && return _UNIT_TABLE[name]
    try
        return Unitful.uparse(name)
    catch
        throw(ArgumentError("Cannot convert unit string \"$name\" to a Unitful unit"))
    end
end

function BioprocessHardware.with_units(r::BioprocessHardware.Reading)
    ks = keys(r.value)
    vals = map(ks) do k
        u = haskey(r.units, k) ? _unit(r.units[k]) : Unitful.NoUnits
        r.value[k] * u
    end
    return NamedTuple{ks}(Tuple(vals))
end

end # module
