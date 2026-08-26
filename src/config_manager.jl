# ============================================================================
# CONFIGURATION & PARAMETER MANAGER
# ============================================================================
# Handles loading, JSON comment-stripping, validation, defaulting, and atomic
# saving of control parameters for the LUCRA Pilot System.
# ============================================================================

using JSON3

"""
    load_control_parameters(filename::String)

Load control parameters from a JSON file with support for comments and Windows COM port dynamic overrides.

Supports:
- Single-line comments: // comment or # comment
- Trailing comments: "key": value  // comment
- Multi-line comments: /* comment */

Returns a `Dict{String,Any}` with all parameters.
Throws error if file does not exist.
"""
function load_control_parameters(filename::String)
    if !isfile(filename)
        error("Parameter file not found: $filename")
    end

    # Read file content
    content = read(filename, String)

    # Strip comments for JSON parsing
    # Remove single-line comments (// ... to end of line)
    content = replace(content, r"//.*?$"m => "")

    # Remove multi-line comments (/* ... */)
    content = replace(content, r"/\*.*?\*/"s => "")

    # Remove trailing commas before closing braces/brackets (common error)
    content = replace(content, r",(\s*[}\]])" => s"\1")

    # Parse cleaned JSON
    json_obj = JSON3.read(content)

    # Convert to Dict with String keys (JSON3 uses Symbol keys by default)
    params = Dict{String,Any}(String(k) => v for (k, v) in pairs(json_obj))

    # Apply Windows COM Port Dynamic Anti-Swapping Overrides if on Windows
    if Sys.iswindows() && isdefined(Main, :detect_windows_com_ports)
        detected_ports = detect_windows_com_ports()
        if haskey(detected_ports, "esp32")
            old_port = get(params, "serial_port", "not set")
            if old_port != detected_ports["esp32"]
                params["serial_port"] = detected_ports["esp32"]
                println("[INFO] Anti-Swapping Override: Overrode serial_port from '$old_port' to '$(detected_ports["esp32"])'")
            end
        end
        if haskey(detected_ports, "numato")
            old_port = get(params, "co2_numato_port", "not set")
            if old_port != detected_ports["numato"]
                params["co2_numato_port"] = detected_ports["numato"]
                println("[INFO] Anti-Swapping Override: Overrode co2_numato_port from '$old_port' to '$(detected_ports["numato"])'")
            end
        end
    end

    return params
end

"""
    save_params_to_json(params, filename::String)

Save parameters dictionary to JSON file with pretty formatting.
"""
function save_params_to_json(params, filename::String)
    sanitized = Dict{String, Any}()
    for (k, v) in params
        if isa(v, AbstractFloat) && isnan(v)
            sanitized[string(k)] = nothing
        else
            sanitized[string(k)] = v
        end
    end
    open(filename, "w") do f
        JSON3.pretty(f, sanitized)
    end
end

"""
    apply_parameter_defaults!(params::Dict)

Fill in missing parameters with sensible defaults and enforce Float64 numeric types.
Modifies params dictionary in-place.
"""
function apply_parameter_defaults!(params::Dict)
    # Define default values for all possible parameters
    defaults = Dict{String,Any}(
        "VVM" => 0.1,                    # Vessel volumes per minute (gas flow)
        "R_gas" => 0.082057,             # Ideal gas constant [L·atm/(mol·K)]
        "T_K" => 310.15,                 # Temperature [K] (37°C, typical fermentation)
        "P_CO2_gas" => 1.0,              # CO₂ partial pressure [atm]
        "Z_succ_avg" => 2.0,             # Average charge of succinate (≈2 at pH 7)
        "Z_carb_avg" => 1.0,             # Average charge of carbonate (≈1 at pH 7)
        "D_succ_bulk" => 0.783e-9,       # succinate²⁻ bulk diffusivity [m²/s]
        "D_HCO3_bulk" => 1.185e-9,       # bicarbonate⁻ bulk diffusivity [m²/s]
        "D_acet_bulk" => 1.089e-9,       # acetate⁻ bulk diffusivity [m²/s]
        "K_Don"       => 1.5,            # Donnan enhancement factor [-]
        "A_mem"       => 0.01,           # Effective AEM area [m²]
        "C_acet_bg"   => 0.0,            # Background acetate [mol/L]
        "J_max_OH" => 1e-4,              # Maximum OH⁻ flux [mol/L/s]
        "controlLim" => 5.0,             # Maximum control output [0-5 A]
        "tau_adapt" => 600.0,            # Adaptation time constant [s]
        "gamma_adapt" => 0.0,            # Adaptation gain (0 = disabled)
        "deadband" => 0.05,              # Adaptation deadband [pH units]
        "pH_initial_non_measured" => NaN, # Initial pH for non-measured vessel
        "pH_ferm_offset" => 0.0,         # Offline pH offset for fermenter probe [pH units]
        "pH_extr_offset" => 0.0,         # Offline pH offset for extraction probe [pH units]
        "initial_current" => 0.0,        # Initial control output
        "reset_parameters" => false,     # Flag for hard reset
        "soft_reset_parameters" => false, # Flag for soft reset
        "target_pH" => 7.2,              # pH setpoint
        "control_interval" => 1.0,       # Time between control executions [s]
        "time_resolution" => 0.1,        # Time step for model discretization [s]
        "use_new_unit" => true,          # Standalone new hardware interface mode
        "co2_max_lpm" => 30.0,           # MFC full-scale flow rate [L/min]
        "co2_min_continuous_lpm" => 3.0, # MFC minimum continuous flow [L/min]
        "co2_low_flow_mode" => "cutoff", # "cutoff" or "pwm"
        "pump_max_L_h" => 10.0,          # Filtrate pump maximum flow rate [L/h]
        "pump_min" => 0.0,               # Minimum pump percentage [0.0 = allow stop]
        "pump_baseline" => 50.0,         # Baseline pump setpoint [%]
        "pump_slew_rate_limit" => 20.0,  # Pump slew rate limit [%/min]
        "manual_override_mode" => false, # Constant output test mode (bypasses feedback)
        "manual_current_A" => 0.0,       # Constant current setpoint [A] in manual mode
        "manual_co2_pct" => 0.0,         # Constant CO2 setpoint [%] in manual mode
        "manual_pump_pct" => 50.0,       # Constant filtrate pump setpoint [%] in manual mode
        "co2_setpoint" => 0.0,           # CO₂ setpoint (%)
        "co2_actuation_mode" => "mcu",   # mcu | local_pwm
        "co2_numato_port" => "COM3",
        "co2_numato_baudrate" => 115200,
        "co2_adc_channel" => 0,
        "co2_relay_channel" => 0,
        "co2_cal_X1" => 205.0,
        "co2_cal_Y1" => 0.0,
        "co2_cal_X2" => 1023.0,
        "co2_cal_Y2" => 98.71,
        "co2_pi_Kp" => 10.0,
        "co2_pi_Ki" => 0.02,
        "co2_pwm_window_s" => 120.0,
        "co2_pwm_min_on_s" => 20.0,
        "co2_pwm_min_off_s" => 20.0,
        "yocto_mA_min" => 4.0,
        "yocto_mA_max" => 20.0,
        "yocto_co2_min" => 0.0,
        "yocto_co2_max" => 1200.0
    )

    # Apply defaults for any missing keys
    for (key, default_val) in defaults
        if !haskey(params, key)
            params[key] = default_val
        end
    end

    # Type Conversion to Float64
    numeric_keys = [
        "VVM", "R_gas", "T_K", "P_CO2_gas", "Z_succ_avg", "Z_carb_avg",
        "D_succ_bulk", "D_HCO3_bulk", "D_acet_bulk", "K_Don", "A_mem", "C_acet_bg",
        "J_max_OH", "controlLim", "tau_adapt", "gamma_adapt", "deadband",
        "pH_ferm_offset", "pH_extr_offset",
        "co2_max_lpm", "co2_min_continuous_lpm", "pump_max_L_h", "pump_min", "pump_baseline", "pump_slew_rate_limit",
        "manual_current_A", "manual_co2_pct", "manual_pump_pct",
        "yocto_mA_min", "yocto_mA_max", "yocto_co2_min", "yocto_co2_max",
        "Kp", "Ki", "Kd", "tau_I", "tau_D", "initial_current",
        "target_pH", "control_interval", "time_resolution", "rolling_window", "co2_setpoint",
        "co2_numato_baudrate", "co2_adc_channel", "co2_relay_channel",
        "co2_cal_X1", "co2_cal_Y1", "co2_cal_X2", "co2_cal_Y2",
        "co2_pi_Kp", "co2_pi_Ki", "co2_pwm_window_s", "co2_pwm_min_on_s", "co2_pwm_min_off_s"
    ]

    for key in numeric_keys
        if haskey(params, key) && !isnan(params[key])
            params[key] = Float64(params[key])
        end
    end

    # Special handling for NaN in pH_initial_non_measured
    if haskey(params, "pH_initial_non_measured")
        val = params["pH_initial_non_measured"]
        if val === nothing || val === "null"
            params["pH_initial_non_measured"] = NaN
        else
            params["pH_initial_non_measured"] = Float64(val)
        end
    end
end
