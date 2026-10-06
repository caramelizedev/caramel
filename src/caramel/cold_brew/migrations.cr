require "../../sugar_orm/migration"

module Caramel::ColdBrew
  # Framework-owned system tables. Their versions sort before any application
  # migration, and every name starts with `caramel_`, so the SugarORM differ
  # leaves them alone. Partition DDL runs through SECURITY DEFINER functions:
  # the application's runtime role may not create or drop tables, yet its
  # maintenance fiber must.
  #
  # Their SQL is checksummed and must not change. A trailing backslash joins
  # a long line to the next one at parse time, dropping that line's indent.
  MIGRATIONS = [
    SugarORM::Migration.new(20260927000001_i64, "create_caramel_jobs", [
      <<-SQL,
        CREATE TABLE caramel_jobs (
          id bigint GENERATED ALWAYS AS IDENTITY,
          queue text NOT NULL DEFAULT 'default',
          class_name text NOT NULL,
          payload jsonb NOT NULL,
          priority int NOT NULL DEFAULT 0,
          attempts int NOT NULL DEFAULT 0,
          run_at timestamptz NOT NULL DEFAULT now(),
          locked_at timestamptz,
          locked_by text,
          failed_at timestamptz,
          last_error text,
          enqueued_at timestamptz NOT NULL DEFAULT now(),
          finished_at timestamptz,
          PRIMARY KEY (id, enqueued_at)
        ) PARTITION BY RANGE (enqueued_at)
        SQL
      "CREATE TABLE caramel_jobs_default PARTITION OF caramel_jobs DEFAULT",
      <<-SQL,
        CREATE INDEX caramel_jobs_fetch ON caramel_jobs (queue, run_at, priority DESC)
        WHERE locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL
        SQL
      # Creates the UTC daily partitions first_day .. first_day + days. A day
      # whose rows already sit in the default partition is skipped.
      <<-SQL,
        CREATE FUNCTION caramel_jobs_create_partitions(first_day date, days integer) RETURNS integer
        LANGUAGE plpgsql SECURITY DEFINER SET search_path FROM CURRENT SET lock_timeout = '2s' AS $$
        DECLARE
          target_day date;
          partition text;
          created integer := 0;
        BEGIN
          IF days IS NULL OR days < 0 OR days > 366 THEN
            RAISE EXCEPTION 'caramel_jobs_create_partitions: days must be between 0 and 366';
          END IF;
          FOR offset_days IN 0..days LOOP
            target_day := first_day + offset_days;
            partition := 'caramel_jobs_p' || to_char(target_day, 'YYYY_MM_DD');
            CONTINUE WHEN to_regclass(partition) IS NOT NULL;
            BEGIN
              EXECUTE format('CREATE TABLE %I PARTITION OF caramel_jobs \
                  FOR VALUES FROM (%L) TO (%L)',
                partition, target_day::timestamp AT TIME ZONE 'UTC', \
                  (target_day + 1)::timestamp AT TIME ZONE 'UTC');
              created := created + 1;
            EXCEPTION WHEN check_violation THEN
              NULL;
            END;
          END LOOP;
          RETURN created;
        END
        $$
        SQL
      # Drops daily partitions that ended before now() - retention and hold
      # only finished or failed jobs; deletes such rows from the default partition.
      <<-SQL,
        CREATE FUNCTION caramel_jobs_drop_partitions(retention interval) RETURNS integer
        LANGUAGE plpgsql SECURITY DEFINER SET search_path FROM CURRENT SET lock_timeout = '2s' AS $$
        DECLARE
          partition text;
          pending boolean;
          dropped integer := 0;
        BEGIN
          IF retention IS NULL OR retention < interval '1 day' THEN
            RAISE EXCEPTION 'caramel_jobs_drop_partitions: retention must be at least one day';
          END IF;
          FOR partition IN
            SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'caramel_jobs'::regclass \
                AND c.relname ~ '^caramel_jobs_p[0-9]{4}_[0-9]{2}_[0-9]{2}$'
              AND (to_date(substring(c.relname FROM 15), 'YYYY_MM_DD') + 1)::timestamp \
                AT TIME ZONE 'UTC' <= now() - retention
            ORDER BY c.relname
          LOOP
            EXECUTE format('LOCK TABLE %I IN ACCESS EXCLUSIVE MODE', partition);
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I \
                WHERE finished_at IS NULL AND failed_at IS NULL)', partition) INTO pending;
            CONTINUE WHEN pending;
            EXECUTE format('DROP TABLE %I', partition);
            dropped := dropped + 1;
          END LOOP;
          DELETE FROM caramel_jobs_default
          WHERE enqueued_at <= now() - retention \
            AND (finished_at IS NOT NULL OR failed_at IS NOT NULL);
          RETURN dropped;
        END
        $$
        SQL
      "SELECT caramel_jobs_create_partitions((now() AT TIME ZONE 'UTC')::date, 7)",
    ]),
    SugarORM::Migration.new(20260927000002_i64, "create_caramel_cache", [
      <<-SQL,
        CREATE UNLOGGED TABLE caramel_cache (
          key text PRIMARY KEY,
          value text NOT NULL,
          expires_at timestamptz
        )
        SQL
      "CREATE INDEX caramel_cache_expires_at ON caramel_cache (expires_at) " \
      "WHERE expires_at IS NOT NULL",
    ]),
    SugarORM::Migration.new(20260927000003_i64, "create_caramel_schedules", [
      <<-SQL,
        CREATE TABLE caramel_schedules (
          name text PRIMARY KEY,
          last_run_at timestamptz NOT NULL
        )
        SQL
    ]),
    # Crema's job context: the ids of the trace that enqueued the job. Never a message.
    SugarORM::Migration.new(20260927000004_i64, "add_caramel_jobs_context", [
      "ALTER TABLE caramel_jobs ADD COLUMN context jsonb",
    ]),
    # Crema's per-minute aggregates. Every application has the table; only one that
    # requires "caramel/crema/recorder" writes it. It holds counts and latency
    # histograms under route templates and parameterized SQL, never a message or a path.
    SugarORM::Migration.new(20260927000005_i64, "create_caramel_metrics", [<<-SQL]),
      CREATE TABLE caramel_metrics (
        bucket timestamptz NOT NULL,
        kind text NOT NULL,
        key text NOT NULL,
        count bigint NOT NULL,
        errors bigint NOT NULL,
        total_ms double precision NOT NULL,
        max_ms double precision NOT NULL,
        histogram bigint[] NOT NULL,
        PRIMARY KEY (bucket, kind, key)
      )
      SQL
  ]
end
