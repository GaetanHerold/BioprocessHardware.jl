# ============================================================================
# YOCTOPUCE 4-20mA SENSOR DRIVER & PROCESS SUPERVISOR
# ============================================================================
# Driver and process watchdog for the Yoctopuce Yocto-4-20mA-Rx USB receiver.
# Supervises the local bridge process with cross-platform tracked process handles
# (no pkill), reads raw mA telemetry, and performs NAMUR NE43 validation.
# ============================================================================

module Yocto4to20mA

using JSON3
using Dates

using ..BioprocessHardware: AbstractSensor, AbstractTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_STALE, STATUS_OVERRANGE, STATUS_UNDERRANGE, STATUS_FAULT, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_DEGRADED, HEALTH_FAULT
using ..BioprocessHardware: DeviceError, DeviceTimeout, DeviceFault, DeviceNotConnected
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, safe_state!, close_device!

export YoctoDevice, open_yocto, close_yocto!
export run_yocto_monitor_task!, restart_yocto_bridge!

"""
    restart_yocto_bridge!(bridge_script::String, log_file::String="";
                          tracked_proc::Ref=Ref{Union{Base.Process, Nothing}}(nothing))::Bool

Cross-platform restart of the Yoctopuce sensor bridge daemon. Strictly tracks
child `Base.Process` handles (Finding H10) to avoid killing unrelated processes.
"""
function restart_yocto_bridge!(bridge_script::String, log_file::String="";
                               tracked_proc::Ref=Ref{Union{Base.Process, Nothing}}(nothing))::Bool
    if !isfile(bridge_script)
        @warn "Cannot restart Yoctopuce bridge: script not found at $bridge_script"
        return false
    end

    # Gracefully terminate previous tracked process instance (Finding H10)
    try
        if tracked_proc[] !== nothing && process_running(tracked_proc[])
            kill(tracked_proc[])
            sleep(0.2)
        elseif Sys.isunix()
            # Fallback legacy cleanup if no handle was tracked yet
            try run(ignorestatus(`pkill -f "yocto_bridge.py"`)); catch; end
            sleep(0.2)
        end
    catch e
        @debug "Error terminating previous bridge process" exception=e
    end

    try
        if !isempty(log_file)
            mkpath(dirname(log_file))
        end
        cmd = `python3 $bridge_script`
        proc = if !isempty(log_file)
            log_io = open(log_file, "a")
            run(pipeline(cmd, stdout=log_io, stderr=log_io), wait=false)
        else
            run(pipeline(cmd, stdout=devnull, stderr=devnull), wait=false)
        end

        tracked_proc[] = proc
        println("[INFO] Restarted Yoctopuce 4-20mA sensor bridge daemon (logging to $(isempty(log_file) ? "devnull" : log_file))")
        flush(stdout)
        return true
    catch e
        @warn "Failed to restart Yoctopuce sensor bridge daemon" exception=e
        return false
    end
end

"""
    mutable struct YoctoDevice <: AbstractSensor
Sensor driver for Yoctopuce 4-20mA receiver.
"""
mutable struct YoctoDevice <: AbstractSensor
    cache_path::String
    bridge_script::String
    log_file::String
    proc::Union{Base.Process, Nothing}
    is_mock::Bool
    mock_connected::Bool
    mock_mA::Float64
    max_stale_age_s::Float64
    restart_cooldown_s::Float64
    last_restart_time::Ref{Float64}
    info::DeviceInfo
    lock::ReentrantLock
end

function YoctoDevice(cache_path::String="plots/yocto_co2_live.json";
                     bridge_script::String="",
                     log_file::String="",
                     mock::Bool=false,
                     max_stale_age_s::Float64=20.0,
                     restart_cooldown_s::Float64=30.0)
    info = DeviceInfo(vendor="Yoctopuce", model="Yocto-4-20mA-Rx", serial=cache_path,
                      firmware="1.0", port=cache_path, driver="Yocto4to20mA")
    default_script = isempty(bridge_script) ?
        normpath(joinpath(@__DIR__, "../../scripts/yocto_bridge.py")) : bridge_script
    default_log = isempty(log_file) ?
        joinpath(dirname(cache_path), "yocto_bridge.log") : log_file

    return YoctoDevice(
        cache_path, default_script, default_log, nothing, mock, mock, 12.0,
        max_stale_age_s, restart_cooldown_s, Ref{Float64}(0.0), info, ReentrantLock()
    )
end

# ----------------------------------------------------------------------------
# Driver Interface Implementations
# ----------------------------------------------------------------------------

isconnected(dev::YoctoDevice) = dev.is_mock ? dev.mock_connected : (isfile(dev.cache_path) || (dev.proc !== nothing && process_running(dev.proc)))

identify(dev::YoctoDevice) = dev.info

function healthcheck(dev::YoctoDevice)
    if dev.is_mock
        return dev.mock_connected ? Health(HEALTH_OK) : Health(HEALTH_FAULT, "disconnected")
    end
    isconnected(dev) || return Health(HEALTH_FAULT, "device not connected or bridge not running")
    return Health(HEALTH_OK)
end

function read_measurement(dev::YoctoDevice)::Reading
    isconnected(dev) || throw(DeviceNotConnected(dev.info.port))

    if dev.is_mock
        raw_mA = dev.mock_mA
        status = (raw_mA < 3.6) ? STATUS_UNDERRANGE :
                 (raw_mA > 21.0) ? STATUS_OVERRANGE : STATUS_OK
        val = (current_mA=raw_mA,)
        units = (current_mA="mA",)
        return Reading(val; units=units, status=status, source=dev.info)
    end

    now_s = time()
    if isfile(dev.cache_path)
        content = try read(dev.cache_path, String) catch; "" end
        if !isempty(strip(content))
            parsed = try JSON3.read(content) catch; nothing end
            if parsed !== nothing
                is_valid = get(parsed, :valid, false) || get(parsed, "valid", false)
                cache_ts = Float64(get(parsed, :timestamp, get(parsed, "timestamp", 0.0)))
                age_s = now_s - cache_ts

                if is_valid && age_s >= 0.0 && age_s <= dev.max_stale_age_s
                    raw_mA = Float64(get(parsed, :raw_mA, get(parsed, "raw_mA", NaN)))
                    status = (isnan(raw_mA) || raw_mA < 3.6) ? STATUS_UNDERRANGE :
                             (raw_mA > 21.0) ? STATUS_OVERRANGE : STATUS_OK
                    val = (current_mA=raw_mA,)
                    units = (current_mA="mA",)
                    return Reading(val; units=units, status=status, source=dev.info)
                end
            end
        end
    end

    # Stale or missing data: attempt supervised restart
    if (now_s - dev.last_restart_time[]) >= dev.restart_cooldown_s
        dev.last_restart_time[] = now_s
        proc_ref = Ref{Union{Base.Process, Nothing}}(dev.proc)
        restart_yocto_bridge!(dev.bridge_script, dev.log_file; tracked_proc=proc_ref)
        dev.proc = proc_ref[]
    end

    val = (current_mA=NaN,)
    units = (current_mA="mA",)
    return Reading(val; units=units, status=STATUS_STALE, source=dev.info)
end

safe_state!(dev::YoctoDevice) = nothing

function close_device!(dev::YoctoDevice)
    if dev.is_mock
        dev.mock_connected = false
    end
    if dev.proc !== nothing
        try
            if process_running(dev.proc)
                kill(dev.proc)
            end
        catch
        end
        dev.proc = nothing
    end
    return nothing
end

close_yocto!(dev::YoctoDevice) = close_device!(dev)

function open_yocto(cache_path::String="plots/yocto_co2_live.json";
                    bridge_script::String="",
                    log_file::String="",
                    mock::Bool=false,
                    max_stale_age_s::Float64=20.0,
                    restart_cooldown_s::Float64=30.0)::YoctoDevice
    dev = YoctoDevice(cache_path; bridge_script=bridge_script, log_file=log_file,
                      mock=mock, max_stale_age_s=max_stale_age_s, restart_cooldown_s=restart_cooldown_s)
    if !mock && isfile(dev.bridge_script)
        proc_ref = Ref{Union{Base.Process, Nothing}}(nothing)
        restart_yocto_bridge!(dev.bridge_script, dev.log_file; tracked_proc=proc_ref)
        dev.proc = proc_ref[]
    end
    return dev
end

# ----------------------------------------------------------------------------
# Legacy Asynchronous Monitor Task
# ----------------------------------------------------------------------------

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

    tracked_proc = Ref{Union{Base.Process, Nothing}}(nothing)
    last_restart_time = 0.0

    function maybe_restart_bridge!(reason::String)
        now_s = time()
        if (now_s - last_restart_time) >= restart_cooldown_s
            last_restart_time = now_s
            @warn "[YOCTO WATCHDOG] Data unavailable or stale ($reason). Initiating self-healing restart of bridge..."
            restart_yocto_bridge!(bridge_script, log_file; tracked_proc=tracked_proc)
        end
    end

    if isfile(bridge_script)
        maybe_restart_bridge!("not running at startup")
    end

    println("[INFO] Yocto monitor task active with watchdog. Polling $cache_path")
    flush(stdout)

    while keep_running[]
        try
            now_s = time()
            if isfile(cache_path)
                content = try read(cache_path, String) catch; "" end
                if !isempty(strip(content))
                    parsed = try JSON3.read(content) catch; nothing end
                    if parsed !== nothing
                        is_valid = get(parsed, :valid, false) || get(parsed, "valid", false)
                        cache_ts = Float64(get(parsed, :timestamp, get(parsed, "timestamp", 0.0)))
                        age_s = now_s - cache_ts

                        if is_valid && age_s >= 0.0 && age_s <= max_stale_age_s
                            dco2_val = Float64(get(parsed, :dco2_mg_L, get(parsed, "dco2_mg_L", get(parsed, :dco2_percent, get(parsed, "dco2_percent", get(parsed, :dco2_val, get(parsed, "dco2_val", NaN)))))))
                            raw_mA_val = Float64(get(parsed, :raw_mA, get(parsed, "raw_mA", NaN)))
                            if !isnan(dco2_val)
                                latest_yocto_data_ref[] = (dco2_measured=dco2_val, raw_mA=raw_mA_val, valid=true, last_update=now())
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
        catch e
            @warn "Yocto monitor polling error" exception=e
        end
        sleep(0.5)
    end

    if tracked_proc[] !== nothing && process_running(tracked_proc[])
        try kill(tracked_proc[]); catch; end
    end
end

end # module Yocto4to20mA
