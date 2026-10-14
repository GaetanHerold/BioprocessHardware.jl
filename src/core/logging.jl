# ============================================================================
# GENERIC SELF-DESCRIBING CSV LOGGER
# ============================================================================
# Works for any sensor (or actuator readback). Columns come from the Reading, so
# there is no instrument-specific schema. The file starts with a commented
# metadata block: who measured, with what, in which units, with which software.
# Timestamps are UTC ISO-8601 with milliseconds.
# ============================================================================

const LOG_FORMAT_VERSION = 1

_csv_clean(x) = replace(string(x), r"[\r\n]+" => " ")

"""
    write_log_header(io, info::DeviceInfo, units::NamedTuple; metadata=Dict(), started_utc=now(UTC))

Write the commented metadata block of a log file (`# key: value` lines).
Extra `metadata` entries (calibration constants and dates, operator, experiment id, ...)
are written verbatim, one per line, sorted by key.
"""
function write_log_header(io::IO, info::DeviceInfo, units::NamedTuple;
                          metadata::AbstractDict=Dict{String, Any}(),
                          started_utc::DateTime=Dates.now(Dates.UTC))
    println(io, "# bioprocesshardware_log_format: ", LOG_FORMAT_VERSION)
    println(io, "# started_utc: ", Dates.format(started_utc, "yyyy-mm-ddTHH:MM:SS.sss"), "Z")
    println(io, "# package_version: ", string(pkgversion(@__MODULE__)))
    println(io, "# julia_version: ", VERSION)
    println(io, "# host: ", gethostname())
    for f in fieldnames(DeviceInfo)
        v = getfield(info, f)
        isempty(v) || println(io, "# device.", f, ": ", _csv_clean(v))
    end
    isempty(units) || println(io, "# units: ", join(("$k=$(units[k])" for k in keys(units)), "; "))
    for k in sort!(collect(string.(keys(metadata))))
        println(io, "# ", k, ": ", _csv_clean(metadata[k]))
    end
    return nothing
end

"""
    log_device(dev; to, every=1.0, n=nothing, duration_s=nothing, stop=Ref(false),
               metadata=Dict(), max_consecutive_errors=10, on_sample=nothing) -> Int

Read `dev` every `every` seconds (fixed-rate, no drift) and append the readings to the CSV file `to`.
Stops after `n` samples, after `duration_s` seconds, when `stop[]` becomes `true`, or on Ctrl-C.
Returns the number of rows written.

- The header block (see [`write_log_header`](@ref)) is written after the first successful reading.
- A failed read becomes a row with status `STATUS_FAULT` and `NaN` values, so gaps stay visible.
  After `max_consecutive_errors` failures in a row the logger throws the last error.
- `on_sample(reading)` is called for every successful reading (for live displays).
- The file is flushed after every row.
"""
function log_device(dev::AbstractDevice; to::AbstractString, every::Real=1.0,
                    n::Union{Integer, Nothing}=nothing,
                    duration_s::Union{Real, Nothing}=nothing,
                    stop::Ref{Bool}=Ref(false),
                    metadata::AbstractDict=Dict{String, Any}(),
                    max_consecutive_errors::Int=10,
                    on_sample::Union{Function, Nothing}=nothing)
    every > 0 || throw(ArgumentError("`every` must be positive"))
    rows = 0
    errors_in_a_row = 0
    cols = nothing
    last_units = NamedTuple()
    last_info = identify_or_empty(dev)
    t0 = time()
    open(to, "w") do io
        i = 0
        try
            while !stop[]
                n !== nothing && rows >= n && break
                duration_s !== nothing && (time() - t0) >= duration_s && break
                i += 1
                reading = nothing
                try
                    reading = read_measurement(dev)
                    errors_in_a_row = 0
                catch e
                    e isa InterruptException && rethrow()
                    e isa DeviceError || rethrow()
                    errors_in_a_row += 1
                    @warn "Read failed" device=typeof(dev) consecutive=errors_in_a_row exception=e
                    errors_in_a_row >= max_consecutive_errors && throw(e)
                    if cols !== nothing   # columns are only known after the first good reading
                        _write_row(io, Dates.now(Dates.UTC), time_ns(), STATUS_FAULT, cols, nothing)
                        rows += 1
                    end
                end
                if reading !== nothing
                    if cols === nothing
                        cols = collect(keys(reading.value))
                        last_units = reading.units
                        last_info = reading.source
                        write_log_header(io, last_info, last_units; metadata=metadata)
                        println(io, "t_utc,t_mono_s,status,", join(cols, ","))
                    end
                    _write_row(io, reading.t_utc, reading.t_mono_ns, reading.status, cols, reading.value)
                    rows += 1
                    on_sample === nothing || on_sample(reading)
                end
                flush(io)
                # fixed-rate schedule: next deadline is t0 + i*every
                delay = (t0 + i * every) - time()
                delay > 0 && sleep(delay)
            end
        catch e
            e isa InterruptException || rethrow()
            @info "Logging stopped by user" rows=rows
        end
    end
    return rows
end

identify_or_empty(dev::AbstractDevice) = try
    hasmethod(identify, Tuple{typeof(dev)}) ? identify(dev) : DeviceInfo()
catch
    DeviceInfo()
end

function _write_row(io::IO, t_utc::DateTime, t_mono_ns::Integer, status::ReadingStatus,
                    cols::Vector{Symbol}, value)
    print(io, Dates.format(t_utc, "yyyy-mm-ddTHH:MM:SS.sss"), "Z,",
          round(Int64(t_mono_ns) / 1e9; digits=6), ",", status)
    for c in cols
        v = value === nothing ? NaN : value[c]
        print(io, ",", v)
    end
    println(io)
end
