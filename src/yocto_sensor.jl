# ============================================================================
# YOCTOPUCE 4-20mA SENSOR MONITOR
# ============================================================================
# Background reader task connecting to the Yoctopuce 4-20mA dCO2 probe bridge.
# ============================================================================

using JSON3
using Dates

"""
    restart_yocto_bridge!(bridge_script::String, log_file::String="")

Terminate any unresponsive or stalled Yoctopuce sensor bridge processes and launch a fresh daemon instance.
Appends daemon output to `log_file` if provided.
"""
function restart_yocto_bridge!(bridge_script::String, log_file::String="")
    if !isfile(bridge_script)
        @warn "Cannot restart Yoctopuce bridge: script not found at $bridge_script"
        return false
    end
    try
        # Terminate any hung bridge process
        run(ignorestatus(`pkill -f "yocto_bridge.py"`))
        sleep(0.5)
    catch
    end

    try
        mkpath(dirname(log_file))
        cmd = `python3 $bridge_script`
        if !isempty(log_file)
            log_io = open(log_file, "a")
            run(pipeline(cmd, stdout=log_io, stderr=log_io), wait=false)
        else
            run(pipeline(cmd, stdout=devnull, stderr=devnull), wait=false)
        end
        println("[INFO] Restarted Yoctopuce 4-20mA sensor bridge daemon (logging to $(isempty(log_file) ? "devnull" : log_file))")
        flush(stdout)
        return true
    catch e
        @warn "Failed to restart Yoctopuce sensor bridge daemon" exception=e
        return false
    end
end

"""
    run_yocto_monitor_task!(keep_running, params, latest_yocto_data_ref; project_root, max_stale_age_s, restart_cooldown_s)

Background async task that reads the latest calibrated dissolved CO2 measurement from the
Yoctopuce 4-20mA bridge (plots/yocto_co2_live.json). Validates cache freshness and automatically
restarts the bridge daemon if data becomes stale or missing.
"""
function run_yocto_monitor_task!(
    keep_running::Ref{Bool},
    params::AbstractDict,
    latest_yocto_data_ref::Ref;
    project_root::String="",
    max_stale_age_s::Float64=20.0,
    restart_cooldown_s::Float64=30.0
)
    if isempty(project_root)
        project_root = dirname(dirname(@__DIR__))
    end
    cache_path = joinpath(project_root, "plots", "yocto_co2_live.json")
    bridge_script = joinpath(project_root, "tools", "yocto_bridge.py")
    log_file = joinpath(project_root, "plots", "yocto_bridge.log")

    last_restart_time = 0.0

    function maybe_restart_bridge!(reason::String)
        now_s = time()
        if (now_s - last_restart_time) >= restart_cooldown_s
            last_restart_time = now_s
            @warn "[YOCTO WATCHDOG] Data unavailable or stale ($reason). Initiating self-healing restart of bridge..."
            restart_yocto_bridge!(bridge_script, log_file)
        end
    end

    # Initial health check & launch if not currently running
    if isfile(bridge_script)
        is_running = try success(`pgrep -f "yocto_bridge.py"`) catch; false end
        if !is_running
            maybe_restart_bridge!("not running at startup")
        end
    end

    println("[INFO] Yocto monitor task active with watchdog. Polling $cache_path")
    flush(stdout)

    while keep_running[]
        try
            now_s = time()
            data_fresh = false

            if isfile(cache_path)
                content = try read(cache_path, String) catch; "" end
                if !isempty(strip(content))
                    parsed = try JSON3.read(content) catch; nothing end
                    if parsed !== nothing
                        is_valid = get(parsed, :valid, false) || get(parsed, "valid", false)
                        cache_ts = Float64(get(parsed, :timestamp, get(parsed, "timestamp", 0.0)))
                        age_s = now_s - cache_ts

                        if is_valid && age_s >= 0.0 && age_s <= max_stale_age_s
                            # Support mg/L, percentage, or raw value
                            dco2_val = Float64(get(parsed, :dco2_mg_L, get(parsed, "dco2_mg_L", get(parsed, :dco2_percent, get(parsed, "dco2_percent", get(parsed, :dco2_val, get(parsed, "dco2_val", NaN)))))))
                            raw_mA_val = Float64(get(parsed, :raw_mA, get(parsed, "raw_mA", NaN)))
                            if !isnan(dco2_val)
                                latest_yocto_data_ref[] = (dco2_measured=dco2_val, raw_mA=raw_mA_val, valid=true, last_update=now())
                                data_fresh = true
                            end
                        else
                            if age_s > max_stale_age_s
                                maybe_restart_bridge!("cache stale: $(round(age_s, digits=1))s > $(max_stale_age_s)s")
                            end
                        end
                    end
                end
            else
                maybe_restart_bridge!("cache file missing")
            end

            if !data_fresh
                latest_yocto_data_ref[] = (dco2_measured=NaN, raw_mA=NaN, valid=false, last_update=now())
                is_running = try success(`pgrep -f "yocto_bridge.py"`) catch; false end
                if !is_running
                    maybe_restart_bridge!("bridge process died")
                end
            end
        catch e
            @warn "Error reading Yocto sensor cache" exception=e
        end
        sleep(1.0)
    end
end
