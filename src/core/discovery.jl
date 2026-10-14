# ============================================================================
# DEVICE DISCOVERY BY IDENTIFICATION
# ============================================================================
# Port names change between reboots, USB sockets and operating systems, and
# several instruments share the same USB-UART chip. The only reliable way to
# find an instrument is to ask it who it is. Probes MUST be read-only queries:
# never send an actuator command to a port you have not identified.
# ============================================================================

"""
    list_serial_ports() -> Vector{String}

Names of the serial ports the operating system currently exposes.
"""
list_serial_ports() = String.(LibSerialPort.get_port_list())

"""
    probe_ports(probe; baudrate=115200, ports=list_serial_ports(), exclude=String[],
                open_transport=SerialTransport) -> Vector{Pair{String,DeviceInfo}}

Open each candidate port, call `probe(transport)` and close the port again. `probe` must perform a
**read-only** identification query and return a [`DeviceInfo`](@ref) when the expected instrument
answered, or `nothing` otherwise. Errors raised by a probe (timeouts, garbage) mean "not this
device" and are logged at debug level.

```julia
matches = probe_ports(; baudrate=9600) do t
    try_identify_dpps(t)      # returns DeviceInfo or nothing
end
```
"""
function probe_ports(probe::Function; baudrate::Integer=115200,
                     ports::AbstractVector{<:AbstractString}=list_serial_ports(),
                     exclude::AbstractVector{<:AbstractString}=String[],
                     open_transport::Function=(name, baud) -> SerialTransport(name, baud))
    found = Pair{String, DeviceInfo}[]
    for port in ports
        port in exclude && continue
        t = nothing
        try
            t = open_transport(port, baudrate)
            info = probe(t)
            info === nothing || push!(found, String(port) => info)
        catch e
            e isa InterruptException && rethrow()
            @debug "Probe failed on port" port=port exception=e
        finally
            t === nothing || close!(t)
        end
    end
    return found
end

"""
    find_unique_port(probe; kwargs...) -> Pair{String,DeviceInfo}

Like [`probe_ports`](@ref) but requires exactly one match. Throws an `ErrorException` listing the
matches when zero or several ports answer, so a wrong device is never selected silently.
"""
function find_unique_port(probe::Function; kwargs...)
    found = probe_ports(probe; kwargs...)
    length(found) == 1 && return only(found)
    msg = isempty(found) ? "no port answered the identification probe" :
          "several ports answered the identification probe: " * join(first.(found), ", ") *
          " (select one by port name or serial number)"
    error(msg)
end
