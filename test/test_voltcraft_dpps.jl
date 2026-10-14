using Test
using Dates
using BioprocessHardware

@testset "Voltcraft DPPS-16-30 Hardware Driver Tests" begin
    @testset "1. Frame Parsing & Decoders" begin
        # CV mode reading: 12.00V, 5.00A
        raw_cv = "120005000\rOK\r"
        r1 = parse_dpps_telemetry(raw_cv)
        @test r1.voltage_V == 12.0
        @test r1.current_A == 5.0
        @test r1.power_W ≈ 60.0
        @test r1.mode == "CV"
        @test r1.timestamp <= now()

        # CC mode reading: 5.50V, 15.00A
        raw_cc = "055015001\rOK\r"
        r2 = parse_dpps_telemetry(raw_cc)
        @test r2.voltage_V == 5.5
        @test r2.current_A == 15.0
        @test r2.power_W ≈ 82.5
        @test r2.mode == "CC"

        # Zero output reading
        raw_zero = "000000000\rOK\r"
        r0 = parse_dpps_telemetry(raw_zero)
        @test r0.voltage_V == 0.0
        @test r0.current_A == 0.0
        @test r0.power_W == 0.0
        @test r0.mode == "CV"

        # Edge case: High current (30.00A at 16.00V)
        raw_max = "160030000"
        rmax = parse_dpps_telemetry(raw_max)
        @test rmax.voltage_V == 16.0
        @test rmax.current_A == 30.0
        @test rmax.power_W ≈ 480.0

        # CRLF response variant (\r\n)
        raw_crlf = "120005000\r\nOK\r\n"
        r_crlf = parse_dpps_telemetry(raw_crlf)
        @test r_crlf.voltage_V == 12.0
        @test r_crlf.current_A == 5.0
        @test r_crlf.mode == "CV"

        # Echoed command variant (e.g. "GETD\r120005000\rOK\r")
        raw_echo = "GETD\r120005000\rOK\r"
        r_echo = parse_dpps_telemetry(raw_echo)
        @test r_echo.voltage_V == 12.0
        @test r_echo.current_A == 5.0
        @test r_echo.mode == "CV"

        # Corrupted / short payload raises error
        @test_throws ErrorException parse_dpps_telemetry("1200")
        @test_throws ErrorException parse_dpps_telemetry("")
    end

    @testset "2. Mock Device Operations & Control" begin
        dev = open_dpps("COM4"; mock=true, v_max=16.0, i_max=30.0)
        @test dev.is_mock == true
        @test dev.v_max == 16.0
        @test dev.i_max == 30.0
        @test dev.mock_output_on == false

        # Test GMAX query
        gmax_resp = query_dpps(dev, "GMAX")
        @test gmax_resp == "160300"

        # Test Voltage Setpoint with clamping
        @test set_dpps_voltage!(dev, 12.5) == true
        @test dev.mock_voltage == 12.5

        # Over-voltage clamping (exceeding 16.0V)
        @test set_dpps_voltage!(dev, 25.0) == true
        @test dev.mock_voltage == 16.0

        # Negative voltage clamping
        @test set_dpps_voltage!(dev, -5.0) == true
        @test dev.mock_voltage == 0.0

        # Test Current Setpoint with clamping
        @test set_dpps_current!(dev, 18.2) == true
        @test dev.mock_current == 18.2

        # Over-current clamping (exceeding 30.0A)
        @test set_dpps_current!(dev, 45.0) == true
        @test dev.mock_current == 30.0

        # Test Output Enable / Disable
        @test set_dpps_output!(dev, true) == true
        @test dev.mock_output_on == true
        @test set_dpps_output!(dev, false) == true
        @test dev.mock_output_on == false

        # Test Telemetry Reading from Mock: when output is OFF, measured voltage and current are 0.0
        dev.mock_voltage = 10.0
        dev.mock_current = 2.5
        dev.mock_mode = "CV"
        reading_off = read_dpps_telemetry(dev)
        @test reading_off.voltage_V == 0.0
        @test reading_off.current_A == 0.0
        @test reading_off.power_W == 0.0

        # When output is ON, measured values reflect active supply
        set_dpps_output!(dev, true)
        reading_on = read_dpps_telemetry(dev)
        @test reading_on.voltage_V == 10.0
        @test reading_on.current_A == 2.5
        @test reading_on.power_W ≈ 25.0
        @test reading_on.mode == "CV"

        # Generic driver interface
        m = read_measurement(dev)
        @test m isa Reading
        @test m.voltage == 10.0
        @test m.current == 2.5
        @test m.units.voltage == "V"

        # Test write_setpoint! with voltage
        res = write_setpoint!(dev, 8.5)
        @test res.ok == true
        @test dev.mock_voltage == 8.5

        # Test write_setpoint! with NamedTuple
        res2 = write_setpoint!(dev, (voltage=6.0, current=2.0, output=true))
        @test res2.ok == true
        @test dev.mock_voltage == 6.0
        @test dev.mock_current == 2.0
        @test dev.mock_output_on == true

        # Test safe_state!
        safe_state!(dev)
        @test dev.mock_output_on == false
        @test dev.mock_voltage == 0.0

        # Close Mock
        close_dpps!(dev)
        @test dev.sp === nothing
        @test !isconnected(dev)
    end

    @testset "3. Port Enumeration" begin
        ports = detect_dpps_ports()
        @test isa(ports, Vector{String})
    end

    @testset "4. Common Actuator Contract" begin
        include("contract.jl")
        test_actuator_contract(
            () -> begin
                d = open_dpps("COM_TEST"; mock=true, v_max=16.0, i_max=30.0)
                set_dpps_output!(d, true)
                return d
            end;
            setpoint=12.0,
            out_of_range=50.0,
            safe_value=0.0,
            label="VoltcraftDPPS"
        )
    end
end
