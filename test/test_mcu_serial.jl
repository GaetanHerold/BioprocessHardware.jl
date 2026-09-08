using Test
using BioprocessHardware

@testset "3. MCU Serial Framing Tests" begin
    # MCU1: Valid measurement line detected
    @test is_measurement_line("2026-08-25 14:00:00,7.20,7.10,0.1,0.0")
    @test is_measurement_line("2026-09-01 12:00:00,6.50,6.40,0.0")

    # MCU2: Header line rejected
    @test !is_measurement_line("DTM,pH1,pH2,current,pump")
    @test !is_measurement_line("timestamp,pH_ferm,pH_extr")

    # MCU3: Menu line rejected
    @test !is_measurement_line("MENU: choose # and <Enter>")
    @test !is_measurement_line("INFO: Initializing MCU boot sequence")

    # MCU4: parse_mcu_line extracts correct fields
    line = "2026-08-25 14:00:00,7.15,7.35,0.2,0.0,0.0,0.0,0.0,0.0,25.4,15.0,45.0,20.0,0.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
    mcu = parse_mcu_line(line, true)
    @test mcu !== nothing
    @test mcu.pH_ferm == 7.15
    @test mcu.pH_extr == 7.35
    @test mcu.ps_voltage == 0.2
    @test mcu.T_ferm == 25.4
    @test mcu.co2_sp_measured == 15.0
    @test mcu.pump_sp_measured == 45.0

    # MCU5: Partial line returns nothing safely
    short_line = "2026-08-25 14:00:00,7.15,7.35"
    @test parse_mcu_line(short_line, true) === nothing

    # MCU6: format_mcu_actuator_command format matches MCU protocol
    cmd = format_mcu_actuator_command(12.5, 25.0, 60.0)
    @test cmd == "PC,12.5,25.0,60.0\r"

    # MCU7: Edge case: all zeros line parsed without exception
    zero_line = "2026-08-25 14:00:00" * join([",0.0" for _ in 1:29], "")
    mcu_zero = parse_mcu_line(zero_line, true)
    @test mcu_zero !== nothing
    @test mcu_zero.pH_ferm == 0.0
    @test mcu_zero.pH_extr == 0.0

    # MCU8: Edge case: NaN string in field handled safely
    nan_line = "2026-08-25 14:00:00,NaN,7.35" * join([",0.0" for _ in 1:27], "")
    mcu_nan = parse_mcu_line(nan_line, true)
    @test mcu_nan === nothing || isnan(mcu_nan.pH_ferm)
end
