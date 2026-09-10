using Test
using Dates
using SQLite
using DBInterface
using BioprocessHardware

@testset "BioprocessHardware Comprehensive Test Suite" begin
    include("test_config_manager.jl")
    include("test_telemetry_logger.jl")
    include("test_mcu_serial.jl")
    include("test_bioflo_modbus.jl")
    include("test_co2_doser.jl")

    @testset "SOLRESS Serial Driver & Mock MCU" begin
        # Test CRC and framing
        @test solress_crc16("123456789") == 0x29B1
        @test solress_crc16("") == 0xFFFF
        pkt = format_solress_packet("CMD,POS,50.0")
        p = parse_solress_packet(pkt)
        @test p.valid == true
        @test p.type == "CMD"
        @test p.fields[2] == "POS"

        # Test driver lifecycle and mock MCU
        driver = open_solress_driver(mock=true)
        @test driver.is_connected == true
        @test driver.is_mock == true

        # Wait for telemetry
        t0 = time()
        tel = nothing
        while (time() - t0) < 2.0
            tel = read_telemetry(driver)
            if tel !== nothing; break; end
            sleep(0.02)
        end
        @test tel !== nothing
        @test tel.pressure_bar > 0.0

        # Command valve
        @test set_valve_position!(driver, 35.0) == true
        sleep(0.1)
        @test driver.mock_mcu.target_steps == round(Int, 0.35 * 19200)

        # Homing
        @test home_valve!(driver) == true
        @test driver.is_homed == true

        # E-Stop
        @test emergency_stop!(driver) == true
        @test driver.mock_mcu.is_estop == true

        # Health & fault injection
        @test is_healthy(driver) == false # Because of estop
        close_solress_driver!(driver)
        @test driver.is_connected == false
    end
end
