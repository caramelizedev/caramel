require "file_utils"
require "json"
require "random/secure"
require "uri"
require "./paths"
require "./site"
require "./process"
require "./toolchain"

module Caramel::Latte
  # The one PostgreSQL instance owned by Latte for a given major version.
  # Projects receive databases and non-privileged roles inside this cluster;
  # project removal never removes those databases.
  class Postgres
    MAJOR                      = Toolchain::POSTGRES_MAJOR
    MAX_CONNECTIONS            = 64
    RUNTIME_CONNECTION_LIMIT   =  4
    MIGRATION_CONNECTION_LIMIT =  1
    ADMIN_USER                 = "caramel_admin"

    class Error < Exception
    end

    class ExistingData < Error
    end

    class WrongMajor < Error
      getter expected : Int32
      getter actual : Int32

      def initialize(@expected : Int32, @actual : Int32)
        super("managed PostgreSQL major #{@expected} is required; existing cluster has major #{@actual}")
      end
    end

    class SecretMissing < Error
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

      def initialize(@development_runtime : String, @development_migration : String, @spec_runtime : String, @spec_migration : String)
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

    def initialize(@paths : Paths, @toolchain : Toolchain = Toolchain.new)
      @lock = Mutex.new
      @data_directory = @paths.postgres_data
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
        run_psql("SELECT 1", "postgres", ADMIN_USER, admin_material.password)
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
        ensure_role(material.roles.development_migration, material.development_migration_password, MIGRATION_CONNECTION_LIMIT)
        ensure_role(material.roles.development_runtime, material.development_runtime_password, RUNTIME_CONNECTION_LIMIT)
        ensure_role(material.roles.spec_migration, material.spec_migration_password, MIGRATION_CONNECTION_LIMIT)
        ensure_role(material.roles.spec_runtime, material.spec_runtime_password, RUNTIME_CONNECTION_LIMIT)

        ensure_database(material.databases.development, material.roles.development_migration)
        ensure_database(material.databases.spec, material.roles.spec_migration)
        configure_database(material.databases.development, material.roles.development_migration, material.roles.development_runtime)
        configure_database(material.databases.spec, material.roles.spec_migration, material.roles.spec_runtime)
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
          [@toolchain.pg_dump, "--format=custom", "--no-owner", "--file", destination, "--dbname", self.class.connection_url(role, "", database, @socket_directory)],
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 120.seconds,
          output_limit: 16 * 1024,
        )
        raise Error.new("managed PostgreSQL backup failed: #{result.diagnostic}") unless result.success?
      end
      File.chmod(destination, 0o600)
      destination
    end

    def restore(site : Site, backup_file : String, environment : Symbol = :development) : Nil
      material = load_material(site)
      database, role, password = selected_connection(material, environment, :migration)
      info = File.info(backup_file, follow_symlinks: false)
      StateSecurity.validate_owned_directory(File.dirname(backup_file))
      raise ArgumentError.new("backup must be an owned regular file") if info.symlink? || !info.file? || info.owner_id.to_i64? != StateSecurity.current_uid
      raise ArgumentError.new("backup must be mode 0600") unless info.permissions.value == 0o600
      run_with_password_file(role, password) do |passfile|
        result = ProcessRunner.run(
          [@toolchain.pg_restore, "--exit-on-error", "--clean", "--if-exists", "--no-owner", "--dbname", self.class.connection_url(role, "", database, @socket_directory), backup_file],
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 120.seconds,
          output_limit: 16 * 1024,
        )
        raise Error.new("managed PostgreSQL restore failed: #{result.diagnostic}") unless result.success?
      end
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

    def self.connection_url(user : String, password : String, database : String, socket_directory : String) : String
      "postgresql://#{user}:#{password}@/#{database}?host=#{URI.encode_www_form(socket_directory)}&port=5432"
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

    private def start_locked! : Nil
      @toolchain.verify_postgres_version!(Toolchain::POSTGRES_VERSION)
      validate_data_directory!
      if cluster_initialized?
        verify_cluster_major!
        ensure_admin_material!(false)
      else
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
        raise Error.new("managed PostgreSQL started with ineffective managed settings") unless managed_configuration_ok?
      rescue ex
        cleanup_error = cleanup_started_postgres_locked!(attempt_identity || postmaster_identity, previous_identity)
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
      unless result.success? || !verified_postmaster_pid?
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
      sql = <<-SQL
      SELECT current_setting('listen_addresses') = ''
        AND current_setting('unix_socket_directories') = #{self.class.quote_literal(@socket_directory)}
        AND current_setting('unix_socket_permissions') IN ('0700', '700')
        AND current_setting('max_connections') = '#{MAX_CONNECTIONS}'
        AND current_setting('password_encryption') = 'scram-sha-256'
        AND current_setting('timezone') = 'UTC'
        AND current_setting('log_statement') = 'none'
        AND current_setting('log_min_error_statement') = 'panic'
        AND current_setting('log_parameter_max_length') = '0'
        AND current_setting('log_parameter_max_length_on_error') = '0';
      SQL
      run_psql(sql, "postgres", ADMIN_USER, admin_material.password).strip == "t"
    rescue
      false
    end

    private def cleanup_started_postgres_locked!(attempt : PostmasterIdentity?, previous : PostmasterIdentity?) : Exception?
      return nil unless attempt
      return nil if previous && same_postmaster_identity?(attempt.not_nil!, previous.not_nil!)
      current = postmaster_identity
      return nil unless current && same_postmaster_identity?(current.not_nil!, attempt.not_nil!)
      begin
        OperationDeadline.without { stop_locked! }
        nil
      rescue ex
        STDERR.puts("Latte PostgreSQL startup cleanup failed: #{ex.class}")
        ex
      end
    end

    private def same_postmaster_identity?(left : PostmasterIdentity, right : PostmasterIdentity) : Bool
      left.pid == right.pid && left.data_directory == right.data_directory && left.start_time == right.start_time
    end

    private def cluster_initialized? : Bool
      version_path = File.join(@data_directory, "PG_VERSION")
      return true if File.exists?(version_path)
      entries = Dir.children(@data_directory)
      unless entries.empty?
        raise ExistingData.new("managed PostgreSQL data directory is non-empty but has no PG_VERSION; it was preserved")
      end
      false
    end

    private def validate_data_directory! : Nil
      StateSecurity.validate_owned_directory(@data_directory)
      if info = File.info?(File.join(@data_directory, "PG_VERSION"), follow_symlinks: false)
        raise OwnershipError.new("managed PostgreSQL version file is a symlink") if info.symlink?
        raise OwnershipError.new("managed PostgreSQL version file has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
      end
      StateSecurity.ensure_owned_directory(@socket_directory)
    end

    private def verify_cluster_major! : Nil
      value = File.read(File.join(@data_directory, "PG_VERSION")).strip
      actual = value.to_i?
      raise Error.new("managed PostgreSQL PG_VERSION is invalid; data was preserved") unless actual
      raise WrongMajor.new(MAJOR, actual) unless actual == MAJOR
    end

    private def initialize_cluster! : Nil
      passfile = initdb_password_file
      result = ProcessRunner.run(
        [@toolchain.initdb, "-D", @data_directory, "--username", ADMIN_USER, "--pwfile", passfile,
         "--encoding=UTF8", "--locale=C", "--auth-local=scram-sha-256", "--auth-host=scram-sha-256", "--no-instructions"],
        env: @toolchain.environment,
        timeout: 120.seconds,
        output_limit: 16 * 1024,
      )
      raise Error.new("managed PostgreSQL initialization failed: #{result.diagnostic}") unless result.success?
      verify_cluster_major!
    end

    private def ensure_configuration! : Nil
      config = File.join(@data_directory, "postgresql.conf")
      hba = File.join(@data_directory, "pg_hba.conf")
      raise Error.new("managed PostgreSQL configuration is missing") unless File.exists?(config) && File.exists?(hba)
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
        raise Error.new("managed PostgreSQL exited during readiness") if File.exists?(File.join(@data_directory, "postmaster.pid")) && !verified_postmaster_pid?
        sleep 100.milliseconds
      end
      raise Error.new("managed PostgreSQL readiness deadline exceeded")
    end

    private def verified_postmaster_pid? : Bool
      !!postmaster_identity
    end

    private def postmaster_identity : PostmasterIdentity?
      pid_file = File.join(@data_directory, "postmaster.pid")
      info = File.info?(pid_file, follow_symlinks: false)
      return nil unless info
      raise OwnershipError.new("managed PostgreSQL PID file is a symlink") if info.symlink?
      return nil unless info.file?
      raise OwnershipError.new("managed PostgreSQL PID file has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
      raise OwnershipError.new("managed PostgreSQL PID file must be private") if (info.permissions.value & 0o077) != 0
      pid_lines = File.read(pid_file).lines.map(&.strip)
      return nil if pid_lines.size < 3 || pid_lines[1] != @data_directory
      pid = pid_lines[0].to_i64?
      return nil unless pid && pid > 1
      postmaster_start = pid_lines[2].to_i64?
      return nil unless postmaster_start
      return nil unless Process.exists?(pid)
      ps = File.exists?("/bin/ps") ? "/bin/ps" : "/usr/bin/ps"
      result = ProcessRunner.run([ps, "-ww", "-p", pid.to_s, "-o", "uid=,lstart=,command="], timeout: 2.seconds, output_limit: 16 * 1024)
      return nil unless result.success?
      fields = result.stdout.strip.split(/\s+/, 7)
      return nil if fields.size < 7
      return nil unless fields[0].to_i64? == StateSecurity.current_uid
      process_start = Time::Format.new("%a %b %e %T %Y", Time::Location.local).parse(fields[1, 5].join(" ")).to_unix
      return nil unless (process_start - postmaster_start).abs <= 1
      command_line = fields[6]
      expected = "#{@toolchain.postgres} -D #{@data_directory}"
      return nil unless command_line == expected || command_line.starts_with?("#{expected} ")
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
        raise SecretMissing.new("managed PostgreSQL administrator secret is missing; data was preserved")
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
      return nil unless File.exists?(path)
      info = File.info(path, follow_symlinks: false)
      raise OwnershipError.new("managed administrator secret is a symlink") if info.symlink?
      raise OwnershipError.new("managed administrator secret has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
      raise SecretMissing.new("managed administrator secret is not a regular file") unless info.file?
      raise OwnershipError.new("managed administrator secret must be private") if info.permissions.value != 0o600
      json = JSON.parse(File.read(path))
      username = json["username"].as_s
      password = json["password"].as_s
      raise SecretMissing.new("managed administrator secret is invalid") unless username == ADMIN_USER && password.size >= 32 && !password.includes?('\n')
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
      raise SecretMissing.new("site PostgreSQL credentials are not provisioned") unless File.exists?(path)
      info = File.info(path, follow_symlinks: false)
      raise OwnershipError.new("site PostgreSQL credentials are a symlink") if info.symlink?
      raise OwnershipError.new("site PostgreSQL credentials have foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
      raise SecretMissing.new("site PostgreSQL credentials are not a regular file") unless info.file?
      raise OwnershipError.new("site PostgreSQL credentials must be private") if info.permissions.value != 0o600
      json = JSON.parse(File.read(path))
      id = json["site_id"].as_s
      raise SecretMissing.new("site PostgreSQL credentials do not match this site") unless id == site.id
      databases = DatabaseNames.new(json["databases"]["development"].as_s, json["databases"]["spec"].as_s)
      roles = RoleNames.new(
        json["roles"]["development_runtime"].as_s,
        json["roles"]["development_migration"].as_s,
        json["roles"]["spec_runtime"].as_s,
        json["roles"]["spec_migration"].as_s,
      )
      passwords = json["passwords"]
      values = [passwords["development_runtime"].as_s, passwords["development_migration"].as_s, passwords["spec_runtime"].as_s, passwords["spec_migration"].as_s]
      raise SecretMissing.new("site PostgreSQL credentials are invalid") if values.any? { |value| value.empty? || value.includes?('\n') }
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
        self.class.connection_url(material.roles.development_runtime, material.development_runtime_password, material.databases.development, @socket_directory),
        self.class.connection_url(material.roles.development_migration, material.development_migration_password, material.databases.development, @socket_directory),
        self.class.connection_url(material.roles.spec_runtime, material.spec_runtime_password, material.databases.spec, @socket_directory),
        self.class.connection_url(material.roles.spec_migration, material.spec_migration_password, material.databases.spec, @socket_directory),
        material.databases.development,
        material.databases.spec,
        material.roles,
        material.databases,
      )
    end

    private def ensure_role(role : String, password : String, connection_limit : Int32) : Nil
      sql = <<-SQL
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{self.class.quote_literal(role)}) THEN
          CREATE ROLE #{self.class.quote_identifier(role)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT #{connection_limit} PASSWORD #{self.class.quote_literal(password)};
        END IF;
      END
      $$;
      ALTER ROLE #{self.class.quote_identifier(role)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS CONNECTION LIMIT #{connection_limit} PASSWORD #{self.class.quote_literal(password)};
      SQL
      run_psql(sql, "postgres", ADMIN_USER, admin_material.password)
    end

    private def ensure_database(database : String, owner : String) : Nil
      return if database_exists?(database)
      sql = "CREATE DATABASE #{self.class.quote_identifier(database)} OWNER #{self.class.quote_identifier(owner)} ENCODING 'UTF8' TEMPLATE template0;"
      run_psql(sql, "postgres", ADMIN_USER, admin_material.password)
    end

    private def database_exists?(database : String) : Bool
      output = run_psql("SELECT 1 FROM pg_database WHERE datname = #{self.class.quote_literal(database)};", "postgres", ADMIN_USER, admin_material.password)
      output.strip == "1"
    end

    private def configure_database(database : String, migration_role : String, runtime_role : String) : Nil
      sql = <<-SQL
      ALTER DATABASE #{self.class.quote_identifier(database)} OWNER TO #{self.class.quote_identifier(migration_role)};
      ALTER DATABASE #{self.class.quote_identifier(database)} SET timezone TO 'UTC';
      REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE #{self.class.quote_identifier(database)} FROM PUBLIC;
      GRANT CONNECT ON DATABASE #{self.class.quote_identifier(database)} TO #{self.class.quote_identifier(migration_role)}, #{self.class.quote_identifier(runtime_role)};
      SQL
      run_psql(sql, "postgres", ADMIN_USER, admin_material.password)

      database_sql = <<-SQL
      REVOKE ALL ON SCHEMA public FROM PUBLIC;
      ALTER SCHEMA public OWNER TO #{self.class.quote_identifier(migration_role)};
      REVOKE ALL ON SCHEMA public FROM #{self.class.quote_identifier(runtime_role)};
      GRANT USAGE ON SCHEMA public TO #{self.class.quote_identifier(runtime_role)};
      ALTER DEFAULT PRIVILEGES FOR ROLE #{self.class.quote_identifier(migration_role)} IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
      ALTER DEFAULT PRIVILEGES FOR ROLE #{self.class.quote_identifier(migration_role)} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{self.class.quote_identifier(runtime_role)};
      ALTER DEFAULT PRIVILEGES FOR ROLE #{self.class.quote_identifier(migration_role)} IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;
      ALTER DEFAULT PRIVILEGES FOR ROLE #{self.class.quote_identifier(migration_role)} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO #{self.class.quote_identifier(runtime_role)};
      CREATE TABLE IF NOT EXISTS caramel_migrations (
        version bigint PRIMARY KEY,
        name text NOT NULL,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      ALTER TABLE caramel_migrations OWNER TO #{self.class.quote_identifier(migration_role)};
      REVOKE ALL ON TABLE caramel_migrations FROM #{self.class.quote_identifier(runtime_role)};
      GRANT SELECT ON TABLE caramel_migrations TO #{self.class.quote_identifier(runtime_role)};
      SQL
      run_psql(database_sql, database, ADMIN_USER, admin_material.password)
    end

    private def run_psql(sql : String, database : String, role : String, password : String) : String
      run_with_password_file(role, password) do |passfile|
        result = ProcessRunner.run(
          [@toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-h", @socket_directory, "-U", role, "-d", database],
          input: sql,
          env: @toolchain.environment({"PGPASSFILE" => passfile}),
          timeout: 15.seconds,
          output_limit: 32 * 1024,
        )
        raise Error.new("managed PostgreSQL administration failed: #{result.diagnostic}") unless result.success?
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

    private def selected_connection(material : Material, environment : Symbol, role_kind : Symbol) : Tuple(String, String, String)
      case {environment, role_kind}
      when {:development, :migration}
        {material.databases.development, material.roles.development_migration, material.development_migration_password}
      when {:development, :runtime}
        {material.databases.development, material.roles.development_runtime, material.development_runtime_password}
      when {:spec, :migration}
        {material.databases.spec, material.roles.spec_migration, material.spec_migration_password}
      when {:spec, :runtime}
        {material.databases.spec, material.roles.spec_runtime, material.spec_runtime_password}
      else
        raise ArgumentError.new("environment must be development or spec")
      end
    end

    private def ensure_backup_destination(destination : String) : Nil
      raise ArgumentError.new("backup destination must be absolute") unless Path[destination].absolute?
      parent = File.dirname(destination)
      StateSecurity.validate_owned_directory(parent)
      if info = File.info?(destination, follow_symlinks: false)
        raise ArgumentError.new("backup destination must not be a symlink") if info.symlink?
        raise ArgumentError.new("backup destination has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
        raise ArgumentError.new("backup destination must be a regular file") unless info.file?
        raise ArgumentError.new("backup destination must be private") if (info.permissions.value & 0o077) != 0
      end
    end

    private def ensure_private_file_parent(path : String) : Nil
      parent = File.dirname(path)
      StateSecurity.ensure_owned_directory(parent)
      if info = File.info?(path, follow_symlinks: false)
        raise OwnershipError.new("managed log is a symlink") if info.symlink?
        raise OwnershipError.new("managed log has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
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
      raise OwnershipError.new("#{label} is a symlink") if info.not_nil!.symlink?
      raise OwnershipError.new("#{label} has foreign ownership") unless info.not_nil!.owner_id.to_i64? == StateSecurity.current_uid
      raise Error.new("#{label} is not a regular file") unless info.not_nil!.file?
      raise OwnershipError.new("#{label} must be private") if (info.not_nil!.permissions.value & 0o077) != 0
    end

    private def validate_replacement_target!(path : String, label : String, expected_mode : Int32? = nil) : Nil
      info = File.info?(path, follow_symlinks: false)
      return unless info
      raise OwnershipError.new("#{label} is a symlink") if info.not_nil!.symlink?
      raise OwnershipError.new("#{label} has foreign ownership") unless info.not_nil!.owner_id.to_i64? == StateSecurity.current_uid
      raise OwnershipError.new("#{label} is not a regular file") unless info.not_nil!.file?
      if expected_mode
        raise OwnershipError.new("#{label} must be mode #{expected_mode.to_s(8)}") unless info.not_nil!.permissions.value == expected_mode
      else
        raise OwnershipError.new("#{label} must be private") if (info.not_nil!.permissions.value & 0o077) != 0
      end
    end

    def self.validate_site_id!(id : String) : Nil
      raise ArgumentError.new("site id must be exactly 16 lowercase hexadecimal characters") unless id =~ /\A[0-9a-f]{16}\z/
    end
  end

  alias PostgreSQL = Postgres
  alias PostgresService = Postgres
end
