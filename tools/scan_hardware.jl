# ============================================================================
# BIOPROCESS HARDWARE DIAGNOSTIC SCANNER & DISCOVERY TOOL
# ============================================================================
# Automatically scans for connected bioprocess instruments, tests serial &
# network connectivity, checks OS-level permissions (e.g. Linux dialout),
# and provides instant copy-paste logging commands.
# ============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)

using Sockets
using Dates
using Printf

# Optional LibSerialPort import if available in active environment
const HAS_LIBSERIALPORT = try
    using LibSerialPort
    true
catch
    false
end

struct ScannedDevice
    name::String
    interface::String
    details::String
    status::String      # "ONLINE", "PERMISSION_ERROR", "NOT_DETECTED", "AVAILABLE"
    recommended_cmd::String
end

function check_linux_permissions()::Tuple{Bool, String}
    if !Sys.islinux()
        return (true, "N/A (Non-Linux system)")
    end
    user = get(ENV, "USER", "")
    try
        groups_raw = read(`groups $user`, String)
        in_dialout = contains(groups_raw, "dialout") || contains(groups_raw, "uucp")
        if in_dialout
            return (true, "OK (User '$user' is in dialout/uucp group)")
        else
            return (false, "WARNING: User '$user' is NOT in dialout group! Run: sudo usermod -aG dialout $user (then re-login)")
        end
    catch
        return (true, "Could not determine groups")
    end
end

function list_serial_ports()::Vector{String}
    ports = String[]
    if Sys.iswindows()
        try
            cmd = `powershell -Command "Get-CimInstance Win32_PnPEntity -Filter \"Name like '%(COM%)'\" | ForEach-Object { \$_.Name }"`
            out = read(cmd, String)
            for line in split(out, '\n')
                m = match(r"\(COM(\d+)\)", line)
                if !isnothing(m)
                    push!(ports, "COM" * m.captures[1])
                end
            end
        catch
        end
    elseif Sys.isapple()
        if ispath("/dev")
            for f in readdir("/dev")
                if startswith(f, "cu.usb") || startswith(f, "cu.SLAB")
                    push!(ports, "/dev/" * f)
                end
            end
        end
    else # Linux
        if ispath("/dev")
            for f in readdir("/dev")
                if startswith(f, "ttyUSB") || startswith(f, "ttyACM")
                    push!(ports, "/dev/" * f)
                end
            end
        end
    end
    return unique(ports)
end

function test_bioflo_modbus(ip::String="192.168.1.100", port::Int=502; timeout_s::Float64=0.5)::Bool
    t = @async try
        s = connect(ip, port)
        close(s)
        return true
    catch
        return false
    end
    t0 = time()
    while !istaskdone(t) && (time() - t0) < timeout_s
        sleep(0.02)
    end
    return istaskdone(t) ? fetch(t) : false
end

function scan_all_hardware(; bioflo_ip::String="192.168.1.100")::Vector{ScannedDevice}
    results = ScannedDevice[]
    available_ports = list_serial_ports()

    # 1. Check Voltcraft DPPS Power Supply
    dpps_found = false
    for p in available_ports
        # If we have LibSerialPort, attempt handshake
        if HAS_LIBSERIALPORT
            try
                LibSerialPort.open(p, 9600) do sp
                    LibSerialPort.set_read_timeout(sp, 300)
                    LibSerialPort.sp_flush(sp, LibSerialPort.SP_BUF_BOTH)
                    write(sp, "GETD\r")
                    sleep(0.08)
                    res = String(read(sp))
                    if contains(res, "OK") || length(strip(res)) >= 9
                        push!(results, ScannedDevice(
                            "Voltcraft DPPS-16-30 (Power Supply)",
                            p,
                            "9600 baud, 8-N-1 (Responded to GETD)",
                            "ONLINE",
                            "julia scripts/bench/log_power_supply.jl --port $p"
                        ))
                        dpps_found = true
                    end
                end
            catch e
                if occursin("Permission denied", string(e))
                    push!(results, ScannedDevice(
                        "Serial Port $p (Possible Instrument)",
                        p,
                        "Permission Denied",
                        "PERMISSION_ERROR",
                        "sudo usermod -aG dialout \$USER"
                    ))
                end
            end
        end
        if dpps_found; break; end
    end

    if !dpps_found
        # List candidate ports if detected
        push!(results, ScannedDevice(
            "Voltcraft DPPS-16-30 (Power Supply)",
            isempty(available_ports) ? "None detected" : join(available_ports, ", "),
            "Default 9600 baud",
            isempty(available_ports) ? "NOT_DETECTED" : "AVAILABLE",
            "julia scripts/bench/log_power_supply.jl"
        ))
    end

    # 2. Check Numato Relay & ADC
    numato_found = false
    for p in available_ports
        if HAS_LIBSERIALPORT
            try
                LibSerialPort.open(p, 115200) do sp
                    LibSerialPort.set_read_timeout(sp, 300)
                    LibSerialPort.sp_flush(sp, LibSerialPort.SP_BUF_BOTH)
                    write(sp, "ver\r")
                    sleep(0.08)
                    res = String(read(sp))
                    if contains(lowercase(res), "numato") || contains(res, "0000000")
                        push!(results, ScannedDevice(
                            "Numato Lab USB ADC / Relay",
                            p,
                            "115200 baud (Firmware: $(strip(res)))",
                            "ONLINE",
                            "julia scripts/bench/log_adc_sensors.jl --port $p"
                        ))
                        numato_found = true
                    end
                end
            catch
            end
        end
        if numato_found; break; end
    end

    if !numato_found
        push!(results, ScannedDevice(
            "Numato Lab USB ADC / Relay",
            isempty(available_ports) ? "None detected" : join(available_ports, ", "),
            "Default 115200 baud",
            isempty(available_ports) ? "NOT_DETECTED" : "AVAILABLE",
            "julia scripts/bench/log_adc_sensors.jl"
        ))
    end

    # 3. Check ESP32-S3 Microcontroller
    push!(results, ScannedDevice(
        "ESP32-S3 Pilot Plant Microcontroller",
        isempty(available_ports) ? "None detected" : join(available_ports, ", "),
        "115200 baud (30-field ASCII telemetry)",
        isempty(available_ports) ? "NOT_DETECTED" : "AVAILABLE",
        "julia scripts/bench/log_mcu_stream.jl"
    ))

    # 4. Check BioFlo Modbus TCP
    bioflo_online = test_bioflo_modbus(bioflo_ip, 502)
    push!(results, ScannedDevice(
        "Eppendorf BioFlo 120 / 320 Bioreactor",
        "$bioflo_ip:502",
        "Modbus TCP / IEEE 754 Float32",
        bioflo_online ? "ONLINE" : "OFFLINE",
        "julia scripts/bench/log_bioflo.jl --host $bioflo_ip"
    ))

    return results
end

function print_scan_report(results::Vector{ScannedDevice})
    perm_ok, perm_msg = check_linux_permissions()

    println("╔════════════════════════════════════════════════════════════════════════════════════════════════════╗")
    println("║                        BIOPROCESS HARDWARE DIAGNOSTIC & DISCOVERY SCANNER                          ║")
    println("╚════════════════════════════════════════════════════════════════════════════════════════════════════╝")
    println("  OS Platform:       ", Sys.KERNEL, " (", Sys.MACHINE, ")")
    println("  Serial Perms:      ", perm_msg)
    if !perm_ok
        println("  " * "!"^84)
        println("  !  CRITICAL: You will not be able to read serial devices until you add your user to dialout. !")
        println("  !  Run: sudo usermod -aG dialout \$USER  (then restart terminal/re-login).                  !")
        println("  " * "!"^84)
    end
    println("-"^102)
    @printf("%-36s │ %-18s │ %-14s │ %-24s\n", "Instrument Name", "Interface/Port", "Status", "Suggested Command")
    println("-"^102)

    for dev in results
        status_badge = if dev.status == "ONLINE"
            "✓ ONLINE"
        elseif dev.status == "AVAILABLE"
            "• DETECTED"
        elseif dev.status == "PERMISSION_ERROR"
            "✗ PERMISSION"
        else
            "- NOT FOUND"
        end
        @printf("%-36s │ %-18s │ %-14s │ %-24s\n",
                dev.name, dev.interface, status_badge, dev.recommended_cmd)
    end
    println("-"^102)
    println("Tip: To run any logger, copy and run the suggested command shown above.")
    println("     All logs are saved automatically to clean CSV files with live console tables.")
end

function main()
    results = scan_all_hardware()
    print_scan_report(results)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
