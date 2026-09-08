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
end
