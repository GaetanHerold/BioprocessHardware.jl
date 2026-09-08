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
end
