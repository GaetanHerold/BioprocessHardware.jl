# ============================================================================
# BENCH LOGGER: Eppendorf BioFlo 120 / 320 Bioreactor (Modbus TCP)
# ============================================================================
# Standalone CLI tool to query and log Process Values (DO, pH, Temp, Agitation,
# Pump Speeds) from the Eppendorf BioFlo controller over Modbus TCP.
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."); io=devnull)

using BioprocessHardware
using Dates
using Printf
using Sockets

function parse_cli_args()
    host = "192.168.1.100"
    port = 502
    interval = 1.0
    output = nothing
    mock = false

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg in ["--host", "-h"] && i < length(ARGS)
            host = ARGS[i+1]; i += 1
        elseif arg in ["--port", "-p"] && i < length(ARGS)
            port = parse(Int, ARGS[i+1]); i += 1
        elseif arg in ["--interval", "-i"] && i < length(ARGS)
            interval = parse(Float64, ARGS[i+1]); i += 1
        elseif arg in ["--csv", "-o"] && i < length(ARGS)
            output = ARGS[i+1]; i += 1
        elseif arg in ["--mock", "-m"]
            mock = true
        end
        i += 1
    end
    return (host=host, port=port, interval=interval, output=output, mock=mock)
end

function main()
    args = parse_cli_args()

    # 1. Resolve CSV Log Path
    log_file = if args.output !== nothing
        args.output
    else
        dir = joinpath(@__DIR__, "..", "..", "experiments", "bioflo_logs")
        mkpath(dir)
        joinpath(dir, "bioflo_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv")
    end

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               EPPENDORF BIOFLO 120 / 320 MODBUS TCP LOGGER               ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Endpoint:      $(args.host):$(args.port)")
    println("  Interval:      $(args.interval) s")
    println("  Logging to:    $log_file")
    println("  Stop:          Press Ctrl+C at any time")
    println("-"^76)
    @printf("%-20s │ %-8s │ %-8s │ %-8s │ %-9s │ %-8s\n", "Timestamp", "pH", "DO (%)", "Temp(°C)", "Agit(rpm)", "Pump1(rpm)")
    println("-"^76)

    # Initialize CSV header
    open(log_file, "w") do io
        println(io, "timestamp,pH,dO_pct,temperature_C,agitation_rpm,pump1_rpm")
    end

    if args.mock
        println("[INFO] Running in MOCK MODE.")
        try
            while true
                ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
                pH = 7.02 + 0.02 * randn()
                dO = 98.5 + 0.5 * randn()
                temp = 37.0 + 0.1 * randn()
                agit = 300.0
                pump = 18.8
                @printf("%-20s │ %8.2f │ %8.1f │ %8.1f │ %9.0f │ %8.1f\n", ts, pH, dO, temp, agit, pump)
                open(log_file, "a") do io
                    @printf(io, "%s,%.3f,%.2f,%.2f,%.1f,%.2f\n", ts, pH, dO, temp, agit, pump)
                end
                sleep(args.interval)
            end
        catch e
            isa(e, InterruptException) && println("\n[INFO] Stopped by user.")
        end
        return
    end

    conn = nothing
    try
        conn = BioFloConn(args.host, args.port)
        while true
            ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
            pvs = bioflo_read_pvs(conn)
            
            @printf("%-20s │ %8.2f │ %8.1f │ %8.1f │ %9.0f │ %8.1f\n",
                    ts, pvs.pH, pvs.dO, pvs.temperature, pvs.agitation, pvs.pump1)

            open(log_file, "a") do io
                @printf(io, "%s,%.3f,%.2f,%.2f,%.1f,%.2f\n",
                        ts, pvs.pH, pvs.dO, pvs.temperature, pvs.agitation, pvs.pump1)
            end

            sleep(args.interval)
        end
    catch e
        if isa(e, InterruptException)
            println("\n[INFO] Logging stopped by user.")
        else
            @error "[ERROR] BioFlo Modbus error: $e"
            println("[TIP] Ensure Ethernet cable is connected and IP is set to $(args.host)")
        end
    finally
        if conn !== nothing
            bioflo_close!(conn)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
