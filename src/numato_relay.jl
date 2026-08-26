# ============================================================================
# NUMATO USB RELAY & ADC HARDWARE DRIVER
# ============================================================================
# Low-level ASCII serial commands for Numato Lab USB relay & ADC modules.
# ============================================================================

using LibSerialPort

"""
    read_numato_adc(sp::SerialPort, channel::Int=0)::Float64

Send `adc read <channel>\\r` command and parse the 10-bit integer count [0..1023].
Returns `NaN` on read failure.
"""
function read_numato_adc(sp::SerialPort, channel::Int=0)::Float64
    sp_flush(sp, SP_BUF_BOTH)
    cmd = "adc read $channel\r"
    write(sp, cmd)
    sleep(0.1)
    
    response = String(read(sp))
    candidates = collect(eachmatch(r"\b\d{1,4}\b", response))
    for m in Iterators.reverse(candidates)
        v = try
            parse(Int, m.match)
        catch
            continue
        end
        if 0 <= v <= 1023
            return Float64(v)
        end
    end

    @warn "Failed to parse Numato ADC reading: $(repr(response))"
    return NaN
end

"""
    set_numato_relay(sp::SerialPort, state::Bool, channel::Int=0)::Bool

Send `relay on/off <channel>\\r` to switch physical relay contact.
"""
function set_numato_relay(sp::SerialPort, state::Bool, channel::Int=0)::Bool
    cmd = state ? "relay on $channel\r" : "relay off $channel\r"
    write(sp, cmd)
    sleep(0.05)
    return true
end
