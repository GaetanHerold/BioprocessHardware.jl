# ============================================================================
# DRIVER CONTRACT TEST SUITE
# ============================================================================
# Every driver, real (over a MockTransport) or simulated, must pass these checks.
# Usage:
#   test_sensor_contract(() -> MySensor(...))
#   test_actuator_contract(() -> MyActuator(...); setpoint=..., out_of_range=...)
# `make` must return a fresh, connected device each call.
# ============================================================================

using Test
using BioprocessHardware

function test_sensor_contract(make::Function; label::AbstractString="sensor")
    @testset "Sensor contract: $label" begin
        dev = make()
        @test dev isa AbstractSensor
        @test isconnected(dev)
        @test ishealthy(healthcheck(dev))

        info = identify(dev)
        @test info isa DeviceInfo

        r = read_measurement(dev)
        @test r isa Reading
        @test r.t_utc isa Dates.DateTime
        @test r.t_mono_ns isa UInt64
        @test !isempty(keys(r))
        @test all(v -> v isa Real, values(r.value))
        @test all(k -> k in keys(r.value), keys(r.units))     # units only for known fields
        @test isvalid(r) == (r.status == STATUS_OK)
        # values are finite when status is OK
        isvalid(r) && @test all(isfinite, values(r.value))

        # monotonic clock never goes backwards
        r2 = read_measurement(dev)
        @test r2.t_mono_ns >= r.t_mono_ns

        # closing is idempotent and leaves the device disconnected
        close_device!(dev)
        close_device!(dev)
        @test !isconnected(dev)
        @test healthcheck(dev).level == HEALTH_FAULT
        @test_throws DeviceNotConnected read_measurement(dev)
    end
end

function test_actuator_contract(make::Function; setpoint::Real, out_of_range::Real,
                                safe_value::Real, label::AbstractString="actuator")
    @testset "Actuator contract: $label" begin
        dev = make()
        @test dev isa AbstractActuator
        @test isconnected(dev)
        @test ishealthy(healthcheck(dev))
        @test identify(dev) isa DeviceInfo

        res = write_setpoint!(dev, setpoint)
        @test res isa SetpointResult
        @test res.ok
        @test res.attempts >= 1

        # out-of-range setpoints are clamped or rejected, never applied as given
        res2 = write_setpoint!(dev, out_of_range)
        @test res2.applied != out_of_range || !res2.ok

        # safe state is idempotent
        safe_state!(dev)
        safe_state!(dev)
        applied = read_measurement(dev)
        @test first(values(applied.value)) == safe_value

        # closing puts the device into its safe state first
        write_setpoint!(dev, setpoint)
        close_device!(dev)
        @test !isconnected(dev)
        close_device!(dev)                                     # idempotent
        @test_throws DeviceNotConnected write_setpoint!(dev, setpoint)
    end
end
