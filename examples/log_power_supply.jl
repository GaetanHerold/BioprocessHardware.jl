# ============================================================================
# STANDALONE BENCH LOGGER: Voltcraft DPPS-16-30 Power Supply
# ============================================================================
# Connects to the Voltcraft DPPS-16-30 DC power supply, continuously reads
# voltage, current, power, and CV/CC mode, and records live data to CSV.
#
# Usage:
#   julia --project=. examples/log_power_supply.jl
#   julia --project=. examples/log_power_supply.jl --port /dev/ttyUSB0
#   julia --project=. examples/log_power_supply.jl --port COM4 --interval 2.0
#   julia --project=. examples/log_power_supply.jl --mock
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)

using BioprocessHardware
using Dates
using Printf

function parse_cli_args()
    port = nothing
    interval = 1.0
    output = nothing
    mock = false

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg in ["--port", "-p"] && i < length(ARGS)
            port = ARGS[i+1]; i += 1
        elseif arg in ["--interval", "-i"] && i < length(ARGS)
            interval = parse(Float64, ARGS[i+1]); i += 1
        elseif arg in ["--csv", "-o"] && i < length(ARGS)
            output = ARGS[i+1]; i += 1
        elseif arg in ["--mock", "-m"]
            mock = true
        elseif !startswith(arg, "-") && port === nothing
            port = arg
        end
        i += 1
    end
    return (port=port, interval=interval, output=output, mock=mock)
end

function main()
    args = parse_cli_args()

    target_port = if args.port !== nothing
        args.port
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

    csv_path = if args.output !== nothing
        args.output
    else
        "power_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv"
    end

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               VOLTCRAFT DPPS-16-30 STANDALONE BENCH LOGGER               ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Port:          $target_port ($(args.mock ? "MOCK SIMULATION" : "9600 baud"))")
    println("  Interval:      $(args.interval) s")
    println("  Logging to:    $csv_path")
    println("  Stop:          Press Ctrl+C to finish")
    println("-"^76)
    @printf("%-23s │ %-9s │ %-9s │ %-9s │ %-4s\n", "Timestamp", "Voltage", "Current", "Power", "Mode")
    println("-"^76)

    # Initialize CSV header
    open(csv_path, "w") do io
        println(io, "timestamp,voltage_V,current_A,power_W,mode")
        flush(io)
    end

    dev = try
        if args.mock
            open_dpps(target_port; mock=true)
        else
            open_dpps(target_port; baudrate=9600)
        end
    catch e
        @warn "[WARNING] Port '$target_port' could not be opened: $e"
        println("[INFO] Falling back to MOCK SIMULATION mode for demonstration.")
        open_dpps(target_port; mock=true)
    end

    step = 0
    rows_written = 0
    try
        while true
            step += 1
            reading = try
                read_dpps_telemetry(dev)
            catch e_read
                @warn "[DPPS] Communication warning at step $step: $e_read"
                sleep(args.interval)
                continue
            end

            ts = Dates.format(reading.timestamp, "yyyy-mm-dd HH:MM:SS.sss")

            # Terminal print
            @printf("%-23s │ %7.2f V │ %7.2f A │ %7.2f W │ %-4s\n",
                    ts, reading.voltage_V, reading.current_A, reading.power_W, reading.mode)

            # Append to CSV with flush
            open(csv_path, "a") do io
                @printf(io, "%s,%.3f,%.3f,%.3f,%s\n",
                        ts, reading.voltage_V, reading.current_A, reading.power_W, reading.mode)
                flush(io)
            end
            rows_written += 1

            sleep(args.interval)
        end
    catch e
        if isa(e, InterruptException)
            println("\n[INFO] Logging stopped by user (Ctrl+C).")
        else
            println("\n❌ [ERROR]: Unexpected runtime exception: $e")
            showerror(stderr, e, catch_backtrace())
            println()
        end
    finally
        close_dpps!(dev)
        println("[INFO] Completed. Recorded $rows_written data rows to: $csv_path")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
