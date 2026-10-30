# ============================================================================
# CONFIGURATION & PARAMETER MANAGER
# ============================================================================
# Handles loading, string-safe JSONC comment-stripping, type normalization,
# hardware defaulting, and atomic saving of configuration files.
# ============================================================================

using JSON3

export strip_json_comments, apply_hardware_defaults!, HARDWARE_PARAMETER_DEFAULTS

"""
    strip_json_comments(content::AbstractString) -> String

Strip single-line (`// ...` and `# ...`), multi-line (`/* ... */`) comments, and
trailing commas from a JSONC string without corrupting `//` or `#` inside quoted
string literals (e.g., URLs like `"http://127.0.0.1:4444"`).
"""
function strip_json_comments(content::AbstractString)::String
    buf = IOBuffer()
    chars = collect(content)
    n = length(chars)
    i = 1
    in_string = false
    escape_next = false

    while i <= n
        c = chars[i]
        if in_string
            write(buf, c)
            if escape_next
                escape_next = false
            elseif c == '\\'
                escape_next = true
            elseif c == '"'
                in_string = false
            end
            i += 1
        else
            if c == '"'
                in_string = true
                write(buf, c)
                i += 1
            elseif c == '/' && i < n && chars[i + 1] == '/'
                # Skip single-line // comment until newline
                i += 2
                while i <= n && chars[i] != '\n'
                    i += 1
                end
            elseif c == '#'
                # Skip single-line # comment until newline
                i += 1
                while i <= n && chars[i] != '\n'
                    i += 1
                end
            elseif c == '/' && i < n && chars[i + 1] == '*'
                # Skip multi-line /* ... */ comment
                i += 2
                while i <= n && !(i < n && chars[i] == '*' && chars[i + 1] == '/')
                    if chars[i] == '\n'
                        write(buf, '\n')
                    end
                    i += 1
                end
                i += 2
            else
                write(buf, c)
                i += 1
            end
        end
    end

    cleaned = String(take!(buf))
    # Remove trailing commas before closing braces/brackets
    return replace(cleaned, r",(\s*[}\]])" => s"\1")
end

"""
    load_control_parameters(filename::String) -> Dict{String,Any}

Load parameters from a JSON/JSONC file with comment stripping and Windows COM port dynamic overrides.
"""
function load_control_parameters(filename::String)
    if !isfile(filename)
        error("Parameter file not found: $filename")
    end

    content = read(filename, String)
    cleaned = strip_json_comments(content)
    json_obj = JSON3.read(cleaned)
    params = Dict{String,Any}(String(k) => v for (k, v) in pairs(json_obj))

    # Apply Windows COM Port Dynamic Anti-Swapping Overrides if on Windows
    if Sys.iswindows()
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

Atomically save parameters dictionary to a JSON file with pretty formatting.
Writes to a temporary file in the same directory and renames atomically via `mv`.
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
    dir = dirname(abspath(filename))
    mkpath(dir)
    tmp_path = joinpath(dir, ".tmp_" * basename(filename) * "_" * string(getpid()) * "_" * string(time_ns()))
    try
        open(tmp_path, "w") do f
            JSON3.pretty(f, sanitized)
        end
        mv(tmp_path, filename; force = true)
    catch err
        rm(tmp_path; force = true)
        rethrow(err)
    end
    return filename
end

"Hardware-only default parameters (ports, channels, 4-20 mA & ADC bounds, PWM timing)."
const HARDWARE_PARAMETER_DEFAULTS = Dict{String,Any}(
    "use_new_unit" => true,
    "co2_max_lpm" => 30.0,
    "co2_min_continuous_lpm" => 3.0,
    "co2_low_flow_mode" => "cutoff",
    "pump_max_L_h" => 10.0,
    "pump_min" => 0.0,
    "pump_baseline" => 50.0,
    "pump_slew_rate_limit" => 20.0,
    "manual_override_mode" => false,
    "manual_current_A" => 0.0,
    "manual_co2_pct" => 0.0,
    "manual_pump_pct" => 50.0,
    "co2_setpoint" => 0.0,
    "co2_actuation_mode" => "mcu",
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
    "yocto_co2_max" => 1200.0,
)

"Legacy process and controller defaults retained for backward-compatible `apply_parameter_defaults!` calls."
const LEGACY_PROCESS_DEFAULTS = Dict{String,Any}(
    "VVM" => 0.1,
    "R_gas" => 0.082057,
    "T_K" => 310.15,
    "P_CO2_gas" => 1.0,
    "Z_succ_avg" => 2.0,
    "Z_carb_avg" => 1.0,
    "D_succ_bulk" => 1.049e-9,
    "D_HCO3_bulk" => 1.588e-9,
    "D_acet_bulk" => 1.459e-9,
    "K_Don" => 1.5,
    "A_mem" => 0.01,
    "C_acet_bg" => 0.0,
    "J_max_OH" => 1e-4,
    "controlLim" => 5.0,
    "tau_adapt" => 600.0,
    "gamma_adapt" => 0.0,
    "deadband" => 0.05,
    "pH_initial_non_measured" => NaN,
    "pH_ferm_offset" => 0.0,
    "pH_extr_offset" => 0.0,
    "initial_current" => 0.0,
    "reset_parameters" => false,
    "soft_reset_parameters" => false,
    "target_pH" => 7.2,
    "control_interval" => 1.0,
    "time_resolution" => 0.1,
)

const INTEGER_PARAMETER_KEYS = Set{String}([
    "co2_numato_baudrate", "co2_adc_channel", "co2_relay_channel",
    "baud_rate", "yocto_channel", "n_membranes", "max_pred_steps",
])

const FLOAT_PARAMETER_KEYS = Set{String}([
    "VVM", "R_gas", "T_K", "P_CO2_gas", "Z_succ_avg", "Z_carb_avg",
    "D_succ_bulk", "D_HCO3_bulk", "D_acet_bulk", "K_Don", "A_mem", "C_acet_bg",
    "J_max_OH", "controlLim", "tau_adapt", "gamma_adapt", "deadband",
    "pH_ferm_offset", "pH_extr_offset",
    "co2_max_lpm", "co2_min_continuous_lpm", "pump_max_L_h", "pump_min", "pump_baseline", "pump_slew_rate_limit",
    "manual_current_A", "manual_co2_pct", "manual_pump_pct",
    "yocto_mA_min", "yocto_mA_max", "yocto_co2_min", "yocto_co2_max",
    "Kp", "Ki", "Kd", "tau_I", "tau_D", "initial_current",
    "target_pH", "control_interval", "time_resolution", "rolling_window", "co2_setpoint",
    "co2_cal_X1", "co2_cal_Y1", "co2_cal_X2", "co2_cal_Y2",
    "co2_pi_Kp", "co2_pi_Ki", "co2_pwm_window_s", "co2_pwm_min_on_s", "co2_pwm_min_off_s",
])

function _normalize_parameter_types!(params::Dict, defaults_lookup::AbstractDict)
    for key in INTEGER_PARAMETER_KEYS
        if haskey(params, key)
            val = params[key]
            if val === nothing || val === "null" || (val isa AbstractFloat && isnan(val))
                params[key] = get(defaults_lookup, key, 0)
            elseif val isa AbstractString
                parsed = tryparse(Int, strip(val))
                params[key] = parsed === nothing ? round(Int, parse(Float64, strip(val))) : parsed
            else
                params[key] = round(Int, val)
            end
        end
    end

    for key in FLOAT_PARAMETER_KEYS
        if haskey(params, key)
            val = params[key]
            if val === nothing || val === "null"
                params[key] = Float64(get(defaults_lookup, key, NaN))
            elseif val isa AbstractString
                parsed = tryparse(Float64, strip(val))
                params[key] = parsed === nothing ? NaN : parsed
            elseif val isa Real
                params[key] = Float64(val)
            end
        end
    end

    if haskey(params, "pH_initial_non_measured")
        val = params["pH_initial_non_measured"]
        if val === nothing || val === "null"
            params["pH_initial_non_measured"] = NaN
        elseif val isa AbstractString
            parsed = tryparse(Float64, strip(val))
            params["pH_initial_non_measured"] = parsed === nothing ? NaN : parsed
        else
            params["pH_initial_non_measured"] = Float64(val)
        end
    end
    return params
end

"""
    apply_hardware_defaults!(params::Dict; extra_defaults::AbstractDict = Dict{String,Any}())

Populate missing hardware-layer configuration keys (`HARDWARE_PARAMETER_DEFAULTS` plus any `extra_defaults`)
and enforce `Int` vs `Float64` types without injecting application-specific process/chemistry parameters.
"""
function apply_hardware_defaults!(params::Dict; extra_defaults::AbstractDict = Dict{String,Any}())
    merged_defaults = merge(HARDWARE_PARAMETER_DEFAULTS, extra_defaults)
    for (key, default_val) in merged_defaults
        if !haskey(params, key) || params[key] === nothing || params[key] === "null"
            params[key] = default_val
        end
    end
    return _normalize_parameter_types!(params, merged_defaults)
end

"""
    apply_parameter_defaults!(params::Dict; include_legacy_process_defaults::Bool = true, extra_defaults::AbstractDict = Dict{String,Any}())

Fill in missing parameters and enforce numeric types (`Int` for channels/baudrates, `Float64` for continuous values).
When `include_legacy_process_defaults = false`, only hardware defaults and `extra_defaults` are applied.
"""
function apply_parameter_defaults!(
    params::Dict;
    include_legacy_process_defaults::Bool = true,
    extra_defaults::AbstractDict = Dict{String,Any}()
)
    base_defaults = include_legacy_process_defaults ?
        merge(LEGACY_PROCESS_DEFAULTS, HARDWARE_PARAMETER_DEFAULTS, extra_defaults) :
        merge(HARDWARE_PARAMETER_DEFAULTS, extra_defaults)

    for (key, default_val) in base_defaults
        if !haskey(params, key)
            params[key] = default_val
        end
    end
    return _normalize_parameter_types!(params, base_defaults)
end
