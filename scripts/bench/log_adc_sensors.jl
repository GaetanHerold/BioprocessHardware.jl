# ============================================================================
# BENCH LOGGER: Numato Lab USB 10-Bit ADC & 4-20mA Sensor Reader
# ============================================================================
# Standalone CLI tool to monitor and log analog sensor voltages, 4-20mA current,
# and dissolved gas/sensor values from the Numato USB ADC board.
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."); io=devnull)

using BioprocessHardware
using Dates
using Printf
using LibSerialPort

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

    # 1. Resolve Port
    target_port = if args.port !== nothing
        args.port
    elseif Sys.iswindows()
        ports = detect_windows_com_ports()
        get(ports, "numato", "COM3")
    elseif Sys.isapple()
        ports = filter(p -> occursin("usb", lowercase(p)), ispath("/dev") ? readdir("/dev", join=true) : String[])
        isempty(ports) ? "/dev/cu.usbmodem101" : ports[1]
    else
        ports = filter(p -> startswith(basename(p), "ttyACM") || startswith(basename(p), "ttyUSB"), ispath("/dev") ? readdir("/dev", join=true) : String[])
        isempty(ports) ? "/dev/ttyACM0" : ports[1]
    end

    # 2. Resolve CSV Log Path
    log_file = if args.output !== nothing
        args.output
    else
        dir = joinpath(@__DIR__, "..", "..", "experiments", "sensor_logs")
        mkpath(dir)
        joinpath(dir, "adc_sensors_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv")
    end

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               NUMATO LAB USB ADC & 4-20mA SENSOR LOGGER                 ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Connection:    $target_port (115200 baud)")
    println("  Interval:      $(args.interval) s")
    println("  Logging to:    $log_file")
    println("  Stop:          Press Ctrl+C at any time")
    println("-"^76)
    @printf("%-23s │ %-9s │ %-11s │ %-9s │ %-11s\n", "Timestamp", "ADC 0", "Current 0", "ADC 1", "Current 1")
    println("-"^76)

    # Initialize CSV header
    open(log_file, "w") do io
        println(io, "timestamp,adc0_counts,current0_mA,adc1_counts,current1_mA")
    end

    adc_calc = CalibratedADC4_20mA(263.0, 5.0, 1023.0)

    if args.mock
        println("[INFO] Running in MOCK MODE.")
        try
            while true
                ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")
                c0 = 215 + round(Int, 50 * rand())
                c1 = 215 + round(Int, 50 * rand())
                mA0 = counts_to_mA(adc_calc, c0)
                mA1 = counts_to_mA(adc_calc, c1)
                @printf("%-23s │ %5d cts │ %8.2f mA │ %5d cts │ %8.2f mA\n", ts, c0, mA0, c1, mA1)
                open(log_file, "a") do io
                    @printf(io, "%s,%d,%.3f,%d,%.3f\n", ts, c0, mA0, c1, mA1)
                end
                sleep(args.interval)
            end
        catch e
            isa(e, InterruptException) && println("\n[INFO] Stopped by user.")
        end
        return
    end

    try
        LibSerialPort.open(target_port, 115200) do sp
            LibSerialPort.set_read_timeout(sp, 500)

            while true
                ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss")

                # Flush buffer
                LibSerialPort.sp_flush(sp, LibSerialPort.SP_BUF_BOTH)

                # Query ADC 0
                write(sp, "adc read 0\r")
                sleep(0.05)
                res0 = String(read(sp))

                # Query ADC 1
                write(sp, "adc read 1\r")
                sleep(0.05)
                res1 = String(read(sp))

                m0 = collect(eachmatch(r"(\d+)", res0))
                m1 = collect(eachmatch(r"(\d+)", res1))

                if !isempty(m0) && !isempty(m1)
                    v0 = parse(Int, m0[end].match)
                    v1 = parse(Int, m1[end].match)
                    mA0 = counts_to_mA(adc_calc, v0)
                    mA1 = counts_to_mA(adc_calc, v1)

                    @printf("%-23s │ %5d cts │ %8.2f mA │ %5d cts │ %8.2f mA\n",
                            ts, v0, mA0, v1, mA1)

                    open(log_file, "a") do io
                        @printf(io, "%s,%d,%.3f,%d,%.3f\n", ts, v0, mA0, v1, mA1)
                    end
                else
                    @warn "[ADC] Parsing error (raw: ADC0=$(repr(res0)), ADC1=$(repr(res1)))"
                end

                sleep(args.interval)
            end
        end
    catch e
        if isa(e, InterruptException)
            println("\n[INFO] Logging stopped by user.")
        else
            @error "[ERROR] Serial error: $e"
            println("[TIP] If on Linux, ensure you ran: sudo usermod -aG dialout \$USER")
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
