# ============================================================================
# BENCH LOGGER: Voltcraft DPPS-16-30 DC Power Supply
# ============================================================================
# Standalone CLI tool to monitor and log Voltage, Current, Power, and CV/CC mode
# from a Voltcraft DPPS-16-30 lab power supply to a CSV file.
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."); io=devnull)

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

    # 1. Resolve Serial Port
    target_port = if args.port !== nothing
        args.port
    else
        detected = detect_dpps_ports()
        if !isempty(detected)
            println("[INFO] Auto-detected candidate DPPS port(s): $(join(detected, ", "))")
            detected[1]
        elseif Sys.iswindows()
            "COM4"
        elseif Sys.isapple()
            "/dev/cu.usbserial-10"
        else
            "/dev/ttyUSB0"
        end
    end

    # 2. Resolve CSV Log Path
    log_file = if args.output !== nothing
        args.output
    else
        dir = joinpath(@__DIR__, "..", "..", "experiments", "power_logs")
        mkpath(dir)
        joinpath(dir, "power_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv")
    end

    # 3. Connect to Device
    dev = try
        if args.mock
            open_dpps(target_port; mock=true)
        else
            open_dpps(target_port; baudrate=9600)
        end
    catch e
        @warn "[WARNING] Failed to open physical port '$target_port': $e"
        println("[INFO] Falling back to MOCK SIMULATION mode.")
        open_dpps(target_port; mock=true)
    end

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               VOLTCRAFT DPPS-16-30 DC POWER SUPPLY LOGGER                ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Connection:    $(dev.is_mock ? "MOCK SIMULATOR" : target_port) (9600 baud)")
    println("  Interval:      $(args.interval) s")
    println("  Logging to:    $log_file")
    println("  Stop:          Press Ctrl+C at any time")
    println("-"^76)
    @printf("%-23s │ %-9s │ %-9s │ %-9s │ %-4s\n", "Timestamp", "Voltage", "Current", "Power", "Mode")
    println("-"^76)

    # Initialize CSV header
    open(log_file, "w") do io
        println(io, "timestamp,voltage_V,current_A,power_W,mode")
    end

    step = 0
    try
        while true
            step += 1
            reading = try
                read_dpps_telemetry(dev)
            catch e_read
                @warn "[DPPS] Communication error at step $step" exception=e_read
                sleep(args.interval)
                continue
            end

            ts_str = Dates.format(reading.timestamp, "yyyy-mm-dd HH:MM:SS.sss")

            # Live terminal display
            @printf("%-23s │ %7.2f V │ %7.2f A │ %7.2f W │ %-4s\n",
                    ts_str, reading.voltage_V, reading.current_A, reading.power_W, reading.mode)

            # Append to CSV
            open(log_file, "a") do io
                @printf(io, "%s,%.3f,%.3f,%.3f,%s\n",
                        ts_str, reading.voltage_V, reading.current_A, reading.power_W, reading.mode)
                flush(io)
            end

            sleep(args.interval)
        end
    catch e_int
        if isa(e_int, InterruptException)
            println("\n[INFO] Logging stopped by user.")
        else
            rethrow(e_int)
        end
    finally
        close_dpps!(dev)
        println("[INFO] Device closed. Final dataset stored at: $log_file")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
