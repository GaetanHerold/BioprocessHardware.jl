using Test
using Dates
using BioprocessHardware

@testset "6. SOLRESS Serial Driver & Mock MCU Tests" begin
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
    # H4: Homing status comes from telemetry or mock
    sleep(0.05)
    @test driver.mock_mcu.is_homed == true

    # E-Stop
    @test emergency_stop!(driver) == true
    @test driver.mock_mcu.is_estop == true

    # Health & fault injection
    @test is_healthy(driver) == false # Because of estop
    close_solress_driver!(driver)
    @test driver.is_connected == false

    # ------------------------------------------------------------------------
    # Finding H1: Handshake identification
    # ------------------------------------------------------------------------
    mock_hw = MockSolressMCU()
    start_mock_mcu!(mock_hw)
    channel_put_drop_oldest!(mock_hw.rx_channel, format_solress_packet("CMD,ID"))
    sleep(0.05)
    @test isready(mock_hw.tx_channel)
    resp = take!(mock_hw.tx_channel)
    p_id = parse_solress_packet(resp)
    @test p_id.valid == true
    @test p_id.type == "ACK"
    @test p_id.fields[2] == "ID"
    @test p_id.fields[3] == "SOLRESS_MCU"
    stop_mock_mcu!(mock_hw)

    # ------------------------------------------------------------------------
    # Finding H3 & H6: Sequence-numbered commands and mock ACK routing
    # ------------------------------------------------------------------------
    d2 = open_solress_driver(mock=true)
    # Send command and verify ACK matches through mock rx/tx channel
    res = Solress.send_driver_command!(d2, "CMD,POS,42.0")
    @test res == "OK"
    @test d2.cmd_seq_counter[] >= 1
    close_solress_driver!(d2)

    # ------------------------------------------------------------------------
    # Common Actuator Contract Tests
    # ------------------------------------------------------------------------
    isdefined(Main, :test_actuator_contract) || include("contract.jl")
    test_actuator_contract(
        () -> begin
            d = open_solress("COM_SOL_MOCK"; mock=true)
            # Home and initialize so healthcheck passes
            home_valve!(d)
            # Wait for first telemetry
            t0 = time()
            while (time() - t0) < 1.0
                read_telemetry(d) !== nothing && break
                sleep(0.02)
            end
            return d
        end;
        setpoint=50.0,
        out_of_range=150.0,
        safe_value=100.0,
        label="SolressDevice"
    )
end
