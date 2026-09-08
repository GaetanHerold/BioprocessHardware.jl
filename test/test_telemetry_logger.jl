using Test
using Dates
using SQLite
using DBInterface
using BioprocessHardware

@testset "2. Telemetry Logger Tests" begin
    # TL1: DB file created on init
    tmp_db_path = tempname() * ".sqlite"
    exp_id = "test_exp_hardware"
    (db, log_stmt) = init_telemetry_db(tmp_db_path, exp_id, false)
    @test isfile(tmp_db_path)

    # TL2: Schema has correct columns in logs_full table
    col_names = String[]
    for row in DBInterface.execute(db, "PRAGMA table_info(logs_full)")
        push!(col_names, String(row[:name]))
    end
    @test "timestamp" in col_names
    @test "experiment_id" in col_names
    @test "pH_ferm" in col_names
    @test "pH_extr" in col_names

    # TL3: insert_params_to_db! stores records
    insert_params_to_db!(db, exp_id, Dict("target_pH" => 7.2, "Kp" => 0.5), "initial")
    param_count = 0
    for row in DBInterface.execute(db, "SELECT count(*) as cnt FROM parameters WHERE experiment_id = '$exp_id'")
        param_count = Int(row[:cnt])
    end
    @test param_count == 2

    # TL4: flush_telemetry_to_db! clears buffer
    row1 = (
        "2026-08-25 14:00:01",
        exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
        7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
    )
    row2 = (
        "2026-08-25 14:00:02",
        exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
        7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
    )
    row3 = (
        "2026-08-25 14:00:03",
        exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
        7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
    )
    buffer = [row1, row2, row3]
    flush_telemetry_to_db!(db, log_stmt, buffer)
    @test isempty(buffer)

    # TL5: Telemetry row count matches inserts in logs_full
    log_count = 0
    for r in DBInterface.execute(db, "SELECT count(*) as cnt FROM logs_full")
        log_count = Int(r[:cnt])
    end
    @test log_count == 3

    # TL6: CSV header correct
    tmp_csv = tempname() * ".csv"
    init_csv_file(tmp_csv)
    @test isfile(tmp_csv)
    lines = readlines(tmp_csv)
    @test length(lines) == 1
    @test startswith(lines[1], "timestamp,pH_ferm,pH_extr")

    # TL7: appending to CSV adds rows
    open(tmp_csv, "a") do f
        println(f, "2026-08-25 14:00:01,7.1,7.3,10.0,9.8,12.5,20.0,50.0,37.0,37.0,5.0,0.05,0.0,37.0,5.0,5.0,7.15,7.25,10.0,0.02,1,0.0,50.0,20.0,7.1,0.0")
        println(f, "2026-08-25 14:00:02,7.1,7.3,10.0,9.8,12.5,20.0,50.0,37.0,37.0,5.0,0.05,0.0,37.0,5.0,5.0,7.15,7.25,10.0,0.02,1,0.0,50.0,20.0,7.1,0.0")
    end
    lines_after = readlines(tmp_csv)
    @test length(lines_after) == 3

    # TL8: Concurrent DB writes safety
    row4 = (
        "2026-08-25 14:00:04",
        exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
        7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
    )
    row5 = (
        "2026-08-25 14:00:05",
        exp_id, 7.1, 7.3, 10.0, 9.8, 12.5, 20.0, 50.0, 37.0, 37.0, 5.0, 0.05, 0.0, 37.0, 5.0, 5.0,
        7.15, 7.25, 10.0, 0.02, 1, 0.0, 50.0, 20.0, 7.1, 0.0
    )
    buffer_a = [row4]
    buffer_b = [row5]
    @sync begin
        @async flush_telemetry_to_db!(db, log_stmt, buffer_a)
        @async flush_telemetry_to_db!(db, log_stmt, buffer_b)
    end
    count_after_async = 0
    for r in DBInterface.execute(db, "SELECT count(*) as cnt FROM logs_full")
        count_after_async = Int(r[:cnt])
    end
    @test count_after_async == 5

    # TL9: Clean up all temporary files
    close(db)
    rm(tmp_db_path, force=true)
    rm(tmp_csv, force=true)
    @test !isfile(tmp_db_path)
    @test !isfile(tmp_csv)
end
