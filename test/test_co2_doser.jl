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

    # ========================================================================
    # F26: CalibratedADC4_20mA & Burden Resistor Saturation Guard Tests
    # ========================================================================
    # CD4: Default parameters
    adc_default = CalibratedADC4_20mA()
    @test adc_default.R_burden == 263.0
    @test adc_default.V_ref == 5.0
    @test adc_default.max_counts == 1024.0

    # CD5: Sub-saturation linear mapping
    # 0 counts clamps to 4.0 mA
    @test counts_to_mA(adc_default, 0.0) == 4.0
    # ~215.35 counts corresponds to 4.0 mA
    @test isapprox(counts_to_mA(adc_default, 215.35), 4.0; atol=0.01)
    # 600 counts corresponds to V_in = (600/1023)*5 = 2.9325V -> 11.15 mA
    expected_mA_600 = ((600.0 / 1023.0) * 5.0 / 263.0) * 1000.0
    @test isapprox(counts_to_mA(adc_default, 600.0), expected_mA_600; atol=1e-4)

    # CD6: Saturation ceiling and warning assertion at >= 1023 counts
    # Saturation current: 5.000 V / 263.0 Ω * 1000 = 19.0114 mA
    expected_sat_mA = (5.0 / 263.0) * 1000.0
    @test isapprox(expected_sat_mA, 19.0114; atol=0.01)
    @test_logs (:warn, r"ADC input saturated! Current exceeds 19.01 mA.") begin
        i_sat = counts_to_mA(adc_default, 1023.0)
        @test isapprox(i_sat, expected_sat_mA; atol=1e-4)
    end
    @test_logs (:warn, r"ADC input saturated! Current exceeds 19.01 mA.") begin
        i_over = counts_to_mA(adc_default, 1024.0)
        @test i_over <= 20.0
    end

    # CD7: Current to CO2 percentage conversion
    @test mA_to_co2(4.0) == 0.0
    @test mA_to_co2(20.0) == 100.0
    @test isapprox(mA_to_co2(12.0), 50.0; atol=1e-5)
    # CO2 at saturation (1023 counts)
    co2_sat = @test_logs (:warn, r"ADC input saturated! Current exceeds 19.01 mA.") counts_to_co2(adc_default, 1023.0)
    @test isapprox(co2_sat, (expected_sat_mA - 4.0) / 16.0 * 100.0; atol=1e-3)
    @test isapprox(co2_sat, 93.82; atol=0.05)

    # ========================================================================
    # F27: Relay PWM Dwell Time Enforcement Tests
    # ========================================================================
    # CD8: Suppression of narrow pulses below minimum dwell (1.0 s)
    # duty = 0.5% on 10.0s window -> raw_on = 0.05s < 1.0s -> suppressed to 0.0s
    on_sup, off_sup = CO2Doser.compute_pwm_times(0.5, 10.0, 1.0, 1.0)
    @test on_sup == 0.0
    @test off_sup == 10.0

    # duty = 5.0% on 10.0s window -> raw_on = 0.5s < 1.0s -> suppressed to 0.0s
    on_sup5, off_sup5 = CO2Doser.compute_pwm_times(5.0, 10.0, 1.0, 1.0)
    @test on_sup5 == 0.0
    @test off_sup5 == 10.0

    # CD9: Clamping to full-on when off-time violates minimum dwell (1.0 s)
    # duty = 95.0% on 10.0s window -> raw_on = 9.5s -> off = 0.5s < 1.0s -> clamped to 10.0s
    on_clamp, off_clamp = CO2Doser.compute_pwm_times(95.0, 10.0, 1.0, 1.0)
    @test on_clamp == 10.0
    @test off_clamp == 0.0

    # CD10: Minimum dwell constraints cannot be bypassed by zero or small arguments
    on_bypass, off_bypass = CO2Doser.compute_pwm_times(0.5, 10.0, 0.0, 0.0)
    @test on_bypass == 0.0
    @test off_bypass == 10.0
    on_bypass95, off_bypass95 = CO2Doser.compute_pwm_times(95.0, 10.0, 0.0, 0.0)
    @test on_bypass95 == 10.0
    @test off_bypass95 == 0.0

    # CD11: execute_guarded_relay_pwm and run_pwm_cycle command issuance
    mock_sleep(t) = nothing # No-op sleep for fast unit test execution

    # Suppressed pulse (< 1.0 s dwell) sends only relay off
    io_sup = IOBuffer()
    on_t1, off_t1 = execute_guarded_relay_pwm(io_sup, 5.0, 10.0, 1.0; sleep_fn=mock_sleep)
    @test on_t1 == 0.0
    @test off_t1 == 10.0
    @test String(take!(io_sup)) == "relay off 0\r\n"

    # Clamped to full-on (< 1.0 s off-dwell) sends only relay on
    io_clamp = IOBuffer()
    on_t2, off_t2 = execute_guarded_relay_pwm(io_clamp, 95.0, 10.0, 1.0; sleep_fn=mock_sleep)
    @test on_t2 == 10.0
    @test off_t2 == 0.0
    @test String(take!(io_clamp)) == "relay on 0\r\n"

    # Valid 50% duty cycle on 10.0 s window sends on then off
    io_valid = IOBuffer()
    on_t3, off_t3 = run_pwm_cycle(io_valid, 50.0, 10.0; sleep_fn=mock_sleep)
    @test on_t3 == 5.0
    @test off_t3 == 5.0
    @test String(take!(io_valid)) == "relay on 0\r\nrelay off 0\r\n"

    # CD12 (Finding B1): Keyword argument dispatch for min_dwell_s in run_pwm_cycle
    io_kw = IOBuffer()
    on_kw, off_kw = run_pwm_cycle(io_kw, 50.0, 10.0; min_dwell_s=2.0, sleep_fn=mock_sleep)
    @test on_kw == 5.0
    @test off_kw == 5.0

    # ========================================================================
    # Finding S1: NAMUR NE43 broken wire detection (< 3.6 mA)
    # ========================================================================
    @test ADC4_20mA.classify_loop_current(0.0) == STATUS_UNDERRANGE
    @test ADC4_20mA.classify_loop_current(2.5) == STATUS_UNDERRANGE
    @test ADC4_20mA.classify_loop_current(4.0) == STATUS_OK
    @test ADC4_20mA.classify_loop_current(12.0) == STATUS_OK
    @test ADC4_20mA.classify_loop_current(20.0) == STATUS_OK
    @test ADC4_20mA.classify_loop_current(22.0) == STATUS_OVERRANGE

    val_broken, status_broken = ADC4_20mA.counts_to_engineering(adc_default, 0.0)
    @test status_broken == STATUS_UNDERRANGE
    @test isnan(val_broken)

    val_good, status_good = ADC4_20mA.counts_to_engineering(adc_default, 600.0)
    @test status_good == STATUS_OK
    @test !isnan(val_good)

    # ========================================================================
    # Finding S2: Numato echo-stripping & ADC channel isolation
    # ========================================================================
    # Echo-only response (e.g. "adc read 0\r\n") must NOT return channel number 0.0
    # Create Numato mock and test
    numato_dev = open_numato("COM3"; mock=true, relay_channel=0, adc_channel=0)
    @test numato_dev.is_mock == true
    @test read_adc(numato_dev) == 215.0

    # Test relay switching
    @test set_relay!(numato_dev, true) == true
    @test numato_dev.mock_relay_state == true
    @test set_relay!(numato_dev, false) == true
    @test numato_dev.mock_relay_state == false

    # Test common driver contract on NumatoDevice
    include("contract.jl")
    test_actuator_contract(
        () -> open_numato("COM_MOCK"; mock=true),
        setpoint=1.0,
        out_of_range=2.0,
        safe_value=0.0,
        label="NumatoDevice"
    )

    # Wear tracker tests (Finding S4)
    tracker = RelayWearTracker(100)
    @test tracker.total_cycles == 0
    record_switch!(tracker)
    @test tracker.total_cycles == 1

    close_numato!(numato_dev)
    @test !isconnected(numato_dev)
end
