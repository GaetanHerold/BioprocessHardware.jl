using Test
using BioprocessHardware

@testset "5. CO2 Doser Tests" begin
    # CD1: ControllerConfig and CO2SensorCalibration initialize with valid defaults
    config = CO2Doser.ControllerConfig()
    @test config.target_co2 == 5.0
    @test config.Kp > 0.0
    @test config.pwm_window_s >= 1.0

    cal = CO2Doser.CO2SensorCalibration(200.0, 0.0, 1000.0, 100.0)
    @test isapprox(CO2Doser.adc_to_co2(600.0, cal), 50.0; atol=1e-5)

    # CD2: Setpoint clamping and duty cycle calculation
    # Current CO2 is 2.0%, target is 5.0% -> error is +3.0 -> duty cycle positive
    duty_pos = CO2Doser.compute_duty_cycle(2.0, config)
    @test 0.0 <= duty_pos <= 100.0
    @test duty_pos > 0.0

    # CD3: Setpoint clamping at 0% when current CO2 is higher than target
    duty_zero = CO2Doser.compute_duty_cycle(8.0, config)
    @test duty_zero == 0.0

    # Test PWM timing constraints
    on_s, off_s = CO2Doser.compute_pwm_times(50.0, 10.0, 1.0, 1.0)
    @test isapprox(on_s, 5.0; atol=1e-5)
    @test isapprox(off_s, 5.0; atol=1e-5)
end
