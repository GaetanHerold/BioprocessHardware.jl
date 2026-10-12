# ============================================================================
# STANDALONE EXAMPLE: Voltcraft DPPS-16-30 Power Supply Logger
# ============================================================================
# Use this script when cloning BioprocessHardware.jl independently on any laptop.
# Usage:
#   julia --project=. examples/log_power_supply.jl
#   julia --project=. examples/log_power_supply.jl COM4
#   julia --project=. examples/log_power_supply.jl /dev/ttyUSB0
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)

using BioprocessHardware
using Dates
using Printf

function main()
    target_port = if length(ARGS) >= 1
        ARGS[1]
    else
        detected = detect_dpps_ports()
        if !isempty(detected)
            println("[INFO] Auto-detected candidate port(s): $(join(detected, ", "))")
            detected[1]
        elseif Sys.iswindows()
            "COM4"
        elseif Sys.isapple()
            "/dev/cu.usbserial-10"
        else
            "/dev/ttyUSB0"
        end
    end

    csv_path = "power_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv"

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               VOLTCRAFT DPPS-16-30 STANDALONE BENCH LOGGER               ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Port:          $target_port (9600 baud)")
    println("  Logging to:    $csv_path")
    println("  Stop:          Press Ctrl+C to finish")
    println("-"^76)
    @printf("%-23s │ %-9s │ %-9s │ %-9s │ %-4s\n", "Timestamp", "Voltage", "Current", "Power", "Mode")
    println("-"^76)

    open(csv_path, "w") do io
        println(io, "timestamp,voltage_V,current_A,power_W,mode")
    end

    dev = try
        open_dpps(target_port; baudrate=9600)
    catch e
        @warn "[WARNING] Port '$target_port' not opened: $e"
        println("[INFO] Running in MOCK SIMULATION mode for demonstration.")
        open_dpps(target_port; mock=true)
    end

    try
        while true
            r = read_dpps_telemetry(dev)
            ts = Dates.format(r.timestamp, "yyyy-mm-dd HH:MM:SS.sss")

            @printf("%-23s │ %7.2f V │ %7.2f A │ %7.2f W │ %-4s\n",
                    ts, r.voltage_V, r.current_A, r.power_W, r.mode)

            open(csv_path, "a") do io
                @printf(io, "%s,%.3f,%.3f,%.3f,%s\n",
                        ts, r.voltage_V, r.current_A, r.power_W, r.mode)
            end

            sleep(1.0)
        end
    catch e
        isa(e, InterruptException) && println("\n[INFO] Stopped by user.")
    finally
        close_dpps!(dev)
        println("[INFO] Saved log to: $csv_path")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
