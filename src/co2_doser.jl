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
export read_adc, read_co2_percent, set_relay, adc_to_co2
export compute_duty_cycle, compute_pwm_times, run_pwm_cycle, run_pwm_task!
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

Base.@kwdef mutable struct ControllerConfig
    target_co2::Float64 = 5.0
    Kp::Float64 = 10.0
    Ki::Float64 = 0.02
    pwm_window_s::Float64 = 10.0
    min_on_s::Float64 = 0.0
    min_off_s::Float64 = 0.0
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
function read_co2_percent(sp::SerialPort, cal::CO2SensorCalibration; channel::Int=0)
    adc_val = read_adc(sp, channel)
    return isnan(adc_val) ? NaN : adc_to_co2(adc_val, cal)
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
    compute_pwm_times(duty_pct, window_s, min_on_s, min_off_s)

Convert a duty cycle into ON/OFF times while respecting slow-PWM minimum
switching constraints for a mechanical relay.
"""
function compute_pwm_times(duty_pct::Float64, window_s::Float64,
                           min_on_s::Float64, min_off_s::Float64)::Tuple{Float64, Float64}
    duty_pct = clamp(duty_pct, 0.0, 100.0)
    duty_pct == 0.0 && return (0.0, window_s)
    duty_pct == 100.0 && return (window_s, 0.0)

    raw_on = duty_pct / 100.0 * window_s
    on_s = clamp(raw_on, min_on_s, window_s - min_off_s)
    return (on_s, window_s - on_s)
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
    set_relay(sp::SerialPort, state::Bool, channel::Int=0)

Turns the mechanical relay ON or OFF.
"""
function set_relay(sp::SerialPort, state::Bool, channel::Int=0)
    if state
        write(sp, "relay on $channel\r")
    else
        write(sp, "relay off $channel\r")
    end
    flush(sp)
end

"""
    run_pwm_cycle(sp::SerialPort, duty_cycle_percent::Float64, window_s::Float64)

Executes ONE slow-PWM cycle using sleep() to modulate the mechanical relay.
DO NOT use high frequency.
"""
function run_pwm_cycle(sp::SerialPort, duty_cycle_percent::Float64, window_s::Float64)
    on_time = (duty_cycle_percent / 100.0) * window_s
    off_time = window_s - on_time
    
    if on_time > 0
        set_relay(sp, true)
        sleep(on_time)
    end
    
    if off_time > 0
        set_relay(sp, false)
        sleep(off_time)
    end
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
    
    # Base defaults: roughly ~1V to ~5V translates to 200 to 1023 ADC
    # We will assume a 0 to 100% reading scale for an arbitrary placeholder.
    cal = CO2SensorCalibration(215.0, 0.0, 1023.0, 100.0) 
    
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
            
            # 5. EXECUTE ACTUATOR
            on_s, off_s = compute_pwm_times(duty_cycle, config.pwm_window_s, config.min_on_s, config.min_off_s)
            run_pwm_cycle(sp, duty_cycle, on_s + off_s)
            
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
