# ============================================================================
# NUMATO USB RELAY & ADC HARDWARE DRIVER
# ============================================================================
# Driver for Numato Lab 1-Channel/Multi-Channel USB Relay & ADC modules.
# Communicates via USB CDC serial port with ASCII command protocol.
# ============================================================================

module Numato

using Dates
using Printf
using LibSerialPort

using ..BioprocessHardware: AbstractActuator, AbstractTransport, SerialTransport, MockTransport
using ..BioprocessHardware: Reading, ReadingStatus, STATUS_OK, STATUS_FAULT, DeviceInfo
using ..BioprocessHardware: Health, HEALTH_OK, HEALTH_FAULT
using ..BioprocessHardware: SetpointResult, DeviceError, DeviceTimeout, DeviceProtocolError, DeviceNotConnected
using ..BioprocessHardware: write_bytes!, read_until, read_line, flush_input!, close!, bytes_ready, read_ready
import ..BioprocessHardware: isconnected, identify, healthcheck, read_measurement, write_setpoint!, safe_state!, close_device!

using ..SlowPWM: RelayWearTracker, record_switch!

export NumatoDevice, open_numato, close_numato!
export read_numato_adc, set_numato_relay, read_adc, set_relay!

"""
    mutable struct NumatoDevice <: AbstractActuator
Represents a Numato Lab USB Relay & ADC controller.
"""
mutable struct NumatoDevice <: AbstractActuator
    port_name::String
    baudrate::Int
    relay_channel::Int
    adc_channel::Int
    transport::Union{AbstractTransport, Nothing}
    is_mock::Bool
    mock_relay_state::Bool
    mock_adc_counts::Float64
    info::DeviceInfo
    wear_tracker::RelayWearTracker
    lock::ReentrantLock

    # Backward compatibility with dev.sp
    sp::Union{SerialPort, Nothing}
end

function NumatoDevice(port_name::String="COM3";
                      baudrate::Int=115200,
                      relay_channel::Int=0,
                      adc_channel::Int=0,
                      mock::Bool=false)
    info = DeviceInfo(vendor="Numato Lab", model="USB Relay & ADC", serial=port_name,
                      firmware="1.0", port=port_name, driver="Numato")
    return NumatoDevice(port_name, baudrate, relay_channel, adc_channel, nothing, mock,
                        false, 215.0, info, RelayWearTracker(100000), ReentrantLock(), nothing)
end

# ----------------------------------------------------------------------------
# Driver Interface Implementations
# ----------------------------------------------------------------------------

isconnected(dev::NumatoDevice) = dev.transport !== nothing && isopen(dev.transport)

identify(dev::NumatoDevice) = dev.info

function healthcheck(dev::NumatoDevice)
    isconnected(dev) || return Health(HEALTH_FAULT, "device not connected")
    try
        # Query ADC or version to verify communication
        v = read_adc(dev, dev.adc_channel)
        isnan(v) && return Health(HEALTH_FAULT, "failed to read ADC channel $(dev.adc_channel)")
        return Health(HEALTH_OK)
    catch e
        return Health(HEALTH_FAULT, sprint(showerror, e))
    end
end

function read_measurement(dev::NumatoDevice)::Reading
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    raw_counts = read_adc(dev, dev.adc_channel)
    status = isnan(raw_counts) ? STATUS_FAULT : STATUS_OK
    val = (relay_on=dev.mock_relay_state ? 1.0 : 0.0, adc_counts=raw_counts)
    units = (relay_on="", adc_counts="counts")
    return Reading(val; units=units, status=status, source=dev.info)
end

function write_setpoint!(dev::NumatoDevice, state::Bool)
    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    ok = set_relay!(dev, state, dev.relay_channel)
    return SetpointResult(ok, state ? 1.0 : 0.0, state ? 1.0 : 0.0, 1, ok ? "applied" : "failed")
end

function write_setpoint!(dev::NumatoDevice, state::Real)
    if state < 0.0 || state > 1.0
        return SetpointResult(false, state, dev.mock_relay_state ? 1.0 : 0.0, 0, "setpoint out of bounds [0.0, 1.0]")
    end
    return write_setpoint!(dev, state > 0.5)
end

function safe_state!(dev::NumatoDevice)
    if isconnected(dev)
        try
            set_relay!(dev, false, dev.relay_channel)
        catch e
            @warn "Failed to set Numato relay to safe off state" exception=e
        end
    end
    dev.mock_relay_state = false
    return nothing
end

function close_device!(dev::NumatoDevice)
    safe_state!(dev)
    if dev.transport !== nothing
        close!(dev.transport)
        dev.transport = nothing
    end
    dev.sp = nothing
    return nothing
end

close_numato!(dev::NumatoDevice) = close_device!(dev)

# ----------------------------------------------------------------------------
# Hardware Protocol & Echo Stripping (Finding S2)
# ----------------------------------------------------------------------------

"""
    read_adc(dev::NumatoDevice, channel::Int=dev.adc_channel)::Float64

Query the specified ADC channel [0..1023 counts]. Robustly strips the command echo
to ensure the echoed channel number is never misinterpreted as an ADC count.
"""
function read_adc(dev::NumatoDevice, channel::Int=dev.adc_channel)::Float64
    if dev.is_mock
        return dev.mock_adc_counts
    end

    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    t = dev.transport

    lock(dev.lock) do
        flush_input!(t)
        cmd = "adc read $channel\r"
        write_bytes!(t, cmd)

        # Read response with timeout
        # Expected format from Numato: "adc read 0\n\r215\n\r>" or "215\n\r"
        try
            # Read until prompt '>' or newline
            response_raw = read_until(t, "\r"; timeout_s=0.5, device=dev.port_name, operation="adc read")
            sleep(0.02)
            tail = read_ready(t, 16)
            response = String(vcat(response_raw, tail))

            for line in split(response, r"[\r\n]+")
                s = strip(line)
                # Skip echoed command or empty lines or prompt characters
                if isempty(s) || startswith(s, "adc") || s == ">"
                    continue
                end
                # Strict check: the entire line must be a valid 1-4 digit integer
                if occursin(r"^\d{1,4}$", s)
                    val = tryparse(Int, s)
                    if val !== nothing && 0 <= val <= 1023
                        return Float64(val)
                    end
                end
            end
        catch e
            @debug "Numato ADC read failed" exception=e
        end
        return NaN
    end
end

"""
    set_relay!(dev::NumatoDevice, state::Bool, channel::Int=dev.relay_channel)::Bool

Switch the specified relay contact ON or OFF. Records wear count for longevity monitoring.
"""
function set_relay!(dev::NumatoDevice, state::Bool, channel::Int=dev.relay_channel)::Bool
    if dev.is_mock
        dev.mock_relay_state = state
        state && record_switch!(dev.wear_tracker)
        return true
    end

    isconnected(dev) || throw(DeviceNotConnected(dev.port_name))
    t = dev.transport

    lock(dev.lock) do
        cmd = state ? "relay on $channel\r" : "relay off $channel\r"
        write_bytes!(t, cmd)
        state && record_switch!(dev.wear_tracker)
        sleep(0.02)
        return true
    end
end

"""
    open_numato(port_name::String="COM3"; baudrate::Int=115200,
                relay_channel::Int=0, adc_channel::Int=0, mock::Bool=false)::NumatoDevice

Open communication with Numato Lab USB Relay & ADC module.
"""
function open_numato(port_name::String="COM3";
                     baudrate::Int=115200,
                     relay_channel::Int=0,
                     adc_channel::Int=0,
                     mock::Bool=false)::NumatoDevice
    dev = NumatoDevice(port_name; baudrate=baudrate, relay_channel=relay_channel,
                       adc_channel=adc_channel, mock=mock)
    if mock
        dev.transport = MockTransport()
        return dev
    end

    sp = SerialTransport(port_name, baudrate)
    dev.transport = sp
    dev.sp = sp.sp
    return dev
end

# ----------------------------------------------------------------------------
# Legacy API Compatibility
# ----------------------------------------------------------------------------

"""
    read_numato_adc(sp::Union{SerialPort, NumatoDevice}, channel::Int=0)::Float64
"""
function read_numato_adc(dev::NumatoDevice, channel::Int=0)::Float64
    return read_adc(dev, channel)
end

function read_numato_adc(sp::SerialPort, channel::Int=0)::Float64
    sp_flush(sp, SP_BUF_BOTH)
    cmd = "adc read $channel\r"
    write(sp, cmd)
    sleep(0.08)
    
    response = String(read(sp))
    for line in split(response, r"[\r\n]+")
        s = strip(line)
        if !isempty(s) && !startswith(s, "adc") && s != ">" && occursin(r"^\d{1,4}$", s)
            val = tryparse(Int, s)
            if val !== nothing && 0 <= val <= 1023
                return Float64(val)
            end
        end
    end
    return NaN
end

"""
    set_numato_relay(sp::Union{SerialPort, NumatoDevice}, state::Bool, channel::Int=0)::Bool
"""
function set_numato_relay(dev::NumatoDevice, state::Bool, channel::Int=0)::Bool
    return set_relay!(dev, state, channel)
end

function set_numato_relay(sp::SerialPort, state::Bool, channel::Int=0)::Bool
    cmd = state ? "relay on $channel\r" : "relay off $channel\r"
    write(sp, cmd)
    sleep(0.02)
    return true
end

end # module Numato
