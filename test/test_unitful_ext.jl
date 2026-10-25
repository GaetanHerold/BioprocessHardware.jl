using Test
using Unitful
using BioprocessHardware

@testset "Unitful extension" begin
    r = Reading((v=2.0, t=37.0, p=1.2, ph=7.0); units=(v="V", t="degC", p="bar", ph="pH"))
    q = with_units(r)
    @test q.v == 2.0u"V"
    @test q.t == 37.0u"°C"
    @test q.p == 1.2u"bar"
    @test q.ph == 7.0
    @test_throws ArgumentError with_units(Reading((x=1.0,); units=(x="nonsense_unit",)))
end
