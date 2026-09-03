# ============================================================================
# YOCTOPUCE 4-20mA SENSOR MONITOR
# ============================================================================
# Background reader task connecting to the Yoctopuce 4-20mA dCO2 probe bridge.
# ============================================================================

using JSON3
using Dates

"""
    run_yocto_monitor_task!(keep_running, params, latest_yocto_data_ref; project_root)

Background async task that reads the latest calibrated dissolved CO2 measurement from the
Yoctopuce 4-20mA bridge (plots/yocto_co2_live.json) and launches the bridge daemon if needed.
"""
function run_yocto_monitor_task!(
    keep_running::Ref{Bool},
    params::AbstractDict,
    latest_yocto_data_ref::Ref;
    project_root::String=""
)
    if isempty(project_root)
        project_root = dirname(dirname(@__DIR__))
    end
    cache_path = joinpath(project_root, "plots", "yocto_co2_live.json")
    bridge_script = joinpath(project_root, "tools", "yocto_bridge.py")

    if isfile(bridge_script)
        try
            is_running = success(`pgrep -f "yocto_bridge.py"`)
            if !is_running
                run(pipeline(`python3 $bridge_script`, stdout=devnull, stderr=devnull), wait=false)
                println("[INFO] Launched Yoctopuce 4-20mA sensor bridge daemon")
            end
        catch e
            @warn "Failed to check or auto-launch Yoctopuce bridge script" exception=e
        end
    end

    println("[INFO] Yocto monitor task active. Polling $cache_path")
    while keep_running[]
        try
            # Check daemon health every cycle and respawn if terminated
            if isfile(bridge_script)
                is_running = try success(`pgrep -f "yocto_bridge.py"`) catch; false end
                if !is_running
                    try
                        run(pipeline(`python3 $bridge_script`, stdout=devnull, stderr=devnull), wait=false)
                    catch
                    end
                end
            end

            if isfile(cache_path)
                content = read(cache_path, String)
                if !isempty(strip(content))
                    parsed = JSON3.read(content)
                    is_valid = get(parsed, :valid, false) || get(parsed, "valid", false)
                    if is_valid
                        dco2_val = Float64(get(parsed, :dco2_percent, get(parsed, "dco2_percent", get(parsed, :dco2_val, get(parsed, "dco2_val", NaN)))))
                        raw_mA_val = Float64(get(parsed, :raw_mA, get(parsed, "raw_mA", NaN)))
                        if !isnan(dco2_val)
                            latest_yocto_data_ref[] = (dco2_measured=dco2_val, raw_mA=raw_mA_val, valid=true, last_update=now())
                        else
                            latest_yocto_data_ref[] = (dco2_measured=NaN, raw_mA=NaN, valid=false, last_update=now())
                        end
                    else
                        latest_yocto_data_ref[] = (dco2_measured=NaN, raw_mA=NaN, valid=false, last_update=now())
                    end
                end
            end
        catch e
            @warn "Error reading Yocto sensor cache" exception=e
        end
        sleep(1.0)
    end
end
