using Test
using Dates
using BioprocessHardware
using Unitful

include("contract.jl")

@testset "Driver core" begin

    @testset "Exported names are all defined" begin
        undefined = [n for n in names(BioprocessHardware) if n !== :BioprocessHardware && !isdefined(BioprocessHardware, n)]
        @test isempty(undefined)
    end

    @testset "Errors" begin
        @test DeviceTimeout("d", "op", 1.0) isa DeviceError
        @test occursin("did not answer", sprint(showerror, DeviceTimeout("d", "op", 1.5)))
        @test occursin("raw", sprint(showerror, DeviceProtocolError("d", "bad"; raw=UInt8[1, 2])))
        @test occursin("not connected", sprint(showerror, DeviceNotConnected("d")))
        @test occursin("E1", sprint(showerror, DeviceFault("d", "E1", "nope")))
    end

    @testset "Reading" begin
        r = Reading((v=1.5, t=36.9); units=(v="V", t="degC"))
        @test r.v == 1.5 && r[:t] == 36.9
        @test r.status == STATUS_OK && isvalid(r)
        @test keys(r) == (:v, :t)
        @test occursin("1.5 V", sprint(show, r))
        @test_throws ArgumentError Reading((v=1.0,); units=(w="V",))   # unit for unknown field
        f = fault_reading((:v, :t), (v="V", t="degC"))
        @test !isvalid(f) && f.status == STATUS_FAULT && isnan(f.v) && isnan(f.t)
        @test r.t_utc <= Dates.now(Dates.UTC)
    end

    @testset "MockTransport and bounded reads" begin
        t = MockTransport(req -> String(req) == "ID?\r" ? "VENDOR,MODEL,1\r\n" : nothing)
        write_bytes!(t, "ID?\r")
        @test read_line(t; timeout_s=0.5) == "VENDOR,MODEL,1"
        @test t.sent == [Vector{UInt8}(codeunits("ID?\r"))]

        # no answer -> typed timeout, quickly
        write_bytes!(t, "NOPE\r")
        @test_throws DeviceTimeout read_line(t; timeout_s=0.05)

        # bytes after the terminator are kept for the next read
        inject!(t, "A\nB\nC")
        @test read_line(t; timeout_s=0.2) == "A"
        @test read_line(t; timeout_s=0.2) == "B"
        @test_throws DeviceTimeout read_line(t; timeout_s=0.05)    # "C" has no terminator
        inject!(t, "\n")
        @test read_line(t; timeout_s=0.2) == "C"

        # fragmented delivery is reassembled
        @async begin
            sleep(0.03); inject!(t, "FRAG")
            sleep(0.03); inject!(t, "MENT\r\n")
        end
        @test read_line(t; timeout_s=1.0) == "FRAGMENT"

        # runaway line without terminator cannot grow without bound
        inject!(t, repeat("x", 600))
        @test_throws DeviceProtocolError read_until(t, "\n"; timeout_s=0.2, maxlen=256)
        flush_input!(t)
        @test bytes_ready(t) == 0

        # multi-byte terminator
        inject!(t, "OK\r\nrest")
        @test String(read_until(t, "\r\n"; timeout_s=0.2)) == "OK\r\n"

        close!(t)
        @test !isopen(t)
        @test_throws DeviceNotConnected write_bytes!(t, "x")
        @test_throws DeviceNotConnected read_until(t, "\n"; timeout_s=0.05)
    end

    @testset "verified_write" begin
        stored = Ref(0.0)
        ok = verified_write(v -> (stored[] = v), () -> stored[], 5.0; tol=1e-9, delay_s=0.0)
        @test ok.ok && ok.applied == 5.0 && ok.attempts == 1

        # device ignores writes -> not ok, after retries
        bad = verified_write(v -> nothing, () -> 0.0, 5.0; tol=1e-9, retries=2, delay_s=0.0)
        @test !bad.ok && bad.attempts == 3 && occursin("expected", bad.message)

        # transient failure then success
        n = Ref(0)
        flaky = verified_write(v -> (n[] += 1; n[] == 1 && throw(DeviceTimeout("d", "w", 0.1)); stored[] = v),
                               () -> stored[], 7.0; tol=1e-9, delay_s=0.0)
        @test flaky.ok && flaky.attempts == 2

        # unverifiable device
        nv = verified_write(v -> nothing, nothing, 1.0)
        @test nv.ok && nv.applied === nothing

        # non-device errors are not swallowed
        @test_throws ErrorException verified_write(v -> error("bug"), () -> 0.0, 1.0; delay_s=0.0)
    end

    @testset "RateLimiter" begin
        rl = RateLimiter(0.05)
        @test ready!(rl)
        @test !ready!(rl)
        sleep(0.06)
        @test ready!(rl)
    end

    @testset "Mock devices pass the contract" begin
        test_sensor_contract(() -> MockSensor(fields=(:a, :b), units=(a="V", b="degC")); label="MockSensor")
        test_actuator_contract(() -> MockActuator(lo=0.0, hi=100.0); setpoint=40.0, out_of_range=250.0,
                               safe_value=0.0, label="MockActuator")
    end

    @testset "Mock actuator failure modes" begin
        a = MockActuator()
        fail_next!(a)
        r = write_setpoint!(a, 10.0)           # first attempt times out, retry succeeds
        @test r.ok && r.attempts == 2
        drop_writes!(a, true)
        r2 = write_setpoint!(a, 20.0)
        @test !r2.ok                            # stuck device is detected by read-back
        drop_writes!(a, false)
        @test with_device(a) do d
            write_setpoint!(d, 33.0).ok
        end
        @test !isconnected(a) && a.value == 0.0   # closed -> safe state
    end

    @testset "with_device closes on error" begin
        a = MockActuator()
        @test_throws ErrorException with_device(a) do d
            write_setpoint!(d, 50.0)
            error("boom")
        end
        @test !isconnected(a) && a.value == 0.0
    end

    @testset "Mock sensor status" begin
        s = MockSensor()
        set_status!(s, STATUS_UNDERRANGE)
        r = read_measurement(s)
        @test !isvalid(r) && isnan(r.signal)
        fail_next!(s)
        @test_throws DeviceTimeout read_measurement(s)
    end

    @testset "probe_ports finds devices by identification" begin
        responders = Dict(
            "A" => req -> "WRONG\r\n",
            "B" => req -> "DPPS,16-30,SN42\r\n",
            "C" => req -> nothing,                      # silent port
        )
        open_t = (name, baud) -> MockTransport(responders[name])
        probe = t -> begin
            write_bytes!(t, "ID?\r")
            line = read_line(t; timeout_s=0.05)
            startswith(line, "DPPS") ? DeviceInfo(vendor="Voltcraft", model="DPPS-16-30", serial=split(line, ',')[3]) : nothing
        end
        found = probe_ports(probe; ports=["A", "B", "C"], open_transport=open_t)
        @test length(found) == 1 && found[1].first == "B" && found[1].second.serial == "SN42"
        @test find_unique_port(probe; ports=["A", "B", "C"], open_transport=open_t).first == "B"
        @test_throws ErrorException find_unique_port(probe; ports=["A", "C"], open_transport=open_t)   # none
        responders["C"] = responders["B"]
        @test_throws ErrorException find_unique_port(probe; ports=["B", "C"], open_transport=open_t)   # ambiguous
    end

    @testset "log_device: self-describing CSV" begin
        s = MockSensor(fields=(:v, :t), units=(v="V", t="degC"), name="bench1")
        path = tempname() * ".csv"
        rows = log_device(s; to=path, every=0.01, n=5,
                          metadata=Dict("calibration_date" => "2026-10-01", "operator" => "me\nsecond line"))
        @test rows == 5
        lines = readlines(path)
        header = filter(startswith("#"), lines)
        @test any(startswith("# bioprocesshardware_log_format: 1"), header)
        @test any(startswith("# started_utc: "), header)
        @test any(==("# device.serial: bench1"), header)
        @test any(==("# units: v=V; t=degC"), header)
        @test any(==("# calibration_date: 2026-10-01"), header)
        @test any(==("# operator: me second line"), header)   # newline cannot break the header
        data = filter(!startswith("#"), lines)
        @test data[1] == "t_utc,t_mono_s,status,v,t"
        @test length(data) == 6
        f = split(data[2], ',')
        @test endswith(f[1], "Z") && f[3] == "STATUS_OK" && !isnan(parse(Float64, f[4]))
        # timestamps strictly increasing
        ts = [DateTime(chop(split(l, ',')[1]), dateformat"yyyy-mm-ddTHH:MM:SS.sss") for l in data[2:end]]
        @test issorted(ts)
        rm(path)
    end

    @testset "log_device: failures stay visible, persistent failure aborts" begin
        s = MockSensor(fields=(:v,))
        path = tempname() * ".csv"
        calls = Ref(0)
        rows = log_device(s; to=path, every=0.005, n=4,
                          on_sample=_ -> (calls[] += 1; calls[] == 2 && fail_next!(s)))
        data = filter(!startswith("#"), readlines(path))
        @test rows == 4
        @test any(l -> occursin("STATUS_FAULT", l) && occursin("NaN", l), data)   # gap row, not silent loss
        rm(path)

        dead = MockSensor()
        close_device!(dead)   # every read throws DeviceNotConnected
        @test_throws DeviceNotConnected log_device(dead; to=path, every=0.001, max_consecutive_errors=3)
        rm(path; force=true)
    end

    @testset "log_device: stop flag and duration" begin
        s = MockSensor()
        path = tempname() * ".csv"
        stop = Ref(false)
        rows = log_device(s; to=path, every=0.005, stop=stop, on_sample=_ -> (stop[] = true))
        @test rows == 1
        rows = log_device(s; to=path, every=0.005, duration_s=0.05)
        @test 3 <= rows <= 15
        @test_throws ArgumentError log_device(s; to=path, every=0.0)
        rm(path; force=true)
    end

    @testset "Unitful extension" begin
        r = Reading((v=2.0, t=37.0, p=1.2, ph=7.0); units=(v="V", t="degC", p="bar", ph="pH"))
        q = with_units(r)
        @test q.v == 2.0u"V"
        @test q.t == 37.0u"°C"
        @test q.p == 1.2u"bar"
        @test q.ph == 7.0
        @test_throws ArgumentError with_units(Reading((x=1.0,); units=(x="nonsense_unit",)))
    end
end
