using Test
using JSON3
using Dates
using BioprocessHardware

isdefined(Main, :test_sensor_contract) || include("contract.jl")

@testset "Yocto 4-20mA Sensor & Staleness Watchdog" begin
    mktempdir() do tmpdir
        plots_dir = joinpath(tmpdir, "plots")
        tools_dir = joinpath(tmpdir, "tools")
        mkpath(plots_dir)
        mkpath(tools_dir)

        cache_file = joinpath(plots_dir, "yocto_co2_live.json")
        bridge_script = joinpath(tools_dir, "yocto_bridge.py")

        # Create mock bridge script that writes a fresh cache file
        write(bridge_script, """
import time
import json
import sys

data = {
    "timestamp": time.time(),
    "raw_mA": 12.0,
    "dco2_mg_L": 600.0,
    "dco2_percent": 600.0,
    "dco2_val": 600.0,
    "unit": "mg/L",
    "valid": True,
    "friendly_name": "MockSensor1"
}
with open("$cache_file", "w") as f:
    json.dump(data, f)
""")

        # 1. Test restart_yocto_bridge!
        log_file = joinpath(plots_dir, "yocto_bridge.log")
        res = restart_yocto_bridge!(bridge_script, log_file)
        @test res == true
        sleep(0.5)
        @test isfile(cache_file)

        # 2. Test fresh cache parsing via run_yocto_monitor_task!
        keep_running = Ref{Bool}(true)
        params = Dict{String, Any}()
        latest_data = Ref((dco2_measured=NaN, raw_mA=NaN, valid=false, last_update=DateTime(0)))

        task = Threads.@spawn run_yocto_monitor_task!(
            keep_running, params, latest_data;
            project_root=tmpdir, max_stale_age_s=2.0, restart_cooldown_s=1.0
        )

        sleep(1.5)
        @test latest_data[].valid == true
        @test isapprox(latest_data[].dco2_measured, 600.0; atol=1.0)
        @test isapprox(latest_data[].raw_mA, 12.0; atol=0.1)

        # 3. Simulate stale cache (write timestamp 10 seconds in the past)
        stale_data = Dict(
            "timestamp" => time() - 10.0,
            "raw_mA" => 12.0,
            "dco2_mg_L" => 600.0,
            "valid" => true
        )
        write(cache_file, JSON3.write(stale_data))

        # Allow time for restarted mock bridge process to execute and write fresh file
        refreshed = false
        for _ in 1:20
            sleep(0.2)
            if latest_data[].valid == true
                refreshed = true
                break
            end
        end
        @test refreshed == true

        # Clean shutdown
        keep_running[] = false
        wait(task)

        # 4. Common Sensor Contract on YoctoDevice
        test_sensor_contract(
            () -> open_yocto(cache_file; mock=true),
            label="YoctoDevice"
        )

        # 5. NAMUR NE43 broken wire and overrange classification
        dev_mock = open_yocto(cache_file; mock=true)
        dev_mock.mock_mA = 2.5 # Broken wire < 3.6 mA
        r_broken = read_measurement(dev_mock)
        @test r_broken.status == STATUS_UNDERRANGE

        dev_mock.mock_mA = 22.5 # Overrange > 21.0 mA
        r_over = read_measurement(dev_mock)
        @test r_over.status == STATUS_OVERRANGE

        close_yocto!(dev_mock)
        @test !isconnected(dev_mock)
    end
end
