using Test
using Dates
using SQLite
using DBInterface
using BioprocessHardware

@testset "BioprocessHardware Tests" begin

    @testset "1. Config Manager" begin
        params = Dict{String, Any}("target_pH" => 7.4)
        apply_parameter_defaults!(params)
        @test params["target_pH"] == 7.4
        @test params["controlLim"] == 5.0
        @test params["manual_override_mode"] == false
        @test params["manual_current_A"] == 0.0

        tmp_path = tempname() * ".json"
        save_params_to_json(params, tmp_path)
        loaded = load_control_parameters(tmp_path)
        @test loaded["target_pH"] == 7.4
        @test loaded["controlLim"] == 5.0
        rm(tmp_path, force=true)
    end

    @testset "2. Telemetry Logger" begin
        tmp_db_path = tempname() * ".sqlite"
        exp_id = "test_exp_001"
        (db, log_stmt) = init_telemetry_db(tmp_db_path, exp_id, false)
        @test isfile(tmp_db_path)

        insert_params_to_db!(db, exp_id, Dict("target_pH" => 7.2, "Kp" => 0.5), "initial")
        
        row = (
            Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
            exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
            7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
        )
        buffer = [row]
        flush_telemetry_to_db!(db, log_stmt, buffer)
        @test isempty(buffer)
        
        close(db)
        rm(tmp_db_path, force=true)

        tmp_csv = tempname() * ".csv"
        init_csv_file(tmp_csv)
        @test isfile(tmp_csv)
        lines = readlines(tmp_csv)
        @test length(lines) == 1
        @test startswith(lines[1], "timestamp,pH_ferm,pH_extr")
        rm(tmp_csv, force=true)
    end

    @testset "3. MCU Serial Framing" begin
        @test is_measurement_line("2026-08-25 14:00:00,7.20,7.10,0.1,0.0")
        @test !is_measurement_line("DTM,pH1,pH2")
        @test !is_measurement_line("MENU: choose # and <Enter>")

        line = "2026-08-25 14:00:00,7.15,7.35,0.2,0.0,0.0,0.0,0.0,0.0,25.4,15.0,45.0,20.0,0.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"
        mcu = parse_mcu_line(line, true)
        @test mcu !== nothing
        @test mcu.pH_ferm == 7.15
        @test mcu.pH_extr == 7.35
        @test mcu.ps_voltage == 0.2
        @test mcu.T_ferm == 25.4
        @test mcu.co2_sp_measured == 15.0
        @test mcu.pump_sp_measured == 45.0

        cmd = format_mcu_actuator_command(12.5, 25.0, 60.0)
        @test cmd == "PC,12.5,25.0,60.0\r"
    end

    @testset "4. BioFlo Modbus Endianness" begin
        val = Float32(18.8)
        bytes = float32_to_bytes(val)
        @test length(bytes) == 4
        recovered = bytes_to_float32(bytes)
        @test isapprox(recovered, val, atol=1e-5)
    end
end
