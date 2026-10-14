# ============================================================================
# 4-20 mA CURRENT LOOP & BURDEN RESISTOR MATH
# ============================================================================
# Scientific modeling and calibration for 4-20 mA industrial current loops
# terminated across a precision burden resistor and digitized by an ADC.
#
# Adheres to NAMUR NE43 standard:
# - Normal operating range: 3.8 mA to 20.5 mA
# - Failure / Broken wire (under-range): < 3.6 mA
# - Sensor fault / Saturation (over-range): > 21.0 mA
# ============================================================================

module ADC4_20mA

using ..BioprocessHardware: ReadingStatus, STATUS_OK, STATUS_UNDERRANGE, STATUS_OVERRANGE, STATUS_FAULT
using ..BioprocessHardware: RateLimiter, ready!

export CalibratedADC4_20mA, classify_loop_current
export counts_to_mA, mA_to_engineering, counts_to_engineering

"""
    CalibratedADC4_20mA

Calibration parameters for a 4-20 mA current loop measured across a burden resistor
using an analog-to-digital converter.

Fields:
- `R_burden::Float64`: Burden resistor resistance in ohms (nominal 263.0 Ω or precision 249.0 Ω).
- `V_ref::Float64`: ADC reference voltage in volts (nominal 5.000 V rail).
- `max_counts::Float64`: Full-scale count range of the ADC (1024.0 for 10-bit SAR).
- `limiter::RateLimiter`: Rate limiter to prevent log flooding on continuous saturation.
"""
struct CalibratedADC4_20mA
    R_burden::Float64    # e.g. 263.0 ohms
    V_ref::Float64       # e.g. 5.000 V
    max_counts::Float64  # e.g. 1024.0 counts
    limiter::RateLimiter
end

function CalibratedADC4_20mA(; R_burden=263.0, V_ref=5.0, max_counts=1024.0)
    return CalibratedADC4_20mA(Float64(R_burden), Float64(V_ref), Float64(max_counts), RateLimiter(5.0))
end

"""
    classify_loop_current(I_mA::Real)::ReadingStatus

Classifies loop current according to NAMUR NE43 diagnostic boundaries:
- `STATUS_UNDERRANGE`: I < 3.6 mA (indicates broken wire, disconnected probe, or power loss)
- `STATUS_OVERRANGE`: I > 21.0 mA (short-circuit or transducer fault)
- `STATUS_OK`: 3.6 mA <= I <= 21.0 mA
"""
function classify_loop_current(I_mA::Real)::ReadingStatus
    isnan(I_mA) && return STATUS_FAULT
    if I_mA < 3.6
        return STATUS_UNDERRANGE
    elseif I_mA > 21.0
        return STATUS_OVERRANGE
    else
        return STATUS_OK
    end
end

"""
    counts_to_mA(adc::CalibratedADC4_20mA, counts::Real)::Float64

Convert raw ADC digital counts to loop current in milliamperes [mA].
Emits a rate-limited runtime warning if digital counts reach or exceed full scale (>= 1023.0),
guarding against clipped saturation.
"""
function counts_to_mA(adc::CalibratedADC4_20mA, counts::Real)::Float64
    counts_f = Float64(counts)
    isnan(counts_f) && return NaN
    
    V_in = (counts_f / (adc.max_counts - 1.0)) * adc.V_ref
    I_mA = (V_in / adc.R_burden) * 1000.0
    
    # Saturation guard
    if counts_f >= (adc.max_counts - 1.0)
        if ready!(adc.limiter)
            sat_current = round(adc.V_ref / adc.R_burden * 1000.0, digits=2)
            @warn "ADC input saturated! Current exceeds $sat_current mA."
        end
    end
    return I_mA
end

"""
    mA_to_engineering(I_mA::Real, min_val::Real=0.0, max_val::Real=100.0)::Float64

Linearly map a 4-20 mA current to an engineering unit value (e.g. CO2 concentration, pressure).
Clamps ratio to [0.0, 1.0] for the nominal 4.0 - 20.0 mA span.
"""
function mA_to_engineering(I_mA::Real, min_val::Real=0.0, max_val::Real=100.0)::Float64
    isnan(I_mA) && return NaN
    frac = (Float64(I_mA) - 4.0) / 16.0
    return Float64(min_val) + clamp(frac, 0.0, 1.0) * (Float64(max_val) - Float64(min_val))
end

"""
    counts_to_engineering(adc::CalibratedADC4_20mA, counts::Real, min_val::Real=0.0, max_val::Real=100.0)::Tuple{Float64, ReadingStatus}

Convert raw ADC counts directly to engineering value and quality status.
"""
function counts_to_engineering(adc::CalibratedADC4_20mA, counts::Real, min_val::Real=0.0, max_val::Real=100.0)::Tuple{Float64, ReadingStatus}
    I_mA = counts_to_mA(adc, counts)
    status = classify_loop_current(I_mA)
    val = (status == STATUS_UNDERRANGE || status == STATUS_FAULT) ? NaN : mA_to_engineering(I_mA, min_val, max_val)
    return (val, status)
end

end # module ADC4_20mA
