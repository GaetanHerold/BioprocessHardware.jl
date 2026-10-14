# ============================================================================
# SLOW PWM & MECHANICAL RELAY PROTECTION
# ============================================================================
# Manages low-frequency pulse-width modulation for mechanical relays and
# peristaltic pumps, strictly enforcing dwell constraints and tracking
# switch cycles for wear monitoring.
# ============================================================================

module SlowPWM

using ..BioprocessHardware: RateLimiter, ready!

export compute_pwm_times, execute_guarded_pwm, RelayWearTracker, record_switch!

"""
    compute_pwm_times(duty_pct::Real, window_s::Real,
                      min_on_s::Real=1.0, min_off_s::Real=1.0)::Tuple{Float64, Float64}

Convert a duty cycle (0-100%) into ON/OFF times while strictly enforcing minimum
switching constraints (t_on, t_off >= 1.0 s) for mechanical relays.
- If t_on < min_on_s: pulse is suppressed (t_on = 0.0 s, relay remains OFF) to prevent contact chatter.
- If t_off < min_off_s: clamped to full-on (t_on = window_s, relay remains ON) to prevent contact chatter.
"""
function compute_pwm_times(duty_pct::Real, window_s::Real,
                           min_on_s::Real=1.0, min_off_s::Real=1.0)::Tuple{Float64, Float64}
    duty = clamp(Float64(duty_pct), 0.0, 100.0)
    w_s = max(Float64(window_s), 0.0)
    duty == 0.0 && return (0.0, w_s)
    duty == 100.0 && return (w_s, 0.0)

    # Strictly enforce minimum dwell constraints >= 1.0 s (cannot be bypassed)
    effective_min_on = max(Float64(min_on_s), 1.0)
    effective_min_off = max(Float64(min_off_s), 1.0)

    raw_on = (duty / 100.0) * w_s
    if raw_on < effective_min_on
        on_s = 0.0
    elseif (w_s - raw_on) < effective_min_off
        on_s = w_s
    else
        on_s = raw_on
    end
    return (on_s, w_s - on_s)
end

"""
    RelayWearTracker

Tracks the cumulative switching operations of a mechanical relay to alert operators
before mechanical endurance limit is reached (typical rated lifetime ~100,000 cycles).
"""
mutable struct RelayWearTracker
    total_cycles::Int
    rated_endurance::Int
    warn_limiter::RateLimiter
end

function RelayWearTracker(rated_endurance::Int=100000)
    return RelayWearTracker(0, rated_endurance, RateLimiter(3600.0))
end

"""
    record_switch!(tracker::RelayWearTracker)

Increment the relay cycle count and emit a warning when 50% and 80% of rated lifetime is exceeded.
"""
function record_switch!(tracker::RelayWearTracker)
    tracker.total_cycles += 1
    pct = (tracker.total_cycles / tracker.rated_endurance) * 100.0
    if pct >= 50.0 && ready!(tracker.warn_limiter)
        @warn "Relay contact wear: $(tracker.total_cycles)/$(tracker.rated_endurance) operations ($(round(pct, digits=1))% of rated life)."
    end
    return tracker.total_cycles
end

"""
    execute_guarded_pwm(write_fn::Function, duty_pct::Real, window_s::Real, min_dwell_s::Real=1.0;
                        sleep_fn::Function=sleep, tracker=nothing)::Tuple{Float64, Float64}

Executes ONE slow-PWM cycle using sleep() to modulate the actuator while strictly enforcing dwell bounds.
Calls `write_fn(true)` for ON and `write_fn(false)` for OFF.
"""
function execute_guarded_pwm(write_fn::Function, duty_pct::Real, window_s::Real, min_dwell_s::Real=1.0;
                             sleep_fn::Function=sleep, tracker::Union{RelayWearTracker, Nothing}=nothing)::Tuple{Float64, Float64}
    effective_min = max(Float64(min_dwell_s), 1.0)
    on_s, off_s = compute_pwm_times(duty_pct, window_s, effective_min, effective_min)

    if on_s > 0.0
        write_fn(true)
        tracker !== nothing && record_switch!(tracker)
        sleep_fn(on_s)
    end
    if off_s > 0.0
        write_fn(false)
        sleep_fn(off_s)
    end
    return (on_s, off_s)
end

end # module SlowPWM
