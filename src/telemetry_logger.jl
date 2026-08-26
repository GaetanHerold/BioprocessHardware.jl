# ============================================================================
# TELEMETRY & PERSISTENCE LOGGER
# ============================================================================
# Manages CSV flat-file logging and SQLite database storage for real-time
# telemetry, state estimation, and parameter snapshots.
# ============================================================================

using SQLite
import SQLite: DBInterface
using Dates

const CSV_TELEMETRY_HEADER = "timestamp,pH_ferm,pH_extr,current_sp,current_meas,voltage,co2_sp,pump_sp,T_ferm,T_extr,dco2,Q_recirc,adaptation_F,T_calc,delay_FE,delay_EF,pred_pH_F,pred_pH_E,mpc_horizon_cost,mpc_solve_time_s,mpc_valid,mpc_baseline_ff,mpc_pump_ff,mpc_co2_ff,pH_ferm_raw,pH_ferm_offset"

"""
    init_telemetry_db(db_path::String, experiment_id::String, simulate::Bool)

Initialize SQLite database schema and register current experiment.
Auto-recovers from malformed or corrupted database files from prior hard crashes.
Returns `(db, log_stmt)`.
"""
function init_telemetry_db(db_path::String, experiment_id::String, simulate::Bool)
    db = try
        tmp_db = SQLite.DB(db_path)
        DBInterface.execute(tmp_db, "PRAGMA quick_check;")
        tmp_db
    catch err
        @warn "[DB RECOVERY] SQLite database at $db_path was corrupt or malformed ($err). Backing up and creating fresh database."
        try
            corrupt_backup = db_path * ".corrupt_" * Dates.format(now(), "yyyymmdd_HHMMSS")
            mv(db_path, corrupt_backup, force=true)
            println("[INFO] Moved malformed database to: $corrupt_backup")
        catch e_mv
            @warn "Failed to move corrupted database" exception=e_mv
        end
        SQLite.DB(db_path)
    end

    # Schema: Experiments table
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS experiments (
            experiment_id TEXT PRIMARY KEY,
            start_time    DATETIME,
            source_type   TEXT
        );
        """
    )

    # Schema: Parameters table
    DBInterface.execute(
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

    # Schema: Wide telemetry table
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS logs_full (
            timestamp          DATETIME,
            experiment_id      TEXT,
            pH_ferm            REAL,
            pH_extr            REAL,
            current_sp         REAL,
            current_meas       REAL,
            voltage            REAL,
            co2_sp             REAL,
            pump_sp            REAL,
            T_ferm             REAL,
            T_extr             REAL,
            dco2               REAL,
            Q_recirc           REAL,
            adaptation_F       REAL,
            T_calc             REAL,
            delay_FE           REAL,
            delay_EF           REAL,
            pred_pH_F          REAL,
            pred_pH_E          REAL,
            mpc_horizon_cost   REAL,
            mpc_solve_time_s   REAL,
            mpc_valid          INTEGER,
            mpc_baseline_ff    REAL,
            mpc_pump_ff        REAL,
            mpc_co2_ff         REAL,
            pH_ferm_raw        REAL,
            pH_ferm_offset     REAL,
            PRIMARY KEY (experiment_id, timestamp),
            FOREIGN KEY(experiment_id) REFERENCES experiments(experiment_id)
        );
        """
    )

    # Schema auto-migration: Ensure newer columns exist in logs_full if the table pre-dates them
    existing_cols = String[]
    for row in DBInterface.execute(db, "PRAGMA table_info(logs_full);")
        push!(existing_cols, string(row.name))
    end
    expected_cols = [
        ("mpc_horizon_cost", "REAL DEFAULT 0.0"),
        ("mpc_solve_time_s", "REAL DEFAULT 0.0"),
        ("mpc_valid", "INTEGER DEFAULT 0"),
        ("mpc_baseline_ff", "REAL DEFAULT 0.0"),
        ("mpc_pump_ff", "REAL DEFAULT 0.0"),
        ("mpc_co2_ff", "REAL DEFAULT 0.0"),
        ("pH_ferm_raw", "REAL DEFAULT 0.0"),
        ("pH_ferm_offset", "REAL DEFAULT 0.0")
    ]
    for (col_name, col_type) in expected_cols
        if !(col_name in existing_cols)
            try
                DBInterface.execute(db, "ALTER TABLE logs_full ADD COLUMN $col_name $col_type;")
            catch err
                @warn "[DB MIGRATION] Failed adding column $col_name to logs_full: $err"
            end
        end
    end

    # Register experiment run
    DBInterface.execute(
        db,
        "INSERT OR IGNORE INTO experiments (experiment_id, start_time, source_type) VALUES (?, ?, ?)",
        (experiment_id, Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), simulate ? "simulated" : "real")
    )

    # Prepared statement for high-throughput batch inserts
    log_stmt = DBInterface.prepare(
        db,
        """
        INSERT OR REPLACE INTO logs_full
            (timestamp, experiment_id, pH_ferm, pH_extr, current_sp, current_meas, 
             voltage, co2_sp, pump_sp, T_ferm, T_extr, dco2, Q_recirc, adaptation_F, T_calc, delay_FE, delay_EF,
             pred_pH_F, pred_pH_E, mpc_horizon_cost, mpc_solve_time_s, mpc_valid, mpc_baseline_ff, mpc_pump_ff, mpc_co2_ff,
             pH_ferm_raw, pH_ferm_offset)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    )

    return (db, log_stmt)
end

"""
    insert_params_to_db!(db, experiment_id::String, p, reset_type="initial")

Record key-value parameters snapshot with timestamp and context label.
"""
function insert_params_to_db!(db, experiment_id::String, p, reset_type="initial")
    ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    try
        DBInterface.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
        for (k, v) in p
            DBInterface.execute(
                db,
                "INSERT INTO parameters (experiment_id, param_name, param_value, set_at, reset_type) VALUES (?, ?, ?, ?, ?)",
                (experiment_id, String(k), string(v), ts, reset_type)
            )
        end
        DBInterface.execute(db, "COMMIT;")
    catch err
        try
            DBInterface.execute(db, "ROLLBACK;")
        catch
        end
        @warn "Failed to write parameters to database" exception=err
    end
end

"""
    flush_telemetry_to_db!(db, log_stmt, log_buffer::AbstractVector)

Atomically flush telemetry buffer to SQLite database in a single transaction.
Clears `log_buffer` upon successful commit.
"""
function flush_telemetry_to_db!(db, log_stmt, log_buffer::AbstractVector)
    if isempty(log_buffer)
        return
    end

    try
        DBInterface.execute(db, "BEGIN IMMEDIATE TRANSACTION;")
        for row in log_buffer
            DBInterface.execute(log_stmt, row)
        end
        DBInterface.execute(db, "COMMIT;")
        empty!(log_buffer)
    catch err
        try
            DBInterface.execute(db, "ROLLBACK;")
        catch
        end
        @warn "Failed to commit telemetry batch to SQLite" exception=err
    end
end

"""
    init_csv_file(file_path::String)

Create CSV file and write standardized header row.
"""
function init_csv_file(file_path::String)
    open(file_path, "w") do f
        println(f, CSV_TELEMETRY_HEADER)
    end
end
