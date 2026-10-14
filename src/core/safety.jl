# ============================================================================
# SAFETY HELPERS
# ============================================================================
# Writing a setpoint and hoping it arrived is not acceptable for actuators that
# dose gas or liquid. These helpers write, read back, retry and report.
# ============================================================================

"""
    verified_write(write, readback, requested; tol=0.0, retries=2, delay_s=0.05, device="device")

Call `write(requested)`, then `readback()` and compare with `requested` (within `tol`).
Retries up to `retries` extra times. Returns a [`SetpointResult`](@ref); does **not** throw
for communication failures, so callers can always inspect `result.ok`.

Pass `readback = nothing` for devices that cannot be read back: the result then has
`applied == nothing` and `ok == true` only if the write itself did not throw.
"""
function verified_write(write::Function, readback::Union{Function, Nothing}, requested;
                        tol::Real=0.0, retries::Int=2, delay_s::Real=0.05,
                        device::AbstractString="device")
    last_msg = ""
    applied = nothing
    attempts = 0
    for attempt in 1:(retries + 1)
        attempts = attempt
        try
            write(requested)
            if readback === nothing
                return SetpointResult(true, requested, nothing, attempts, "written, not verifiable")
            end
            delay_s > 0 && sleep(delay_s)
            applied = readback()
            if applied isa Number && requested isa Number
                abs(applied - requested) <= tol && return SetpointResult(true, requested, applied, attempts, "verified")
                last_msg = "read back $applied, expected $requested (tol $tol)"
            else
                applied == requested && return SetpointResult(true, requested, applied, attempts, "verified")
                last_msg = "read back $(repr(applied)), expected $(repr(requested))"
            end
        catch e
            e isa InterruptException && rethrow()
            e isa DeviceError || rethrow()
            last_msg = sprint(showerror, e)
        end
    end
    @warn "Setpoint not confirmed" device=device requested=requested attempts=attempts reason=last_msg
    return SetpointResult(false, requested, applied, attempts, last_msg)
end

"""
    RateLimiter(period_s)

`ready!(rl)` returns `true` at most once per `period_s` seconds. Use it to stop a repeating
warning (for example ADC saturation) from flooding the logs.
"""
mutable struct RateLimiter
    period_s::Float64
    last::Float64
end
RateLimiter(period_s::Real) = RateLimiter(Float64(period_s), -Inf)

function ready!(rl::RateLimiter)
    t = time()
    if t - rl.last >= rl.period_s
        rl.last = t
        return true
    end
    return false
end
