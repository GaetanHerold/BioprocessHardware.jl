# ============================================================================
# TELEMETRY & PERSISTENCE LOGGER
# ============================================================================
# Manages CSV flat-file logging and SQLite database storage for real-time
# telemetry, state estimation, and parameter snapshots with configurable schemas.
# ============================================================================

using SQLite
import SQLite: DBInterface
using Dates

export DEFAULT_TELEMETRY_COLUMNS, CSV_TELEMETRY_HEADER

const DEFAULT_TELEMETRY_COLUMNS = Pair{String,String}[
    "pH_ferm"          => "REAL",
    "pH_extr"          => "REAL",
    "current_sp"       => "REAL",
    "current_meas"     => "REAL",
    "voltage"          => "REAL",
    "co2_sp"           => "REAL",
    "pump_sp"          => "REAL",
    "T_ferm"           => "REAL",
    "T_extr"           => "REAL",
    "dco2"             => "REAL",
    "Q_recirc"         => "REAL",
    "adaptation_F"     => "REAL",
    "T_calc"           => "REAL",
    "delay_FE"         => "REAL",
    "delay_EF"         => "REAL",
    "pred_pH_F"        => "REAL",
    "pred_pH_E"        => "REAL",
    "mpc_horizon_cost" => "REAL",
    "mpc_solve_time_s" => "REAL",
    "mpc_valid"        => "INTEGER",
    "mpc_baseline_ff"  => "REAL",
    "mpc_pump_ff"      => "REAL",
    "mpc_co2_ff"       => "REAL",
    "pH_ferm_raw"      => "REAL",
    "pH_ferm_offset"   => "REAL",
]

const CSV_TELEMETRY_HEADER = join(["timestamp"; first.(DEFAULT_TELEMETRY_COLUMNS)], ",")

"""
    init_telemetry_db(db_path::String, experiment_id::String, simulate::Bool;
                      columns::AbstractVector{Pair{String,String}} = DEFAULT_TELEMETRY_COLUMNS,
                      table_name::String = "logs_full")

Initialize SQLite database schema and register current experiment.
Supports custom telemetry column definitions via `columns` while defaulting to `DEFAULT_TELEMETRY_COLUMNS`.
Auto-recovers from malformed or corrupted database files from prior hard crashes.
Returns `(db, log_stmt)`.
"""
function init_telemetry_db(
    db_path::String,
    experiment_id::String,
    simulate::Bool;
    columns::AbstractVector{Pair{String,String}} = DEFAULT_TELEMETRY_COLUMNS,
    table_name::String = "logs_full"
)
    tmp_db = nothing
    db = try
        if isfile(db_path) && filesize(db_path) > 0
            # Fast SQLite magic header check ("SQLite format 3\0")
            header_bytes = open(db_path, "r") do io
                read(io, min(16, filesize(db_path)))
            end
            if length(header_bytes) < 16 || String(header_bytes[1:15]) != "SQLite format 3"
                error("File is not a valid SQLite database header")
            end
        end
        tmp_db = SQLite.DB(db_path)
        check_ok = false
        q_check = DBInterface.execute(tmp_db, "PRAGMA quick_check;")
        for row in q_check
            if lowercase( string(row[1]) ) == "ok"
                check_ok = true
            end
        end
        DBInterface.close!(q_check)
        check_ok || error("PRAGMA quick_check failed")
        tmp_db
    catch err
        @warn "[DB RECOVERY] SQLite database at $db_path was corrupt or malformed ($err). Backing up and creating fresh database."
        if tmp_db !== nothing
            try close(tmp_db) catch end
        end
        try
            corrupt_backup = db_path * ".corrupt_" * Dates.format(now(UTC), "yyyymmdd_HHMMSS")
            mv(db_path, corrupt_backup; force = true)
            println("[INFO] Moved malformed database to: $corrupt_backup")
        catch e_mv
            @warn "Failed to move corrupted database" exception = e_mv
        end
        SQLite.DB(db_path)
    end

    try
        q_wal = DBInterface.execute(db, "PRAGMA journal_mode=WAL;")
        DBInterface.close!(q_wal)
        q_sync = DBInterface.execute(db, "PRAGMA synchronous=NORMAL;")
        DBInterface.close!(q_sync)
    catch
    end

    # Schema: Experiments table
    q_exp = DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS experiments (
            experiment_id TEXT PRIMARY KEY,
            start_time    DATETIME,
            source_type   TEXT
        );
        """
    )
    DBInterface.close!(q_exp)

    # Schema: Parameters table
    q_params = DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS parameters (
            experiment_id TEXT,
            param_name    TEXT,
            param_value   TEXT,
            set_at        DATETIME,
            reset_type    TEXT,
            FOREIGN KEY(experiment_id) REFERENCES experiments(experiment_id)
        );
        """
    )
    DBInterface.close!(q_params)

    col_defs = join(["$(col_name) $(col_type)" for (col_name, col_type) in columns], ",\n            ")
    q_logs = DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS $(table_name) (
            timestamp          DATETIME,
            experiment_id      TEXT,
            $(col_defs),
            PRIMARY KEY (experiment_id, timestamp),
            FOREIGN KEY(experiment_id) REFERENCES experiments(experiment_id)
        );
        """
    )
    DBInterface.close!(q_logs)

    # Schema auto-migration: Ensure all requested columns exist if the table pre-dates them
    existing_cols = String[]
    q_cols = DBInterface.execute(db, "PRAGMA table_info($(table_name));")
    for row in q_cols
        push!(existing_cols, string(row.name))
    end
    DBInterface.close!(q_cols)
    for (col_name, col_type) in columns
        if !(col_name in existing_cols)
            default_clause = uppercase(col_type) == "INTEGER" ? "INTEGER DEFAULT 0" : "REAL DEFAULT 0.0"
            try
                q_alter = DBInterface.execute(db, "ALTER TABLE $(table_name) ADD COLUMN $(col_name) $(default_clause);")
                DBInterface.close!(q_alter)
            catch err
                @warn "[DB MIGRATION] Failed adding column $(col_name) to $(table_name): $err"
            end
        end
    end

    # Register experiment run
    q_ins_exp = DBInterface.execute(
        db,
        "INSERT OR IGNORE INTO experiments (experiment_id, start_time, source_type) VALUES (?, ?, ?)",
        (experiment_id, Dates.format(now(UTC), "yyyy-mm-dd HH:MM:SS.sss"), simulate ? "simulated" : "real")
    )
    DBInterface.close!(q_ins_exp)

    col_names_sql = join(["timestamp", "experiment_id", first.(columns)...], ", ")
    placeholders_sql = join(fill("?", length(columns) + 2), ", ")
    log_stmt = DBInterface.prepare(
        db,
        "INSERT OR REPLACE INTO $(table_name) ($(col_names_sql)) VALUES ($(placeholders_sql))"
    )

    return (db, log_stmt)
end

"""
    insert_params_to_db!(db, experiment_id::String, p, reset_type="initial")

Record key-value parameters snapshot with timestamp and context label.
"""
function insert_params_to_db!(db, experiment_id::String, p, reset_type="initial")
    ts = Dates.format(now(UTC), "yyyy-mm-dd HH:MM:SS.sss")
    param_stmt = DBInterface.prepare(
        db,
        "INSERT INTO parameters (experiment_id, param_name, param_value, set_at, reset_type) VALUES (?, ?, ?, ?, ?)"
    )
    try
        q_begin = DBInterface.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
        DBInterface.close!(q_begin)
        for (k, v) in p
            q_ins = DBInterface.execute(param_stmt, (experiment_id, String(k), string(v), ts, reset_type))
            DBInterface.close!(q_ins)
        end
        q_commit = DBInterface.execute(db, "COMMIT;")
        DBInterface.close!(q_commit)
    catch err
        try
            q_roll = DBInterface.execute(db, "ROLLBACK;")
            DBInterface.close!(q_roll)
        catch
        end
        @warn "Failed to write parameters to database" exception=err
    finally
        DBInterface.close!(param_stmt)
    end
end

"""
    flush_telemetry_to_db!(db, log_stmt, log_buffer::AbstractVector; max_buffer_size::Int = 10_000)

Atomically flush telemetry buffer to SQLite database in a single transaction.
Clears `log_buffer` upon successful commit. If commit fails and `length(log_buffer) > max_buffer_size`,
drops oldest entries to prevent unbounded memory growth.
"""
function flush_telemetry_to_db!(db, log_stmt, log_buffer::AbstractVector; max_buffer_size::Int = 10_000)
    if isempty(log_buffer)
        return
    end

    try
        q_begin = DBInterface.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
        DBInterface.close!(q_begin)
        for row in log_buffer
            q_ins = DBInterface.execute(log_stmt, row)
            DBInterface.close!(q_ins)
        end
        q_commit = DBInterface.execute(db, "COMMIT;")
        DBInterface.close!(q_commit)
        empty!(log_buffer)
    catch err
        try
            q_roll = DBInterface.execute(db, "ROLLBACK;")
            DBInterface.close!(q_roll)
        catch
        end
        if length(log_buffer) > max_buffer_size
            excess = length(log_buffer) - max_buffer_size
            deleteat!(log_buffer, 1:excess)
        end
        @warn "Failed to commit telemetry batch to SQLite" exception=err
    end
end

"""
    init_csv_file(file_path::String; header::AbstractString = CSV_TELEMETRY_HEADER)

Create CSV file and write standardized or custom header row.
"""
function init_csv_file(file_path::String; header::AbstractString = CSV_TELEMETRY_HEADER)
    open(file_path, "w") do f
        println(f, header)
    end
end
