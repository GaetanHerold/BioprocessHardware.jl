# ============================================================================
# BENCH LOGGER: ESP32-S3 Microcontroller Telemetry Stream
# ============================================================================
# Standalone CLI tool to monitor and log the multi-field plant telemetry frame
# (pH, current, voltage, temperature, pump speeds) from the ESP32-S3 unit.
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."); io=devnull)

using BioprocessHardware
using Dates
using Printf
using LibSerialPort

function parse_cli_args()
    port = nothing
    output = nothing
    mock = false

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg in ["--port", "-p"] && i < length(ARGS)
            port = ARGS[i+1]; i += 1
        elseif arg in ["--csv", "-o"] && i < length(ARGS)
            output = ARGS[i+1]; i += 1
        elseif arg in ["--mock", "-m"]
            mock = true
        elseif !startswith(arg, "-") && port === nothing
            port = arg
        end
        i += 1
    end
    return (port=port, output=output, mock=mock)
end

function main()
    args = parse_cli_args()

    # 1. Resolve Port
    target_port = if args.port !== nothing
        args.port
    elseif Sys.iswindows()
        ports = detect_windows_com_ports()
        get(ports, "esp32", "COM4")
    elseif Sys.isapple()
        ports = filter(p -> occursin("usb", lowercase(p)), ispath("/dev") ? readdir("/dev", join=true) : String[])
        isempty(ports) ? "/dev/cu.usbserial-0001" : ports[1]
    else
        ports = filter(p -> startswith(basename(p), "ttyACM") || startswith(basename(p), "ttyUSB"), ispath("/dev") ? readdir("/dev", join=true) : String[])
        isempty(ports) ? "/dev/ttyACM0" : ports[1]
    end

    # 2. Resolve CSV Log Path
    log_file = if args.output !== nothing
        args.output
    else
        dir = joinpath(@__DIR__, "..", "..", "experiments", "mcu_logs")
        mkpath(dir)
        joinpath(dir, "mcu_stream_log_$(Dates.format(now(), "yyyymmdd_HHMMSS")).csv")
    end

    println("╔══════════════════════════════════════════════════════════════════════════╗")
    println("║               ESP32-S3 TELEMETRY STREAM LOGGER                           ║")
    println("╚══════════════════════════════════════════════════════════════════════════╝")
    println("  Connection:    $target_port (115200 baud)")
    println("  Logging to:    $log_file")
    println("  Stop:          Press Ctrl+C at any time")
    println("-"^76)
    @printf("%-20s │ %-7s │ %-7s │ %-7s │ %-7s │ %-7s\n", "Timestamp", "pH Ferm", "pH Extr", "Volt (V)", "Curr (A)", "Temp(°C)")
    println("-"^76)

    # Initialize CSV header
    open(log_file, "w") do io
        println(io, "timestamp,pH_ferm,pH_extr,voltage_V,current_A,co2_sp,pump_sp,T_ferm")
    end

    if args.mock
        println("[INFO] Running in MOCK MODE.")
        try
            while true
                ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
                pH_f = 6.80 + 0.05 * randn()
                pH_e = 7.10 + 0.05 * randn()
                v = 12.0 + 0.1 * randn()
                c = 3.5 + 0.05 * randn()
                t = 25.2
                @printf("%-20s │ %7.2f │ %7.2f │ %7.2f │ %7.2f │ %7.1f\n", ts, pH_f, pH_e, v, c, t)
                open(log_file, "a") do io
                    @printf(io, "%s,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.2f\n", ts, pH_f, pH_e, v, c, 50.0, 60.0, t)
                end
                sleep(1.0)
            end
        catch e
            isa(e, InterruptException) && println("\n[INFO] Stopped by user.")
        end
        return
    end

    try
        LibSerialPort.open(target_port, 115200) do sp
            LibSerialPort.set_read_timeout(sp, 500)
            
            # Assert RTS & DTR to kickstart MCU
            try
                LibSerialPort.sp_set_rts(sp.ref, LibSerialPort.SP_RTS_ON)
                LibSerialPort.sp_set_dtr(sp.ref, LibSerialPort.SP_DTR_ON)
            catch
            end

            while true
                line = readline(sp)
                if isempty(strip(line))
                    continue
                end

                reading = parse_mcu_line(line, true)
                if reading !== nothing
                    ts_str = Dates.format(reading.timestamp, "yyyy-mm-dd HH:MM:SS")
                    @printf("%-20s │ %7.2f │ %7.2f │ %7.2f │ %7.2f │ %7.1f\n",
                            ts_str, reading.pH_ferm, reading.pH_extr,
                            reading.ps_voltage, reading.current_measured, reading.T_ferm)

                    open(log_file, "a") do io
                        @printf(io, "%s,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.2f\n",
                                ts_str, reading.pH_ferm, reading.pH_extr,
                                reading.ps_voltage, reading.current_measured,
                                reading.co2_sp_measured, reading.pump_sp_measured, reading.T_ferm)
                    end
                end
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
