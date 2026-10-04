require "file_utils"
require "json"
require "random/secure"
require "uri"
require "../caramel/version"
require "./paths"
require "./site"
require "./process"
require "./toolchain"

module Caramel::Latte
  # The one PostgreSQL instance owned by Latte for a given major version.
  # Projects receive databases and non-privileged roles inside this cluster;
  # project removal never removes those databases.
  class Postgres
    MAJOR           = Toolchain::POSTGRES_MAJOR
    MAX_CONNECTIONS = 64
    # The schema of `pg_stat_statements` in the development database (ADR 0029).
    STATISTICS_SCHEMA          = "caramel_stats"
    PRELOADED_LIBRARIES        = "pg_stat_statements,auto_explain"
    RUNTIME_CONNECTION_LIMIT   = 24
    MIGRATION_CONNECTION_LIMIT =  1
    MAX_TEST_WORKERS           =  8 # Corretto workers; each may hold one spec migration connection
    ADMIN_USER                 = "caramel_admin"
    BRANCH_NAME                = /\A[a-z][a-z0-9_]{0,30}\z/
    RELEASE_GUARDS_SQL         = <<-SQL
      DO $$
      DECLARE target text;
      BEGIN
        FOR target IN SELECT datname FROM pg_database WHERE NOT datallowconn \
          AND (starts_with(datname, 'caramel_dev_') \
          OR starts_with(datname, 'caramel_spec_')) LOOP
          EXECUTE format('ALTER DATABASE %I WITH ALLOW_CONNECTIONS true', target);
        END LOOP;
      END
      $$;
      SQL
    DROP_PARTITIONED_SQL = <<-SQL
      DO $$
      DECLARE target text;
      BEGIN
        FOR target IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname = 'public' AND c.relkind = 'p' AND NOT c.relispartition LOOP
          EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', target);
        END LOOP;
      END
      $$;
      SQL
    BRANCH_RULE = "branch name must be lowercase: a letter, " \
                  "then up to 30 letters, digits or underscores"

    class Error < Exception
    end

    class ExistingData < Error
    end

    class WrongMajor < Error
      getter expected : Int32
      getter actual : Int32

      def initialize(@expected : Int32, @actual : Int32)
        message = "Latte's databases are in PostgreSQL #{@actual}, " \
                  "but Caramel #{Caramel::VERSION} uses PostgreSQL #{@expected} " \
                  "and has no upgrade from #{@actual}; the data was preserved. " \
                  "Use the newest Caramel release that uses PostgreSQL #{@actual}."
        super(message)
      end
    end

    class SecretMissing < Error
    end

    class BranchExists < Error
    end

    # A disposable clone of a site's development database, with URLs for the
    # site's development migration and runtime roles.
    struct Branch
      getter name : String
      getter database : String
      getter migration_url : String
      getter runtime_url : String

      def initialize(@name : String,
                     @database : String,
                     @migration_url : String,
                     @runtime_url : String)
      end

      def inspect(io : IO) : Nil
        io << "Caramel::Latte::Postgres::Branch(name="
        @name.inspect(io)
        io << ", database="
        @database.inspect(io)
        io << ", urls=[REDACTED])"
      end

      def to_s(io : IO) : Nil
        inspect(io)
      end
    end

    struct DatabaseNames
      getter development : String
      getter spec : String

      def initialize(@development : String, @spec : String)
      end

      def development_database : String
        @development
      end

      def spec_database : String
        @spec
      end
    end

    struct RoleNames
      getter development_runtime : String
      getter development_migration : String
      getter spec_runtime : String
      getter spec_migration : String

      def initialize(@development_runtime : String,
                     @development_migration : String,
                     @spec_runtime : String,
                     @spec_migration : String)
      end

      def dev_runtime : String
        @development_runtime
      end

      def dev_migration : String
        @development_migration
      end

      def dev_runtime_url : String
        @development_runtime
      end

      def dev_migration_url : String
        @development_migration
      end

      def development_runtime_role : String
        @development_runtime
      end

      def development_migration_role : String
        @development_migration
      end

      def spec_runtime_role : String
        @spec_runtime
      end

      def spec_migration_role : String
        @spec_migration
      end
    end

    struct Credentials
      getter development_runtime : String
      getter development_migration : String
      getter spec_runtime : String
      getter spec_migration : String
      getter development_database : String
      getter spec_database : String
      getter roles : RoleNames
      getter databases : DatabaseNames

      def initialize(
        @development_runtime : String,
        @development_migration : String,
        @spec_runtime : String,
        @spec_migration : String,
        @development_database : String,
        @spec_database : String,
        @roles : RoleNames,
        @databases : DatabaseNames,
      )
      end

      def dev_runtime : String
        @development_runtime
      end

      def dev_migration : String
        @development_migration
      end

      def spec_runtime_url : String
        @spec_runtime
      end

      def development_runtime_url : String
        @development_runtime
      end

      def development_migration_url : String
        @development_migration
      end

      def spec_migration_url : String
        @spec_migration
      end

      def inspect(io : IO) : Nil
        io << "Caramel::Latte::Postgres::Credentials(databases="
        @databases.inspect(io)
        io << ", roles="
        @roles.inspect(io)
        io << ", urls=[REDACTED])"
      end

      def to_s(io : IO) : Nil
        inspect(io)
      end
    end

    private struct Material
      getter site_id : String
      getter databases : DatabaseNames
      getter roles : RoleNames
      getter development_runtime_password : String
      getter development_migration_password : String
      getter spec_runtime_password : String
      getter spec_migration_password : String

      def initialize(
        @site_id : String,
        @databases : DatabaseNames,
        @roles : RoleNames,
        @development_runtime_password : String,
        @development_migration_password : String,
        @spec_runtime_password : String,
        @spec_migration_password : String,
      )
      end

      def inspect(io : IO) : Nil
        io << "Postgres::Material(site_id="
        @site_id.inspect(io)
        io << ", databases="
        @databases.inspect(io)
        io << ", roles="
        @roles.inspect(io)
        io << ", passwords=[REDACTED])"
      end

      def to_s(io : IO) : Nil
        inspect(io)
      end
    end

    private struct AdminMaterial
      getter username : String
      getter password : String

      def initialize(@username : String, @password : String)
      end

      def inspect(io : IO) : Nil
        io << "Postgres::AdminMaterial(username="
        @username.inspect(io)
        io << ", password=[REDACTED])"
      end

      def to_s(io : IO) : Nil
        inspect(io)
      end
    end

    getter paths : Paths
    getter toolchain : Toolchain

    def initialize(@paths : Paths, @toolchain : Toolchain = Toolchain.for_checkout)
      @lock = Mutex.new
      @data_directory = @paths.postgres_data(MAJOR)
      @socket_directory = @paths.postgres_socket_dir
      @admin_record = nil
    end

    def data_directory : String
      @data_directory
    end

    def socket_directory : String
      @socket_directory
    end

    def admin_secret_path : String
      File.join(@paths.secrets_dir, "postgres-admin.json")
    end

    def credentials_path(site : Site) : String
      File.join(@paths.secrets_dir, "site-#{site.id}.json")
    end

    def start : Nil
      @lock.synchronize { start_locked! }
    end

    def stop : Nil
      @lock.synchronize { stop_locked! }
    end

    def restart : Nil
      stop
      start
    end

    def running? : Bool
      return false unless File.exists?(File.join(@data_directory, "postmaster.pid"))
      verified_postmaster_pid?
    rescue ex : OwnershipError
      raise ex
    rescue
      false
    end

    def ready? : Bool
      return false unless running?
      begin
        run_admin_psql("SELECT 1")
        true
      rescue
        false
      end
    end

    def provision(site : Site) : Credentials
      start
      material = load_or_create_material(site)
      @lock.synchronize do
        @toolchain.verify_postgres_version!(Toolchain::POSTGRES_VERSION)
        ensure_roles(material)
        ensure_databases(material)
      end
      credentials_from(material)
    end

    # Returns URLs only after a credential file has already been provisioned.
    # This method never prints or inspects credential contents in diagnostics.
    def credentials(site : Site) : Credentials
      material = load_material(site)
      credentials_from(material)
    end

    def backup(site : Site, destination : String, environment : Symbol = :development) : String
      material = load_material(site)
      database, role, password = selected_connection(material, environment, :migration)
      ensure_backup_destination(destination)
      run_with_password_file(role, password) do |passfile|
        result = ProcessRunner.run(
          [@toolchain.pg_dump, "--format=custom", "--no-owner", "--file", destination,
           "--exclude-schema=#{STATISTICS_SCHEMA}", "--exclude-extension=pg_stat_statements",
           "--dbname", socket_url(role, "", database)],
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 120.seconds,
          output_limit: 16 * 1024,
        )
        unless result.success?
          raise Error.new("managed PostgreSQL backup failed: #{result.diagnostic}")
        end
      end
      File.chmod(destination, 0o600)
      destination
    end

    def restore(site : Site, backup_file : String, environment : Symbol = :development) : Nil
      material = load_material(site)
      database, role, password = selected_connection(material, environment, :migration)
      info = File.info(backup_file, follow_symlinks: false)
      StateSecurity.validate_owned_directory(File.dirname(backup_file))
      if info.symlink? || !info.file? || info.owner_id.to_i64? != StateSecurity.current_uid
        raise ArgumentError.new("backup must be an owned regular file")
      end
      raise ArgumentError.new("backup must be mode 0600") unless info.permissions.value == 0o600
      # pg_restore --clean drops each partition's inherited primary key and
      # indexes one by one, which PostgreSQL refuses; drop partitioned tables
      # whole first (the backup recreates them).
      run_psql(DROP_PARTITIONED_SQL, database, role, password)
      run_with_password_file(role, password) do |passfile|
        result = ProcessRunner.run(
          [@toolchain.pg_restore, "--exit-on-error", "--clean", "--if-exists", "--no-owner",
           "--dbname", socket_url(role, "", database), backup_file],
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 120.seconds,
          output_limit: 16 * 1024,
        )
        unless result.success?
          raise Error.new("managed PostgreSQL restore failed: #{result.diagnostic}")
        end
      end
    end

    # Clones the site's development database into a disposable branch behind
    # the connection guard. The branch belongs to the development
    # migration role and admits exactly the development roles.
    def create_branch(site : Site, name : String) : Branch
      database = self.class.branch_database(site.id, name)
      material = load_material(site)
      migration, runtime = material.roles.development_migration, material.roles.development_runtime
      @lock.synchronize do
        raise BranchExists.new("branch #{name} already exists") if database_exists?(database)
        clone_guarded(material.databases.development, database, migration, runtime)
      end
      Branch.new(
        name,
        database,
        socket_url(migration, material.development_migration_password, database),
        socket_url(runtime, material.development_runtime_password, database),
      )
    end

    def drop_branch(site : Site, name : String) : Bool
      drop_database(self.class.branch_database(site.id, name))
    end

    # Replaces Corretto test worker `index` with a fresh guarded clone of the
    # site's migrated spec database: creating a worker and resetting it after
    # leaked DDL are the same operation. The worker admits only the spec roles.
    def reset_test_worker(site : Site, index : Int32) : Branch
      database = self.class.test_worker_database(site.id, index)
      material = load_material(site)
      migration, runtime = material.roles.spec_migration, material.roles.spec_runtime
      @lock.synchronize do
        run_admin_psql(self.class.branch_drop_sql(database))
        clone_guarded(material.databases.spec, database, migration, runtime)
      end
      Branch.new(
        "w#{index}",
        database,
        socket_url(migration, material.spec_migration_password, database),
        socket_url(runtime, material.spec_runtime_password, database),
      )
    end

    def drop_test_worker(site : Site, index : Int32) : Bool
      drop_database(self.class.test_worker_database(site.id, index))
    end

    def list_branches(site : Site) : Array(String)
      prefix = self.class.branch_database(site.id, "a").rchop("a")
      literal = self.class.quote_literal(prefix)
      sql = "SELECT datname FROM pg_database WHERE starts_with(datname, #{literal}) ORDER BY 1;"
      output = @lock.synchronize { run_admin_psql(sql) }
      output.lines.map(&.strip).reject(&.empty?).map(&.lchop(prefix))
    end

    # Connection guard: while the block runs, `database` refuses new
    # connections and has no other backends. Connections are re-allowed in
    # every outcome, including an expired operation deadline.
    def guard_connections(database : String, &) : Nil
      run_admin_psql(self.class.branch_guard_sql(database))
      yield
    ensure
      OperationDeadline.without { run_admin_psql(self.class.branch_release_sql(database)) }
    end

    # A crash between guard and release would lock developers out of their
    # database; Latte re-allows connections whenever it starts.
    def release_guards : Nil
      @lock.synchronize { run_admin_psql(RELEASE_GUARDS_SQL) }
    end

    def self.database_names(site_id : String) : DatabaseNames
      validate_site_id!(site_id)
      DatabaseNames.new("caramel_dev_#{site_id}", "caramel_spec_#{site_id}")
    end

    def self.role_names(site_id : String) : RoleNames
      validate_site_id!(site_id)
      RoleNames.new(
        "caramel_dev_runtime_#{site_id}",
        "caramel_dev_migration_#{site_id}",
        "caramel_spec_runtime_#{site_id}",
        "caramel_spec_migration_#{site_id}",
      )
    end

    def self.connection_url(user : String,
                            password : String,
                            database : String,
                            socket_directory : String) : String
      host = URI.encode_www_form(socket_directory)
      "postgresql://#{user}:#{password}@/#{database}?host=#{host}&port=5432"
    end

    def self.validate_branch_name!(name : String) : Nil
      raise ArgumentError.new(BRANCH_RULE) unless name.matches?(BRANCH_NAME)
    end

    def self.branch_database(site_id : String, name : String) : String
      validate_site_id!(site_id)
      validate_branch_name!(name)
      "caramel_branch_#{site_id}_#{name}"
    end

    def self.test_worker_database(site_id : String, index : Int32) : String
      unless (1..MAX_TEST_WORKERS).includes?(index)
        raise ArgumentError.new("test worker index must be 1 to #{MAX_TEST_WORKERS}")
      end
      "#{database_names(site_id).spec}_w#{index}"
    end

    def self.branch_guard_sql(database : String) : String
      <<-SQL
        ALTER DATABASE #{quote_identifier(database)} WITH ALLOW_CONNECTIONS false;
        SELECT count(pg_terminate_backend(pid, 5000)) FROM pg_stat_activity \
          WHERE datname = #{quote_literal(database)} AND pid <> pg_backend_pid();
        SQL
    end

    def self.branch_release_sql(database : String) : String
      "ALTER DATABASE #{quote_identifier(database)} WITH ALLOW_CONNECTIONS true;"
    end

    def self.branch_clone_sql(source : String, branch : String, owner : String) : String
      template = quote_identifier(source)
      "CREATE DATABASE #{quote_identifier(branch)} WITH TEMPLATE #{template} " \
      "OWNER #{quote_identifier(owner)} STRATEGY FILE_COPY;"
    end

    # Database-level settings and grants are not copied from a template.
    def self.branch_access_sql(branch : String,
                               migration_role : String,
                               runtime_role : String) : String
      name = quote_identifier(branch)
      roles = "#{quote_identifier(migration_role)}, #{quote_identifier(runtime_role)}"
      <<-SQL
        ALTER DATABASE #{name} SET timezone TO 'UTC';
        REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE #{name} FROM PUBLIC;
        GRANT CONNECT ON DATABASE #{name} TO #{roles};
        SQL
    end

    def self.branch_drop_sql(branch : String) : String
      "DROP DATABASE IF EXISTS #{quote_identifier(branch)} WITH (FORCE);"
    end

    def self.quote_identifier(identifier : String) : String
      %("#{identifier.gsub("\"", "\"\"")}")
    end

    def self.quote_literal(value : String) : String
      "'#{value.gsub("'", "''")}'"
    end

    private def config_literal(value : String) : String
      "'#{value.gsub("\\", "\\\\").gsub("'", "\\'")}'"
    end

    private struct PostmasterIdentity
      getter pid : Int64
      getter data_directory : String
      getter start_time : Int64

      def initialize(@pid : Int64, @data_directory : String, @start_time : Int64)
      end
    end

    @lock : Mutex
    @data_directory : String
    @socket_directory : String
    @admin_record : AdminMaterial?

    # ameba:disable Metrics/CyclomaticComplexity -- recovery for each startup step
    private def start_locked! : Nil
      @toolchain.verify_postgres_version!(Toolchain::POSTGRES_VERSION)
      validate_data_directory!
      if cluster_initialized?
        verify_cluster_major!
        ensure_admin_material!(false)
      else
        refuse_other_major_cluster!
        ensure_admin_material!(true)
        initialize_cluster!
      end

      existing_pid = File.exists?(File.join(@data_directory, "postmaster.pid"))
      previous_identity = postmaster_identity
      if existing_pid && previous_identity.nil?
        raise Error.new("managed PostgreSQL has an unverified postmaster PID; data was preserved")
      end

      ensure_configuration!
      reload_configuration_locked! if previous_identity

      if ready?
        return if managed_configuration_ok?
        stop_locked!
      elsif File.exists?(File.join(@data_directory, "postmaster.pid"))
        raise Error.new("managed PostgreSQL is running but not ready; data was preserved")
      end

      log = File.join(@paths.logs_dir, "postgres.log")
      ensure_private_file_parent(log)
      result = ProcessRunner.run(
        [@toolchain.pg_ctl, "-D", @data_directory, "-l", log,
         "-o", "-k #{@socket_directory} -c listen_addresses='' -c unix_socket_permissions=0700",
         "-w", "start"],
        env: @toolchain.environment,
        timeout: 30.seconds,
        output_limit: 16 * 1024,
      )
      attempt_identity = postmaster_identity
      unless result.success?
        cleanup_error = cleanup_started_postgres_locked!(attempt_identity, previous_identity)
        raise Error.new("managed PostgreSQL failed to start and cleanup failed") if cleanup_error
        raise Error.new("managed PostgreSQL failed to start: #{result.diagnostic}")
      end

      begin
        wait_until_ready!
        unless managed_configuration_ok?
          raise Error.new("managed PostgreSQL started with ineffective managed settings")
        end
      rescue ex
        attempt = attempt_identity || postmaster_identity
        cleanup_error = cleanup_started_postgres_locked!(attempt, previous_identity)
        raise Error.new("managed PostgreSQL startup cleanup failed") if cleanup_error
        raise ex
      end
    end

    private def stop_locked! : Nil
      return unless File.exists?(File.join(@data_directory, "postmaster.pid"))
      unless verified_postmaster_pid?
        raise OwnershipError.new("refusing to stop an unverified PostgreSQL PID")
      end

      result = ProcessRunner.run(
        [@toolchain.pg_ctl, "-D", @data_directory, "-m", "fast", "-w", "stop"],
        env: @toolchain.environment,
        timeout: 30.seconds,
        output_limit: 16 * 1024,
      )
      if !result.success? && verified_postmaster_pid?
        raise Error.new("managed PostgreSQL failed to stop: #{result.diagnostic}")
      end
      raise Error.new("managed PostgreSQL is still running") if verified_postmaster_pid?
    end

    private def reload_configuration_locked! : Nil
      result = ProcessRunner.run(
        [@toolchain.pg_ctl, "-D", @data_directory, "reload"],
        env: @toolchain.environment,
        timeout: 10.seconds,
        output_limit: 8 * 1024,
      )
      raise Error.new("managed PostgreSQL configuration reload failed") unless result.success?
    end

    private def managed_configuration_ok? : Bool
      socket = self.class.quote_literal(@socket_directory)
      sql = <<-SQL
        SELECT current_setting('listen_addresses') = ''
          AND current_setting('unix_socket_directories') = #{socket}
          AND current_setting('unix_socket_permissions') IN ('0700', '700')
          AND current_setting('max_connections') = '#{MAX_CONNECTIONS}'
          AND current_setting('password_encryption') = 'scram-sha-256'
          AND current_setting('timezone') = 'UTC'
          AND current_setting('log_statement') = 'none'
          AND current_setting('log_min_error_statement') = 'panic'
          AND current_setting('log_parameter_max_length') = '0'
          AND current_setting('log_parameter_max_length_on_error') = '0'
          AND current_setting('shared_preload_libraries') = '#{PRELOADED_LIBRARIES}'
          AND current_setting('file_copy_method') = 'clone';
        SQL
      run_admin_psql(sql).strip == "t"
    rescue
      false
    end

    private def cleanup_started_postgres_locked!(
      attempt : PostmasterIdentity?,
      previous : PostmasterIdentity?,
    ) : Exception?
      return unless attempt
      return if previous && same_postmaster_identity?(attempt, previous)
      current = postmaster_identity
      return unless current && same_postmaster_identity?(current, attempt)
      begin
        OperationDeadline.without { stop_locked! }
        nil
      rescue ex
        STDERR.puts("Latte PostgreSQL startup cleanup failed: #{ex.class}")
        ex
      end
    end

    private def same_postmaster_identity?(left : PostmasterIdentity,
                                          right : PostmasterIdentity) : Bool
      left.pid == right.pid && left.data_directory == right.data_directory &&
        left.start_time == right.start_time
    end

    private def cluster_initialized? : Bool
      version_path = File.join(@data_directory, "PG_VERSION")
      return true if File.exists?(version_path)
      entries = Dir.children(@data_directory)
      unless entries.empty?
        message = "managed PostgreSQL data directory is non-empty " \
                  "but has no PG_VERSION; it was preserved"
        raise ExistingData.new(message)
      end
      false
    end

    private def validate_data_directory! : Nil
      StateSecurity.validate_owned_directory(@data_directory)
      if info = File.info?(File.join(@data_directory, "PG_VERSION"), follow_symlinks: false)
        raise OwnershipError.new("managed PostgreSQL version file is a symlink") if info.symlink?
        unless owned?(info)
          raise OwnershipError.new("managed PostgreSQL version file has foreign ownership")
        end
      end
      StateSecurity.ensure_owned_directory(@socket_directory)
    end

    private def verify_cluster_major! : Nil
      value = File.read(File.join(@data_directory, "PG_VERSION")).strip
      actual = value.to_i?
      raise Error.new("managed PostgreSQL PG_VERSION is invalid; data was preserved") unless actual
      raise WrongMajor.new(MAJOR, actual) unless actual == MAJOR
    end

    # Until a release ships the pg_upgrade step for a major bump (ADR 0016),
    # another major's cluster holds the user's databases: starting an empty
    # cluster beside it would look like losing them.
    private def refuse_other_major_cluster! : Nil
      root = @paths.postgres_root
      Dir.children(root).each do |name|
        next if name == MAJOR.to_s
        version = File.join(root, name, "data", "PG_VERSION")
        next unless File.file?(version)
        raise WrongMajor.new(MAJOR, File.read(version).strip.to_i? || 0)
      end
    end

    private def initialize_cluster! : Nil
      passfile = initdb_password_file
      result = ProcessRunner.run(
        [@toolchain.initdb, "-D", @data_directory, "--username", ADMIN_USER,
         "--pwfile", passfile, "--encoding=UTF8", "--locale=C",
         "--auth-local=scram-sha-256", "--auth-host=scram-sha-256", "--no-instructions"],
        env: @toolchain.environment,
        timeout: 120.seconds,
        output_limit: 16 * 1024,
      )
      unless result.success?
        raise Error.new("managed PostgreSQL initialization failed: #{result.diagnostic}")
      end
      verify_cluster_major!
    end

    private def ensure_configuration! : Nil
      config = File.join(@data_directory, "postgresql.conf")
      hba = File.join(@data_directory, "pg_hba.conf")
      unless File.exists?(config) && File.exists?(hba)
        raise Error.new("managed PostgreSQL configuration is missing")
      end
      validate_private_file!(config, "managed PostgreSQL configuration")
      validate_private_file!(hba, "managed PostgreSQL authentication configuration")
      managed_block = <<-CONF

        # Caramel Latte managed settings
        listen_addresses = ''
        unix_socket_directories = #{config_literal(@socket_directory)}
        unix_socket_permissions = 0700
        max_connections = #{MAX_CONNECTIONS}
        password_encryption = 'scram-sha-256'
        timezone = 'UTC'
        log_statement = 'none'
        log_min_error_statement = 'panic'
        log_parameter_max_length = 0
        log_parameter_max_length_on_error = 0
        shared_preload_libraries = '#{PRELOADED_LIBRARIES}'
        pg_stat_statements.track = top
        auto_explain.log_min_duration = '250ms'
        auto_explain.log_analyze = off
        auto_explain.log_format = text
        auto_explain.log_parameter_max_length = 0
        # STRATEGY FILE_COPY branches clone files copy-on-write (APFS clonefile).
        file_copy_method = clone
        CONF
      config_text = File.read(config)
      managed_text = managed_block.strip
      unless config_text.rstrip.ends_with?(managed_text)
        atomic_private_write(config, "#{config_text.rstrip}\n\n#{managed_text}\n")
      end

      hba_text = File.read(hba)
      hba_block = <<-HBA

        # Caramel Latte managed authentication
        local all all scram-sha-256
        host all all 0.0.0.0/0 reject
        host all all ::0/0 reject
        HBA
      # pg_hba.conf uses first-match semantics. Put Latte's SCRAM/local and
      # no-TCP rules before provider defaults so an old trust rule cannot win.
      unless hba_text.lstrip.starts_with?(hba_block.strip)
        atomic_private_write(hba, "#{hba_block}\n#{hba_text}")
      end
    end

    private def wait_until_ready! : Nil
      deadline = Time.instant + 20.seconds
      until Time.instant >= deadline
        OperationDeadline.check!
        return if ready?
        pid_file = File.join(@data_directory, "postmaster.pid")
        if File.exists?(pid_file) && !verified_postmaster_pid?
          raise Error.new("managed PostgreSQL exited during readiness")
        end
        sleep 100.milliseconds
      end
      raise Error.new("managed PostgreSQL readiness deadline exceeded")
    end

    private def verified_postmaster_pid? : Bool
      !!postmaster_identity
    end

    # ameba:disable Metrics/CyclomaticComplexity -- verifies each postmaster.pid field first
    private def postmaster_identity : PostmasterIdentity?
      pid_file = File.join(@data_directory, "postmaster.pid")
      info = File.info?(pid_file, follow_symlinks: false)
      return unless info
      raise OwnershipError.new("managed PostgreSQL PID file is a symlink") if info.symlink?
      return unless info.file?
      unless owned?(info)
        raise OwnershipError.new("managed PostgreSQL PID file has foreign ownership")
      end
      raise OwnershipError.new("managed PostgreSQL PID file must be private") if shared?(info)
      pid_lines = File.read(pid_file).lines.map(&.strip)
      return if pid_lines.size < 3 || pid_lines[1] != @data_directory
      pid = pid_lines[0].to_i64?
      return unless pid && pid > 1
      postmaster_start = pid_lines[2].to_i64?
      return unless postmaster_start
      return unless Process.exists?(pid)
      ps = File.exists?("/bin/ps") ? "/bin/ps" : "/usr/bin/ps"
      result = ProcessRunner.run(
        [ps, "-ww", "-p", pid.to_s, "-o", "uid=,lstart=,command="],
        timeout: 2.seconds,
        output_limit: 16 * 1024,
      )
      return unless result.success?
      fields = result.stdout.strip.split(/\s+/, 7)
      return if fields.size < 7
      return unless fields[0].to_i64? == StateSecurity.current_uid
      lstart = Time::Format.new("%a %b %e %T %Y", Time::Location.local)
      process_start = lstart.parse(fields[1, 5].join(" ")).to_unix
      return unless (process_start - postmaster_start).abs <= 1
      # Any toolchain's build of this major may have started it, as before an
      # upgrade; its private pid file, owner, start time and data directory
      # identify it.
      executable, separator, arguments = fields[6].partition(" -D ")
      return if separator.empty? || !executable.ends_with?("/bin/postgres")
      return unless arguments == @data_directory || arguments.starts_with?("#{@data_directory} ")
      PostmasterIdentity.new(pid, @data_directory, postmaster_start)
    rescue ex : OwnershipError
      raise ex
    rescue
      nil
    end

    private def ensure_admin_material!(for_initialization : Bool) : AdminMaterial
      if material = load_admin_material?
        @admin_record = material
        write_admin_passfile(material.password)
        write_initdb_password_file(material.password)
        return material
      end
      unless for_initialization
        message = "managed PostgreSQL administrator secret is missing; " \
                  "data was preserved"
        raise SecretMissing.new(message)
      end
      material = AdminMaterial.new(ADMIN_USER, Random::Secure.hex(32))
      write_admin_record(material)
      write_admin_passfile(material.password)
      write_initdb_password_file(material.password)
      @admin_record = material
      material
    end

    private def admin_material : AdminMaterial
      @admin_record || ensure_admin_material!(false)
    end

    private def load_admin_material? : AdminMaterial?
      path = admin_secret_path
      return unless File.exists?(path)
      info = File.info(path, follow_symlinks: false)
      raise OwnershipError.new("managed administrator secret is a symlink") if info.symlink?
      unless owned?(info)
        raise OwnershipError.new("managed administrator secret has foreign ownership")
      end
      unless info.file?
        raise SecretMissing.new("managed administrator secret is not a regular file")
      end
      if info.permissions.value != 0o600
        raise OwnershipError.new("managed administrator secret must be private")
      end
      json = JSON.parse(File.read(path))
      username = json["username"].as_s
      password = json["password"].as_s
      if username != ADMIN_USER || password.size < 32 || password.includes?('\n')
        raise SecretMissing.new("managed administrator secret is invalid")
      end
      AdminMaterial.new(username, password)
    rescue JSON::ParseException
      raise SecretMissing.new("managed administrator secret is invalid")
    end

    private def write_admin_record(material : AdminMaterial) : Nil
      write_secret_json(admin_secret_path) do |json|
        json.object do
          json.field "version", 1
          json.field "username", material.username
          json.field "password", material.password
        end
      end
    end

    private def admin_passfile : String
      File.join(@paths.secrets_dir, "postgres-admin.pgpass")
    end

    private def initdb_password_file : String
      File.join(@paths.secrets_dir, "postgres-admin.initpw")
    end

    private def write_admin_passfile(password : String) : Nil
      atomic_private_write(admin_passfile, "*:*:*:#{ADMIN_USER}:#{password}\n")
    end

    private def write_initdb_password_file(password : String) : Nil
      atomic_private_write(initdb_password_file, "#{password}\n")
    end

    private def load_or_create_material(site : Site) : Material
      return load_material(site) if File.exists?(credentials_path(site))
      databases = self.class.database_names(site.id)
      roles = self.class.role_names(site.id)
      material = Material.new(
        site.id,
        databases,
        roles,
        Random::Secure.hex(32),
        Random::Secure.hex(32),
        Random::Secure.hex(32),
        Random::Secure.hex(32),
      )
      write_material(material)
      material
    end

    private def load_material(site : Site) : Material
      path = credentials_path(site)
      unless File.exists?(path)
        raise SecretMissing.new("site PostgreSQL credentials are not provisioned")
      end
      info = File.info(path, follow_symlinks: false)
      raise OwnershipError.new("site PostgreSQL credentials are a symlink") if info.symlink?
      unless owned?(info)
        raise OwnershipError.new("site PostgreSQL credentials have foreign ownership")
      end
      unless info.file?
        raise SecretMissing.new("site PostgreSQL credentials are not a regular file")
      end
      if info.permissions.value != 0o600
        raise OwnershipError.new("site PostgreSQL credentials must be private")
      end
      json = JSON.parse(File.read(path))
      id = json["site_id"].as_s
      unless id == site.id
        raise SecretMissing.new("site PostgreSQL credentials do not match this site")
      end
      names = json["databases"]
      databases = DatabaseNames.new(names["development"].as_s, names["spec"].as_s)
      roles = RoleNames.new(
        json["roles"]["development_runtime"].as_s,
        json["roles"]["development_migration"].as_s,
        json["roles"]["spec_runtime"].as_s,
        json["roles"]["spec_migration"].as_s,
      )
      passwords = json["passwords"]
      values = [
        passwords["development_runtime"].as_s,
        passwords["development_migration"].as_s,
        passwords["spec_runtime"].as_s,
        passwords["spec_migration"].as_s,
      ]
      if values.any? { |value| value.empty? || value.includes?('\n') }
        raise SecretMissing.new("site PostgreSQL credentials are invalid")
      end
      Material.new(id, databases, roles, values[0], values[1], values[2], values[3])
    rescue JSON::ParseException
      raise SecretMissing.new("site PostgreSQL credentials are invalid")
    end

    private def write_material(material : Material) : Nil
      write_secret_json(credentials_path_for_id(material.site_id)) do |json|
        json.object do
          json.field "version", 1
          json.field "site_id", material.site_id
          json.field "databases" do
            json.object do
              json.field "development", material.databases.development
              json.field "spec", material.databases.spec
            end
          end
          json.field "roles" do
            json.object do
              json.field "development_runtime", material.roles.development_runtime
              json.field "development_migration", material.roles.development_migration
              json.field "spec_runtime", material.roles.spec_runtime
              json.field "spec_migration", material.roles.spec_migration
            end
          end
          json.field "passwords" do
            json.object do
              json.field "development_runtime", material.development_runtime_password
              json.field "development_migration", material.development_migration_password
              json.field "spec_runtime", material.spec_runtime_password
              json.field "spec_migration", material.spec_migration_password
            end
          end
        end
      end
    end

    private def credentials_path_for_id(id : String) : String
      self.class.validate_site_id!(id)
      File.join(@paths.secrets_dir, "site-#{id}.json")
    end

    private def credentials_from(material : Material) : Credentials
      Credentials.new(
        development_runtime: role_url(material, :development, :runtime),
        development_migration: role_url(material, :development, :migration),
        spec_runtime: role_url(material, :spec, :runtime),
        spec_migration: role_url(material, :spec, :migration),
        development_database: material.databases.development,
        spec_database: material.databases.spec,
        roles: material.roles,
        databases: material.databases,
      )
    end

    private def role_url(material : Material, environment : Symbol, role_kind : Symbol) : String
      database, role, password = selected_connection(material, environment, role_kind)
      socket_url(role, password, database)
    end

    # A URL for *user* on *database* through this cluster's socket.
    private def socket_url(user : String, password : String, database : String) : String
      self.class.connection_url(user, password, database, @socket_directory)
    end

    # Spec migrations allow one connection per Corretto test worker.
    private def ensure_roles(material : Material) : Nil
      roles = material.roles
      ensure_role(roles.development_migration, material.development_migration_password,
        MIGRATION_CONNECTION_LIMIT)
      ensure_role(roles.development_runtime, material.development_runtime_password,
        RUNTIME_CONNECTION_LIMIT)
      ensure_role(roles.spec_migration, material.spec_migration_password,
        MAX_TEST_WORKERS)
      ensure_role(roles.spec_runtime, material.spec_runtime_password,
        RUNTIME_CONNECTION_LIMIT)
    end

    private def ensure_databases(material : Material) : Nil
      databases, roles = material.databases, material.roles
      ensure_database(databases.development, roles.development_migration)
      ensure_database(databases.spec, roles.spec_migration)
      configure_database(databases.development,
        roles.development_migration, roles.development_runtime, statistics: true)
      configure_database(databases.spec, roles.spec_migration, roles.spec_runtime,
        statistics: false)
    end

    private def ensure_role(role : String, password : String, connection_limit : Int32) : Nil
      literal = self.class.quote_literal(role)
      name = self.class.quote_identifier(role)
      secret = self.class.quote_literal(password)
      attributes = "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS " \
                   "CONNECTION LIMIT #{connection_limit} PASSWORD #{secret}"
      sql = <<-SQL
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{literal}) THEN
            CREATE ROLE #{name} #{attributes};
          END IF;
        END
        $$;
        ALTER ROLE #{name} #{attributes};
        SQL
      run_admin_psql(sql)
    end

    private def ensure_database(database : String, owner : String) : Nil
      return if database_exists?(database)
      name = self.class.quote_identifier(database)
      owner_name = self.class.quote_identifier(owner)
      sql = "CREATE DATABASE #{name} OWNER #{owner_name} ENCODING 'UTF8' TEMPLATE template0;"
      run_admin_psql(sql)
    end

    private def database_exists?(database : String) : Bool
      literal = self.class.quote_literal(database)
      output = run_admin_psql("SELECT 1 FROM pg_database WHERE datname = #{literal};")
      output.strip == "1"
    end

    # Clones `source` into `database` behind the connection guard and admits
    # exactly `migration` and `runtime`; the caller holds @lock.
    private def clone_guarded(source : String,
                              database : String,
                              migration : String,
                              runtime : String) : Nil
      guard_connections(source) do
        run_admin_psql(self.class.branch_clone_sql(source, database, migration))
      end
      begin
        run_admin_psql(self.class.branch_access_sql(database, migration, runtime))
      rescue ex
        OperationDeadline.without { run_admin_psql(self.class.branch_drop_sql(database)) }
        raise ex
      end
    end

    private def drop_database(database : String) : Bool
      @lock.synchronize do
        return false unless database_exists?(database)
        run_admin_psql(self.class.branch_drop_sql(database))
        true
      end
    end

    private def configure_database(database : String,
                                   migration_role : String,
                                   runtime_role : String,
                                   statistics : Bool) : Nil
      name = self.class.quote_identifier(database)
      migration = self.class.quote_identifier(migration_role)
      runtime = self.class.quote_identifier(runtime_role)
      sql = <<-SQL
        ALTER DATABASE #{name} OWNER TO #{migration};
        ALTER DATABASE #{name} SET timezone TO 'UTC';
        REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE #{name} FROM PUBLIC;
        GRANT CONNECT ON DATABASE #{name} TO #{migration}, #{runtime};
        #{"GRANT pg_read_all_stats TO #{runtime};" if statistics}
        SQL
      run_admin_psql(sql)

      defaults = "ALTER DEFAULT PRIVILEGES FOR ROLE #{migration} IN SCHEMA public"
      database_sql = <<-SQL
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        ALTER SCHEMA public OWNER TO #{migration};
        REVOKE ALL ON SCHEMA public FROM #{runtime};
        GRANT USAGE ON SCHEMA public TO #{runtime};
        #{defaults} REVOKE ALL ON TABLES FROM PUBLIC;
        #{defaults} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{runtime};
        #{defaults} REVOKE ALL ON SEQUENCES FROM PUBLIC;
        #{defaults} GRANT USAGE, SELECT ON SEQUENCES TO #{runtime};
        CREATE TABLE IF NOT EXISTS caramel_migrations (
          version bigint PRIMARY KEY,
          name text NOT NULL,
          checksum text NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        ALTER TABLE caramel_migrations OWNER TO #{migration};
        REVOKE ALL ON TABLE caramel_migrations FROM #{runtime};
        GRANT SELECT ON TABLE caramel_migrations TO #{runtime};
        SQL
      database_sql += statistics_sql(migration, runtime) if statistics
      run_psql(database_sql, database, ADMIN_USER, admin_material.password)
    end

    # `pg_stat_statements` in a schema of its own, so its views stay out of `public`, which
    # SugarORM's introspection and Corretto's catalog fingerprint read.
    private def statistics_sql(migration : String, runtime : String) : String
      schema = self.class.quote_identifier(STATISTICS_SCHEMA)
      <<-SQL
        CREATE SCHEMA IF NOT EXISTS #{schema};
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA #{schema};
        GRANT USAGE ON SCHEMA #{schema} TO #{migration}, #{runtime};
        SQL
    end

    # Runs *sql* as the cluster's administrator in the postgres database.
    private def run_admin_psql(sql : String) : String
      run_psql(sql, "postgres", ADMIN_USER, admin_material.password)
    end

    private def run_psql(sql : String, database : String, role : String, password : String) : String
      run_with_password_file(role, password) do |passfile|
        result = ProcessRunner.run(
          [@toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t",
           "-h", @socket_directory, "-U", role, "-d", database],
          input: sql,
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 15.seconds,
          output_limit: 32 * 1024,
        )
        unless result.success?
          raise Error.new("managed PostgreSQL administration failed: #{result.diagnostic}")
        end
        result.stdout
      end
    end

    private def run_with_password_file(role : String, password : String, & : String -> _)
      file = File.tempfile("caramel-latte-pass", ".pgpass", dir: @paths.secrets_dir)
      begin
        file.chmod(0o600)
        file << "*:*:*:#{role}:#{password}\n"
        file.flush
        file.close
        yield file.path
      ensure
        file.close unless file.closed?
        File.delete(file.path) if File.exists?(file.path)
      end
    end

    private def selected_connection(material : Material,
                                    environment : Symbol,
                                    role_kind : Symbol) : Tuple(String, String, String)
      databases, roles = material.databases, material.roles
      case {environment, role_kind}
      when {:development, :migration}
        {databases.development, roles.development_migration,
         material.development_migration_password}
      when {:development, :runtime}
        {databases.development, roles.development_runtime,
         material.development_runtime_password}
      when {:spec, :migration}
        {databases.spec, roles.spec_migration, material.spec_migration_password}
      when {:spec, :runtime}
        {databases.spec, roles.spec_runtime, material.spec_runtime_password}
      else
        raise ArgumentError.new("environment must be development or spec")
      end
    end

    private def ensure_backup_destination(destination : String) : Nil
      unless Path[destination].absolute?
        raise ArgumentError.new("backup destination must be absolute")
      end
      parent = File.dirname(destination)
      StateSecurity.validate_owned_directory(parent)
      if info = File.info?(destination, follow_symlinks: false)
        raise ArgumentError.new("backup destination must not be a symlink") if info.symlink?
        raise ArgumentError.new("backup destination has foreign ownership") unless owned?(info)
        raise ArgumentError.new("backup destination must be a regular file") unless info.file?
        raise ArgumentError.new("backup destination must be private") if shared?(info)
      end
    end

    private def ensure_private_file_parent(path : String) : Nil
      parent = File.dirname(path)
      StateSecurity.ensure_owned_directory(parent)
      if info = File.info?(path, follow_symlinks: false)
        raise OwnershipError.new("managed log is a symlink") if info.symlink?
        raise OwnershipError.new("managed log has foreign ownership") unless owned?(info)
        raise OwnershipError.new("managed log is not a regular file") unless info.file?
        File.chmod(path, 0o600) if info.permissions.value != 0o600
      end
    end

    private def write_secret_json(path : String, & : JSON::Builder ->) : Nil
      parent = File.dirname(path)
      StateSecurity.ensure_owned_directory(parent)
      validate_replacement_target!(path, "managed secret", 0o600)
      temporary = File.tempfile("caramel-secret", ".tmp", dir: parent)
      begin
        temporary.chmod(0o600)
        builder = JSON::Builder.new(temporary)
        builder.start_document
        yield builder
        builder.end_document
        temporary << '\n'
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close unless temporary.closed?
        File.delete(temporary.path) if File.exists?(temporary.path)
      end
    end

    private def atomic_private_write(path : String, content : String) : Nil
      parent = File.dirname(path)
      StateSecurity.ensure_owned_directory(parent)
      validate_replacement_target!(path, "managed private file")
      temporary = File.tempfile("caramel-private", ".tmp", dir: parent)
      begin
        temporary.chmod(0o600)
        temporary << content
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close unless temporary.closed?
        File.delete(temporary.path) if File.exists?(temporary.path)
      end
    end

    private def validate_private_file!(path : String, label : String) : Nil
      info = File.info?(path, follow_symlinks: false)
      raise Error.new("#{label} is missing") unless info
      raise OwnershipError.new("#{label} is a symlink") if info.symlink?
      raise OwnershipError.new("#{label} has foreign ownership") unless owned?(info)
      raise Error.new("#{label} is not a regular file") unless info.file?
      raise OwnershipError.new("#{label} must be private") if shared?(info)
    end

    private def validate_replacement_target!(path : String,
                                             label : String,
                                             expected_mode : Int32? = nil) : Nil
      info = File.info?(path, follow_symlinks: false)
      return unless info
      raise OwnershipError.new("#{label} is a symlink") if info.symlink?
      raise OwnershipError.new("#{label} has foreign ownership") unless owned?(info)
      raise OwnershipError.new("#{label} is not a regular file") unless info.file?
      if expected_mode
        unless info.permissions.value == expected_mode
          raise OwnershipError.new("#{label} must be mode #{expected_mode.to_s(8)}")
        end
      else
        raise OwnershipError.new("#{label} must be private") if shared?(info)
      end
    end

    private def owned?(info : File::Info) : Bool
      info.owner_id.to_i64? == StateSecurity.current_uid
    end

    # Whether the group or other users hold any permission on it.
    private def shared?(info : File::Info) : Bool
      (info.permissions.value & 0o077) != 0
    end

    def self.validate_site_id!(id : String) : Nil
      return if id =~ /\A[0-9a-f]{16}\z/
      raise ArgumentError.new("site id must be exactly 16 lowercase hexadecimal characters")
    end
  end

  alias PostgreSQL = Postgres
  alias PostgresService = Postgres
end
