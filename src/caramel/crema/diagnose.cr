require "pg"
require "./table"

module Caramel::Crema
  # `db diagnose`: a health report from PostgreSQL's own statistics. Each section
  # runs on its own, so one the role may not read does not stop the rest.
  module Diagnose
    CONNECTIONS = <<-SQL
      SELECT application_name, COALESCE(state, '') AS state, count(*)::text AS connections
      FROM pg_stat_activity
      WHERE datname = current_database()
      GROUP BY 1, 2
      ORDER BY count(*) DESC
      SQL

    LONG_RUNNING = <<-SQL
      SELECT pid::text AS pid, (now() - query_start)::text AS running_for,
        COALESCE(wait_event_type || ':' || wait_event, '') AS wait, left(query, 200) AS query
      FROM pg_stat_activity
      WHERE datname = current_database() AND state = 'active' AND pid <> pg_backend_pid()
        AND now() - query_start > interval '1 second'
      ORDER BY query_start
      SQL

    BLOCKING = <<-SQL
      SELECT blocked.pid::text AS blocked_pid, left(blocked.query, 120) AS blocked_query,
        blocker.pid::text AS blocking_pid, left(blocker.query, 120) AS blocking_query
      FROM pg_stat_activity blocked
      JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS locks(pid) ON true
      JOIN pg_stat_activity blocker ON blocker.pid = locks.pid
      WHERE blocked.datname = current_database()
      SQL

    CACHE_HIT = <<-SQL
      SELECT 'tables' AS kind, COALESCE(round(sum(heap_blks_hit) * 100.0 /
        NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2), 0)::text || '%' AS hit_ratio
      FROM pg_statio_user_tables
      UNION ALL
      SELECT 'indexes', COALESCE(round(sum(idx_blks_hit) * 100.0 /
        NULLIF(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2), 0)::text || '%'
      FROM pg_statio_user_indexes
      SQL

    SEQ_SCANS = <<-SQL
      SELECT relname AS table, seq_scan::text AS seq_scans, n_live_tup::text AS live_rows
      FROM pg_stat_user_tables
      ORDER BY seq_scan DESC
      LIMIT 10
      SQL

    UNUSED_INDEXES = <<-SQL
      SELECT stats.relname AS table, stats.indexrelname AS index,
        pg_size_pretty(pg_relation_size(stats.indexrelid)) AS size
      FROM pg_stat_user_indexes stats
      JOIN pg_index idx ON idx.indexrelid = stats.indexrelid
      WHERE stats.idx_scan = 0 AND NOT idx.indisunique AND NOT idx.indisprimary
      ORDER BY pg_relation_size(stats.indexrelid) DESC
      LIMIT 10
      SQL

    VACUUM = <<-SQL
      SELECT relname AS table, n_dead_tup::text AS dead_rows,
        COALESCE(COALESCE(last_autovacuum, last_vacuum)::text, '') AS last_vacuum,
        COALESCE(COALESCE(last_autoanalyze, last_analyze)::text, '') AS last_analyze
      FROM pg_stat_user_tables
      ORDER BY n_dead_tup DESC
      LIMIT 10
      SQL

    TABLE_SIZES = <<-SQL
      SELECT relname AS table, pg_size_pretty(pg_total_relation_size(relid)) AS total_size
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(relid) DESC
      LIMIT 10
      SQL

    STATEMENTS_SCHEMA = <<-SQL
      SELECT extnamespace::regnamespace::text AS schema
      FROM pg_extension
      WHERE extname = 'pg_stat_statements'
      SQL

    NOT_INSTALLED = <<-TEXT
      outliers: pg_stat_statements is not installed in this database.
        Enable it: shared_preload_libraries = 'pg_stat_statements' in postgresql.conf,
        restart PostgreSQL, then CREATE EXTENSION pg_stat_statements;
      TEXT

    SECTIONS = [
      {"connections", CONNECTIONS}, {"long_running", LONG_RUNNING}, {"blocking", BLOCKING},
      {"cache_hit", CACHE_HIT}, {"seq_scans", SEQ_SCANS}, {"unused_indexes", UNUSED_INDEXES},
      {"vacuum", VACUUM}, {"table_sizes", TABLE_SIZES},
    ]

    # One section of the report: its text, and whether it could be read.
    record Section, name : String, text : String, ok : Bool = true

    # The report as sections: each name with its table, or the reason it is missing.
    def self.sections(db : DB::Database? = nil) : Array(Section)
      found = SECTIONS.map do |name, sql|
        attempt(name) { Table.query(sql, db: db).to_text }
      end
      found << outliers(db)
    end

    # Prints every readable section under `== name ==` and the reason for each
    # other. True when at least one section was readable.
    def self.run(io : IO, db : DB::Database? = nil) : Bool
      found = sections(db)
      found.each do |section|
        io << "== " << section.name << " ==\n" if section.ok
        io << section.text << '\n'
      end
      found.any?(&.ok)
    end

    private def self.outliers(db : DB::Database?) : Section
      lookup = attempt("outliers") { statements_schema(db) }
      return lookup unless lookup.ok
      return Section.new("outliers", NOT_INSTALLED) if lookup.text.empty?

      sql = <<-SQL
        SELECT calls::text AS calls, round(total_exec_time::numeric, 1)::text AS total_ms,
          round(mean_exec_time::numeric, 1)::text AS mean_ms, rows::text AS rows,
          left(query, 200) AS query
        FROM #{lookup.text}.pg_stat_statements
        WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND userid = (SELECT oid FROM pg_roles WHERE rolname = current_user)
        ORDER BY total_exec_time DESC
        LIMIT 10
        SQL
      attempt("outliers") { Table.query(sql, db: db).to_text }
    end

    private def self.statements_schema(db : DB::Database?) : String?
      Table.query(STATEMENTS_SCHEMA, db: db).rows.first?.try(&.first)
    end

    # The block's text, or `name: unavailable (SQLSTATE or class)` when it raises.
    private def self.attempt(name : String, & : -> String?) : Section
      Section.new(name, yield || "")
    rescue error : PQ::PQError
      Section.new(name, "#{name}: unavailable (#{error.field_message(:code)})", false)
    rescue error
      Section.new(name, "#{name}: unavailable (#{error.class})", false)
    end
  end
end
