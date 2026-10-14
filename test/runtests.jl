using Test
using Dates
using SQLite
using DBInterface
using BioprocessHardware

include("contract.jl")

@testset "BioprocessHardware Comprehensive Test Suite" begin
    include("test_core.jl")
    include("test_config_manager.jl")
    include("test_telemetry_logger.jl")
    include("test_mcu_serial.jl")
    include("test_bioflo_modbus.jl")
    include("test_co2_doser.jl")
    include("test_yocto_sensor.jl")
    include("test_voltcraft_dpps.jl")
    include("test_solress.jl")
end
