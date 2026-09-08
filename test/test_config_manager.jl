using Test
using BioprocessHardware

@testset "1. Config Manager Tests" begin
    # CF1: Default values injected
    params = Dict{String, Any}()
    apply_parameter_defaults!(params)
    @test params["target_pH"] == 7.2
    @test params["controlLim"] == 5.0
    @test params["manual_override_mode"] == false
    @test params["manual_current_A"] == 0.0
    @test params["VVM"] == 0.1
    @test params["tau_adapt"] == 600.0

    # CF2: Existing values not overwritten
    params_custom = Dict{String, Any}("target_pH" => 7.4, "VVM" => 0.2)
    apply_parameter_defaults!(params_custom)
    @test params_custom["target_pH"] == 7.4
    @test params_custom["VVM"] == 0.2
    @test params_custom["controlLim"] == 5.0

    # CF3: Round-trip save and load preserves exact values
    tmp_path = tempname() * ".json"
    save_params_to_json(params_custom, tmp_path)
    loaded = load_control_parameters(tmp_path)
    @test loaded["target_pH"] == 7.4
    @test loaded["VVM"] == 0.2
    @test loaded["controlLim"] == 5.0
    rm(tmp_path, force=true)

    # CF4: JSON comments stripped
    tmp_comment_path = tempname() * ".json"
    open(tmp_comment_path, "w") do f
        write(f, """
        {
            // Primary setpoints
            "target_pH": 6.35,
            /* Multi-line comment:
               gas flow configuration */
            "VVM": 0.15
        }
        """)
    end
    loaded_comment = load_control_parameters(tmp_comment_path)
    @test loaded_comment["target_pH"] == 6.35
    @test loaded_comment["VVM"] == 0.15
    rm(tmp_comment_path, force=true)

    # CF5: Missing file raises informative error
    @test_throws ErrorException load_control_parameters("/non/existent/path/params.json")

    # CF6: Malformed JSON raises error
    tmp_bad_path = tempname() * ".json"
    write(tmp_bad_path, "{ target_pH: 6.0, unquoted }")
    @test_throws Exception load_control_parameters(tmp_bad_path)
    rm(tmp_bad_path, force=true)

    # CF7: Float and Bool types preserved in round-trip
    typed_params = Dict{String, Any}(
        "VVM" => 0.25,
        "manual_override_mode" => true,
        "control_interval" => 1.0
    )
    tmp_typed_path = tempname() * ".json"
    save_params_to_json(typed_params, tmp_typed_path)
    loaded_typed = load_control_parameters(tmp_typed_path)
    @test loaded_typed["VVM"] isa Float64 && loaded_typed["VVM"] == 0.25
    @test loaded_typed["manual_override_mode"] isa Bool && loaded_typed["manual_override_mode"] == true
    @test loaded_typed["control_interval"] == 1.0
    rm(tmp_typed_path, force=true)
end
