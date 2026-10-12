#=
CO2 DOSING STANDALONE SCRIPT

Hardware Architecture:
- Controller: Numato Lab 1-Channel USB Powered Relay Module (Serial over USB)
- Sensor: 4-20mA CO2 Probe (24V PSU) wired to ADC 0 and 1 via 263Ω burden resistor
- Actuator: Smart Pump via DB25, mechanically switched by relay (GPIO3 internal)

Constraints:
- Low-Frequency PWM Only (relay is mechanical, >10s cycle)
- Two-Point Calibration Math for ADC to current/concentration

Usage:
  # Standalone
  include("co2_doser.jl")
  CO2Doser.run_standalone("/dev/tty.usbmodem123456781") # replace with your port
=#

module CO2Doser

using LibSerialPort
using Dates

export CO2SensorCalibration, ControllerConfig, DoserState
export CalibratedADC4_20mA, counts_to_mA, mA_to_co2, counts_to_co2
export read_adc, read_co2_percent, set_relay, adc_to_co2
export compute_duty_cycle, compute_pwm_times, run_pwm_cycle, execute_guarded_relay_pwm, run_pwm_task!
export run_standalone, interactive_calibration

# ============================================================================
# DATA STRUCTURES
# ============================================================================

mutable struct CO2SensorCalibration
    X1::Float64 # ADC value 1 (0-1023)
    Y1::Float64 # CO2 concentration 1
    X2::Float64 # ADC value 2 (0-1023)
    Y2::Float64 # CO2 concentration 2
end

"""
    CalibratedADC4_20mA

Calibration parameters for a 4-20 mA current loop measured across a burden resistor
using an analog-to-digital converter.

Fields:
- `R_burden::Float64`: Burden resistor resistance in ohms (nominal 263.0 Ω).
- `V_ref::Float64`: ADC reference voltage in volts (nominal 5.000 V).
- `max_counts::Float64`: Full-scale count range of the ADC (1024.0 for 10-bit SAR).
"""
struct CalibratedADC4_20mA
    R_burden::Float64    # 263.0 ohms
    V_ref::Float64       # 5.000 V
    max_counts::Float64  # 1024.0 counts
end

CalibratedADC4_20mA(; R_burden=263.0, V_ref=5.0, max_counts=1024.0) = CalibratedADC4_20mA(R_burden, V_ref, max_counts)

"""
    counts_to_mA(adc::CalibratedADC4_20mA, counts::Real)::Float64

Convert raw ADC digital counts to loop current in milliamperes [mA].
Emits a runtime warning if digital counts reach or exceed full scale (>= 1023.0),
guarding against clipped saturation above 19.01 mA on a 263 Ω burden resistor with 5.0 V rail.
Clamps output to [4.0, 20.0] mA.
"""
function counts_to_mA(adc::CalibratedADC4_20mA, counts::Real)::Float64
    counts_f = Float64(counts)
    V_in = (counts_f / (adc.max_counts - 1.0)) * adc.V_ref
    I_mA = (V_in / adc.R_burden) * 1000.0
    # Guard against clipped saturation above 19.01 mA:
    if counts_f >= 1023.0
        @warn "ADC input saturated! Current exceeds $(round(adc.V_ref / adc.R_burden * 1000.0, digits=2)) mA."
    end
    return clamp(I_mA, 4.0, 20.0)
end

"""
    mA_to_co2(I_mA::Real, co2_min::Real=0.0, co2_max::Real=100.0)::Float64

Convert 4-20 mA loop current to dissolved CO2 concentration/saturation [%].
"""
function mA_to_co2(I_mA::Real, co2_min::Real=0.0, co2_max::Real=100.0)::Float64
    frac = (Float64(I_mA) - 4.0) / 16.0
    return Float64(co2_min) + clamp(frac, 0.0, 1.0) * (Float64(co2_max) - Float64(co2_min))
end

"""
    counts_to_co2(adc::CalibratedADC4_20mA, counts::Real, co2_min::Real=0.0, co2_max::Real=100.0)::Float64

Convert raw ADC counts to dissolved CO2 [%] using the calibrated burden resistor model.
"""
function counts_to_co2(adc::CalibratedADC4_20mA, counts::Real, co2_min::Real=0.0, co2_max::Real=100.0)::Float64
    I_mA = counts_to_mA(adc, counts)
    return mA_to_co2(I_mA, co2_min, co2_max)
end

Base.@kwdef mutable struct ControllerConfig
    target_co2::Float64 = 5.0
    Kp::Float64 = 10.0
    Ki::Float64 = 0.02
    pwm_window_s::Float64 = 10.0
    min_on_s::Float64 = 1.0
    min_off_s::Float64 = 1.0
end

mutable struct DoserState
    sp::SerialPort
    calibration::CO2SensorCalibration
    config::ControllerConfig
    is_running::Bool
end

# ============================================================================
# MATH AND CONVERSIONS
# ============================================================================

"""
    adc_to_co2(adc_val, cal::CO2SensorCalibration)

Linearly interpolates raw ADC readings to ACTUAL CO2 concentration 
using the 2-point calibration math.
"""
function adc_to_co2(adc_val::Float64, cal::CO2SensorCalibration)
    if (cal.X2 - cal.X1) == 0.0
        return cal.Y1 # fallback to avoid division by zero
    end
    return cal.Y1 + ((cal.Y2 - cal.Y1) / (cal.X2 - cal.X1)) * (adc_val - cal.X1)
end

"""
    read_co2_percent(sp, cal; channel=0)

Read the configured ADC channel and convert it directly to dissolved CO2 [%].
Returns NaN when the raw ADC read fails.
"""
function read_co2_percent(sp::IO, cal::CO2SensorCalibration; channel::Int=0)
    adc_val = read_adc(sp, channel)
    return isnan(adc_val) ? NaN : adc_to_co2(adc_val, cal)
end

"""
    read_co2_percent(sp::IO, adc::CalibratedADC4_20mA; channel::Int=0, co2_min::Real=0.0, co2_max::Real=100.0)

Read configured ADC channel and convert to dissolved CO2 [%] using the burden resistor calibration model.
"""
function read_co2_percent(sp::IO, adc::CalibratedADC4_20mA; channel::Int=0, co2_min::Real=0.0, co2_max::Real=100.0)
    adc_val = read_adc(sp, channel)
    return isnan(adc_val) ? NaN : counts_to_co2(adc, adc_val, co2_min, co2_max)
end

"""
    compute_duty_cycle(current_co2, config::ControllerConfig)

Computes the required duty cycle (0-100%) for the pump based on CO2 error.
Uses simple Proportional control.
"""
function compute_duty_cycle(current_co2::Float64, config::ControllerConfig)
    error = config.target_co2 - current_co2
    duty_cycle = clamp(error * config.Kp, 0.0, 100.0)
    return duty_cycle
end

"""
    compute_duty_cycle(co2_measured, co2_target, Kp, Ki, integral_error, dt)

PI controller for dissolved CO2 with anti-windup. Returns
`(duty_cycle_percent, new_integral_error)`.
"""
function compute_duty_cycle(co2_measured::Float64, co2_target::Float64,
                            Kp::Float64, Ki::Float64,
                            integral_error::Float64, dt::Float64)::Tuple{Float64, Float64}
    if isnan(co2_measured)
        return (NaN, integral_error)
    end

    error = co2_target - co2_measured
    p_term = Kp * error
    new_integral = integral_error + error * dt
    i_term = Ki * new_integral

    duty_raw = p_term + i_term
    duty = clamp(duty_raw, 0.0, 100.0)

    if (duty_raw > 100.0 && error > 0.0) || (duty_raw < 0.0 && error < 0.0)
        return (duty, integral_error)
    end

    return (duty, new_integral)
end

"""
    compute_pwm_times(duty_pct::Real, window_s::Real,
                      min_on_s::Real=1.0, min_off_s::Real=1.0)::Tuple{Float64, Float64}

Convert a duty cycle into ON/OFF times while respecting slow-PWM minimum
switching constraints for a mechanical relay.
Strictly enforces minimum dwell constraints (t_on, t_off >= 1.0 s) so they cannot be bypassed.
- If t_on < min_on_s: pulse is suppressed (t_on = 0.0 s) to prevent contact chatter.
- If t_off < min_off_s: clamped to full-on (t_on = window_s) to prevent contact chatter.
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

# ============================================================================
# HARDWARE INTERACTION (NUMATO RELAY MODULE)
# ============================================================================

"""
    read_adc(sp::SerialPort, channel::Int=0)

Sends the reading command and parses the 10-bit integer from the USB Serial module.
"""
function read_adc(sp::SerialPort, channel::Int=0)
    # Clear any residual data
    sp_flush(sp, SP_BUF_BOTH)
    
    cmd = "adc read $channel\r"
    write(sp, cmd)
    
    # Wait for the device to respond
    sleep(0.1)
    
    response = String(read(sp))

    # The device may echo the command and prompt text; choose the last plausible ADC value.
    candidates = collect(eachmatch(r"\b\d{1,4}\b", response))
    for m in Iterators.reverse(candidates)
        v = try
            parse(Int, m.match)
        catch
            continue
        end
        if 0 <= v <= 1023
            return Float64(v)
        end
    end

    @warn "Failed to parse ADC reading: $(repr(response))"
    return NaN
end

"""
    set_relay(sp::IO, state::Bool, channel::Int=0)

Turns the mechanical relay ON or OFF.
"""
function set_relay(sp::IO, state::Bool, channel::Int=0)
    if state
        write(sp, "relay on $channel\r\n")
    else
        write(sp, "relay off $channel\r\n")
    end
    flush(sp)
end

"""
    execute_guarded_relay_pwm(sp::IO, duty_cycle_pct::Real, window_s::Real, min_dwell_s::Real=1.0; channel::Int=0, sleep_fn::Function=sleep)::Tuple{Float64, Float64}

Executes ONE slow-PWM cycle using sleep() to modulate the mechanical relay while strictly
enforcing minimum dwell constraints (t_on, t_off >= 1.0 s) to protect mechanical contacts
against chattering and premature arc erosion (Finding F27 & Remediation Snippet 5.8).
- If t_on < min_dwell: pulse is suppressed (t_on = 0.0 s, relay remains OFF).
- If t_off < min_dwell: clamped to full-on (t_on = window_s, t_off = 0.0 s, relay remains ON).
Returns `(on_time, off_time)`.
"""
function execute_guarded_relay_pwm(sp::IO, duty_cycle_pct::Real, window_s::Real, min_dwell_s::Real=1.0; channel::Int=0, sleep_fn::Function=sleep)::Tuple{Float64, Float64}
    # Enforce minimum dwell constraint (cannot be bypassed below 1.0 s)
    effective_min_dwell = max(Float64(min_dwell_s), 1.0)
    w_s = max(Float64(window_s), 0.0)
    duty = clamp(Float64(duty_cycle_pct), 0.0, 100.0)

    on_time = (duty / 100.0) * w_s

    # Enforce mechanical relay dwell constraints:
    if on_time < effective_min_dwell
        on_time = 0.0  # Suppress pulse below minimum dwell to prevent contact chatter
    elseif (w_s - on_time) < effective_min_dwell
        on_time = w_s  # Clamp to full-on if off-time violates minimum dwell
    end
    off_time = w_s - on_time

    if on_time > 0.0
        write(sp, "relay on $channel\r\n")
        flush(sp)
        sleep_fn(on_time)
    end
    if off_time > 0.0
        write(sp, "relay off $channel\r\n")
        flush(sp)
        sleep_fn(off_time)
    end
    return (on_time, off_time)
end

"""
    run_pwm_cycle(sp::IO, duty_cycle_percent::Real, window_s::Real, min_dwell_s::Real=1.0; channel::Int=0, sleep_fn::Function=sleep)::Tuple{Float64, Float64}

Executes ONE slow-PWM cycle using sleep() to modulate the mechanical relay.
Strictly enforces minimum dwell times (t_on, t_off >= 1.0 s) via `execute_guarded_relay_pwm`.
"""
function run_pwm_cycle(sp::IO, duty_cycle_percent::Real, window_s::Real, min_dwell_s::Real=1.0; channel::Int=0, sleep_fn::Function=sleep)::Tuple{Float64, Float64}
    return execute_guarded_relay_pwm(sp, duty_cycle_percent, window_s, min_dwell_s; channel=channel, sleep_fn=sleep_fn)
end

"""
    run_pwm_task!(sp, duty_ref, keep_running; relay_channel=0, window_ref, min_on_ref, min_off_ref, relay_state_ref)

Background task for continuous slow PWM on the Numato relay.
The duty cycle is sampled at the start of each PWM window so the main control loop
can update it asynchronously.
"""
function run_pwm_task!(sp::SerialPort,
                       duty_ref::Ref{Float64},
                       keep_running::Ref{Bool};
                       relay_channel::Int=0,
                       window_ref::Ref{Float64}=Ref(120.0),
                       min_on_ref::Ref{Float64}=Ref(20.0),
                       min_off_ref::Ref{Float64}=Ref(20.0),
                       relay_state_ref::Union{Nothing, Ref{Bool}}=nothing)
    try
        set_relay(sp, false, relay_channel)
        relay_state_ref !== nothing && (relay_state_ref[] = false)

        while keep_running[]
            duty = clamp(duty_ref[], 0.0, 100.0)
            window_s = max(window_ref[], 1.0)
            min_on_s = clamp(min_on_ref[], 0.0, window_s)
            min_off_s = clamp(min_off_ref[], 0.0, window_s - min_on_s)

            on_s, off_s = compute_pwm_times(duty, window_s, min_on_s, min_off_s)

            if on_s > 0.0
                set_relay(sp, true, relay_channel)
                relay_state_ref !== nothing && (relay_state_ref[] = true)
                t0 = time()
                while (time() - t0) < on_s && keep_running[]
                    sleep(0.5)
                end
            end

            set_relay(sp, false, relay_channel)
            relay_state_ref !== nothing && (relay_state_ref[] = false)
            if off_s > 0.0
                t0 = time()
                while (time() - t0) < off_s && keep_running[]
                    sleep(0.5)
                end
            end
        end
    finally
        try
            set_relay(sp, false, relay_channel)
        catch e
            @warn "Failed to force relay OFF during PWM task shutdown" exception = (e, catch_backtrace())
        end
        relay_state_ref !== nothing && (relay_state_ref[] = false)
    end
end

# ============================================================================
# CALIBRATION AND MAIN LOOP
# ============================================================================

"""
    interactive_calibration(sp::SerialPort)

Guides the user through setting two known points to calibrate the ADC -> CO2 mapping.
"""
function interactive_calibration(sp::SerialPort)
    println("=== 2-Point Sensor Calibration ===")
    println("Please apply the FIRST known CO2 concentration.")
    print("Enter Point 1 CO2 true value (Y1): ")
    y1_str = readline()
    y1 = parse(Float64, y1_str)
    
    println("Waiting for reading to stabilize...")
    sleep(2.0)
    x1 = read_adc(sp, 0)
    println("Read Point 1 ADC (X1) = $x1\n")
    
    println("Please apply the SECOND known CO2 concentration.")
    print("Enter Point 2 CO2 true value (Y2): ")
    y2_str = readline()
    y2 = parse(Float64, y2_str)
    
    println("Waiting for reading to stabilize...")
    sleep(2.0)
    x2 = read_adc(sp, 0)
    println("Read Point 2 ADC (X2) = $x2\n")
    
    cal = CO2SensorCalibration(x1, y1, x2, y2)
    println("Calibration Math Active: Y = $y1 + (($y2 - $y1) / ($x2 - $x1)) * (X - $x1)")
    return cal
end

"""
    run_standalone(port_name::String, baudrate::Int=115200)

Starts a standalone doser script, logs the data to a CSV file, and runs a slow PWM loop.
"""
function run_standalone(port_name::String, baudrate::Int=115200)
    # Open Serial Port
    sp = LibSerialPort.open(port_name, baudrate)
    log_io = nothing
    
    # Burden Resistor Calibration Baseline (Finding F26):
    # For a 4-20 mA sensor across a 263 Ω burden resistor on a 5.0 V ADC:
    # - 4.0 mA -> 1.052 V -> 215.35 ADC counts (0.0% span)
    # - 19.01 mA (5.00 V saturation ceiling) -> 1023.0 ADC counts (93.82% span)
    # The upper 6.18% of sensor span is clipped by ADC rail saturation.
    cal = CO2SensorCalibration(215.0, 0.0, 1023.0, 93.82)
    adc_cal = CalibratedADC4_20mA(263.0, 5.0, 1024.0) 
    
    print("Do you wish to run a new 2-point calibration? (y/n): ")
    ans = lowercase(strip(readline()))
    if ans == "y"
        cal = interactive_calibration(sp)
    else
        println("Using default calibration: $cal")
    end
    
    config = ControllerConfig()
    print("Enter target CO2 concentration (default $(config.target_co2)): ")
    target_str = readline()
    if !isempty(target_str)
        config.target_co2 = parse(Float64, target_str)
    end
    
    # Setup logger
    log_name = "co2_dosing_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv"
    open(log_name, "w") do f
        write(f, "Timestamp,ADC_Raw,CO2_Concentration,CO2_Setpoint,Duty_Cycle_Pct\n")
    end
    log_io = open(log_name, "a")
    println("Logging to $log_name ...")
    println("\nStarting control loop (10-second duty cycle window). Press Ctrl+C to abort.")
    
    try
        # Let device settle
        set_relay(sp, false)
        sleep(1.0)
        
        integral_error = 0.0
        while true
            # 1. READ ADC
            adc_val = read_adc(sp, 0)
            if isnan(adc_val) || adc_val < 0.0 || adc_val > 1023.0
                println("Failed to read ADC on this cycle. Retrying...")
                run_pwm_cycle(sp, 0.0, config.pwm_window_s)
                continue
            end
            
            # 2. CONVERT TO CO2
            co2_conc = adc_to_co2(adc_val, cal)
            
            # 3. CONTROL LOGIC
            duty_cycle, integral_error = compute_duty_cycle(
                co2_conc, config.target_co2, config.Kp, config.Ki, integral_error, config.pwm_window_s)
            
            # 4. LOG STATE
            timestamp_str = string(now())
            write(log_io, "$timestamp_str,$adc_val,$co2_conc,$(config.target_co2),$duty_cycle\n")
            flush(log_io)
            
            println("[$timestamp_str] ADC: $adc_val | CO2: $(round(co2_conc, digits=2)) | Target: $(config.target_co2) | PWM: $(round(duty_cycle, digits=1))%")
            
            # 5. EXECUTE ACTUATOR (Strict relay dwell time enforcement >= 1.0 s)
            on_s, off_s = compute_pwm_times(duty_cycle, config.pwm_window_s, config.min_on_s, config.min_off_s)
            run_pwm_cycle(sp, duty_cycle, config.pwm_window_s; min_dwell_s=max(config.min_on_s, 1.0))
            
        end
    catch e
        if isa(e, InterruptException)
            println("\nStopped by user.")
        else
            @error "Exception in control loop" exception=(e, catch_backtrace())
        end
    finally
        println("Safely turning off relay and closing port...")
        if log_io !== nothing
            try
                close(log_io)
            catch e
                @warn "Failed to close log file cleanly" exception = (e, catch_backtrace())
            end
        end
        try
            set_relay(sp, false) # Failsafe
        catch e
            @warn "Failed to force relay OFF during shutdown" exception = (e, catch_backtrace())
        end
        try
            close(sp)
        catch e
            @warn "Failed to close serial port cleanly" exception = (e, catch_backtrace())
        end
    end
end

end # module
