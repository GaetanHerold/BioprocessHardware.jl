using Test
using BioprocessHardware

@testset "4. BioFlo Modbus Endianness Tests" begin
    # MB1: Float32 byte round-trip (positive value)
    val_pos = Float32(18.8)
    bytes_pos = float32_to_bytes(val_pos)
    rec_pos = bytes_to_float32(bytes_pos)
    @test isapprox(rec_pos, val_pos; atol=1e-5)

    # MB2: Float32 byte round-trip (zero value)
    val_zero = Float32(0.0)
    bytes_zero = float32_to_bytes(val_zero)
    rec_zero = bytes_to_float32(bytes_zero)
    @test rec_zero == 0.0f0

    # MB3: Float32 byte round-trip (negative value)
    val_neg = Float32(-5.5)
    bytes_neg = float32_to_bytes(val_neg)
    rec_neg = bytes_to_float32(bytes_neg)
    @test isapprox(rec_neg, val_neg; atol=1e-5)

    # MB4: Byte array length is exactly 4 bytes
    @test length(bytes_pos) == 4
    @test length(bytes_zero) == 4
    @test length(bytes_neg) == 4

    # MB5: IEEE 754 NaN preserved (using isnan assertion, not direct equality)
    bytes_nan = float32_to_bytes(NaN32)
    rec_nan = bytes_to_float32(bytes_nan)
    @test isnan(rec_nan)

    # MB6: IEEE 754 Inf preserved
    bytes_inf = float32_to_bytes(Inf32)
    rec_inf = bytes_to_float32(bytes_inf)
    @test isinf(rec_inf)
    @test rec_inf > 0.0f0

    # ========================================================================
    # F28: Modbus TCP Packet Fragmentation & Buffer Truncation Tests
    # ========================================================================
    # MB7: Complete read from IOBuffer
    io_full = IOBuffer(UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
    res_full = read_with_timeout(io_full, 9, 1.0)
    @test length(res_full) == 9
    @test res_full == UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]

    # MB8: Fragmented TCP stream accumulation
    # Simulates TCP packet fragmentation: 9-byte frame arrives in 3 chunks of 3 bytes
    stream_frag = Base.BufferStream()
    @async begin
        sleep(0.01)
        write(stream_frag, UInt8[0xAA, 0xBB, 0xCC])
        sleep(0.01)
        write(stream_frag, UInt8[0xDD, 0xEE, 0xFF])
        sleep(0.01)
        write(stream_frag, UInt8[0x11, 0x22, 0x33])
    end
    res_frag = read_with_timeout(stream_frag, 9, 2.0)
    @test length(res_frag) == 9
    @test res_frag == UInt8[0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33]

    # MB9: Premature EOF truncation (no undef bytes in buffer)
    # Stream provides only 4 bytes then closes; buffer should truncate to 4 bytes
    io_short = IOBuffer(UInt8[0xCA, 0xFE, 0xBA, 0xBE])
    res_short = read_with_timeout(io_short, 9, 1.0)
    @test length(res_short) == 4
    @test res_short == UInt8[0xCA, 0xFE, 0xBA, 0xBE]

    # MB10: Read timeout on stalled stream
    stream_stalled = Base.BufferStream()
    @test_throws ErrorException read_with_timeout(stream_stalled, 5, 0.05)

    # ========================================================================
    # F29: BioFlo Pump Actuator Scaling & Calibration Tests
    # ========================================================================
    # MB11: Default pump command constant & calibration factor
    @test BIOFLO_PUMP_DEFAULT_RPM == 18.8f0
    @test BIOFLO_PUMP_CALIBRATION_ML_PER_REV == 1.0

    # MB12: Pump rpm to volumetric flow conversion (18.8 rpm -> 18.8 mL/min)
    flow_nominal = pump_rpm_to_flow_ml_min(BIOFLO_PUMP_DEFAULT_RPM)
    @test isapprox(flow_nominal, 18.8; atol=1e-5)

    # MB13: Volumetric flow to pump rpm conversion (18.8 mL/min -> 18.8 rpm)
    rpm_nominal = pump_flow_ml_min_to_rpm(18.8)
    @test isapprox(rpm_nominal, 18.8f0; atol=1e-5)

    # MB14: Arbitrary flow rate scaling
    @test isapprox(pump_rpm_to_flow_ml_min(30.0), 30.0; atol=1e-5)
    @test isapprox(pump_flow_ml_min_to_rpm(30.0), 30.0f0; atol=1e-5)
    @test isapprox(pump_rpm_to_flow_ml_min(20.0; k_pump=0.8), 16.0; atol=1e-5)

    # ========================================================================
    # Finding H8: Documented Register Map Constants
    # ========================================================================
    @test REG_TEMP == 2
    @test REG_PH == 4
    @test REG_DCO2 == 48
    @test REG_PUMP1 == 76
    @test REG_PUMP2 == 78
    @test REG_PUMP3 == 80

    # ========================================================================
    # Finding B3: Modbus Exception Frame Handling (9 bytes total)
    # ========================================================================
    # FC03 exception response: TID=1, Proto=0, Len=3, Unit=1, FC=0x83, Code=0x02
    exc_frame = UInt8[0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, 0x02]
    @test length(exc_frame) == 9
    exc_fc = exc_frame[8]
    exc_code = exc_frame[9]
    @test exc_fc == 0x83
    @test (exc_fc & 0x80) != 0
    @test exc_code == 0x02
    exc_obj = ModbusException(exc_fc, exc_code)
    @test occursin("ILLEGAL_DATA_ADDRESS", sprint(showerror, exc_obj))

    # ========================================================================
    # Actuator Contract on BioFloDevice
    # ========================================================================
    isdefined(Main, :test_actuator_contract) || include("contract.jl")
    test_actuator_contract(
        () -> open_bioflo("127.0.0.1"; mock=true),
        setpoint=20.0,
        out_of_range=150.0,
        safe_value=0.0,
        label="BioFloDevice"
    )
end
