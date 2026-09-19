require "db"
require "openssl"
require "pg"
require "random/secure"
require "set"
require "socket/tcp_socket"
require "socket/unix_socket"
require "system/user"
require "uri"

module Caramel
  # Creates a bounded PostgreSQL pool with an explicit transport policy.
  class Database
    # These are per-operation limits. Crystal currently applies the DNS portion
    # only on Windows; the connect portion is per resolved address, and the
    # read/write values bound inactivity after a socket is established. They
    # are not a hard end-to-end startup deadline, and Unix sockets have no
    # connect-timeout argument in the Crystal API.
    CONNECT_TIMEOUT_SECONDS = 5.0
    IO_TIMEOUT              = 5.seconds

    record Config,
      host : String,
      port : Int32,
      database : String,
      user : String,
      password : String,
      sslmode : Symbol,
      sslrootcert : String?,
      sslcert : String?,
      sslkey : String?,
      pool_options : DB::Pool::Options do
      SUPPORTED_QUERY_PARAMS = %w(host port sslmode sslrootcert sslcert sslkey)
      DEFAULT_POOL_SIZE      =  4
      MAX_POOL_SIZE          = 32

      def self.parse(url : String, pool_size : Int = DEFAULT_POOL_SIZE) : self
        unless (1..MAX_POOL_SIZE).includes?(pool_size)
          raise ArgumentError.new("pool_size must be between 1 and #{MAX_POOL_SIZE}")
        end

        uri = URI.parse(url)
        unless uri.scheme.in?(%w(postgres postgresql))
          raise ArgumentError.new("database URL must use postgres:// or postgresql://")
        end
        if uri.fragment
          raise ArgumentError.new("database URL must not contain a fragment")
        end

        params = HTTP::Params.parse(uri.query || "")
        validate_query_params(params)

        authority_host = uri.hostname.presence
        reject_nul(authority_host, "host") if authority_host
        query_host = params["host"]?.try(&.presence)
        reject_nul(query_host, "host") if query_host
        if authority_host && query_host && authority_host != query_host
          raise ArgumentError.new("database URL authority and host option conflict")
        end
        host = authority_host || query_host
        raise ArgumentError.new("database URL must include a host") unless host

        user = uri.user.presence
        raise ArgumentError.new("database URL must include a user") unless user
        reject_nul(user, "user")

        database = URI.decode(uri.path.lchop('/'))
        reject_nul(database, "database")
        raise ArgumentError.new("database URL must include a database") if database.empty?

        port = parse_port(uri, params)
        unix_socket = host.starts_with?('/')

        sslmode = parse_sslmode(params["sslmode"]?, unix_socket)
        sslrootcert = params["sslrootcert"]?
        sslcert = params["sslcert"]?
        sslkey = params["sslkey"]?
        reject_nul(sslrootcert, "sslrootcert") if sslrootcert
        reject_nul(sslcert, "sslcert") if sslcert
        reject_nul(sslkey, "sslkey") if sslkey

        password = uri.password || ""
        reject_nul(password, "password")

        if unix_socket
          validate_socket_directory(host)
          if sslrootcert || sslcert || sslkey
            raise ArgumentError.new("TLS certificate options are not valid for a Unix socket")
          end
        elsif sslcert.nil? != sslkey.nil?
          raise ArgumentError.new("sslcert and sslkey must be supplied together")
        end

        pool_size = pool_size.to_i32
        pool_options = DB::Pool::Options.new(
          initial_pool_size: 1,
          max_pool_size: pool_size,
          max_idle_pool_size: pool_size,
          retry_attempts: 0,
          retry_delay: 0.2,
        )

        new(
          host: host,
          port: port,
          database: database,
          user: user,
          # Passing an explicit string prevents crystal-pg from consulting
          # PGPASSWORD or a pgpass file. An empty value is valid for local trust.
          password: password,
          sslmode: sslmode,
          sslrootcert: sslrootcert,
          sslcert: sslcert,
          sslkey: sslkey,
          pool_options: pool_options,
        )
      end

      def unix_socket? : Bool
        @host.starts_with?('/')
      end

      def connection_options : DB::Connection::Options
        DB::Connection::Options.new(
          prepared_statements: true,
          prepared_statements_cache: true,
        )
      end

      def conninfo : PQ::ConnInfo
        mode = @sslmode == :verify_full ? :"verify-full" : :disable
        PQ::ConnInfo.new(@host, @database, @user, @password, @port, mode, "caramel")
      end

      def inspect(io : IO) : Nil
        write_debug(io)
      end

      def to_s(io : IO) : Nil
        write_debug(io)
      end

      private def write_debug(io : IO) : Nil
        io << "Caramel::Database::Config(host="
        @host.inspect(io)
        io << ", port=" << @port << ", database="
        @database.inspect(io)
        io << ", user="
        @user.inspect(io)
        io << ", password=\"[REDACTED]\", sslmode="
        @sslmode.inspect(io)
        io << ", sslrootcert="
        @sslrootcert.inspect(io)
        io << ", sslcert="
        @sslcert.inspect(io)
        io << ", sslkey="
        @sslkey.inspect(io)
        io << ", pool_options="
        @pool_options.inspect(io)
        io << ')'
      end

      private def self.validate_query_params(params : HTTP::Params) : Nil
        seen = Set(String).new
        params.each do |key, _value|
          unless SUPPORTED_QUERY_PARAMS.includes?(key)
            raise ArgumentError.new("unsupported database URL option: #{key}")
          end
          if seen.includes?(key)
            raise ArgumentError.new("database URL option repeated: #{key}")
          end
          seen << key
        end
      end

      private def self.reject_nul(value : String, field : String) : Nil
        if value.includes?('\0')
          raise ArgumentError.new("database URL #{field} must not contain NUL")
        end
      end

      private def self.parse_port(uri : URI, params : HTTP::Params) : Int32
        authority_port = uri.port
        query_port = params["port"]?
        if authority_port && query_port
          parsed_query_port = query_port.to_i
          unless authority_port == parsed_query_port
            raise ArgumentError.new("database URL authority and port option conflict")
          end
        end

        value = authority_port || query_port.try(&.to_i) || 5432
        unless (1..65_535).includes?(value)
          raise ArgumentError.new("database port must be between 1 and 65535")
        end
        value.to_i32
      end

      private def self.parse_sslmode(value : String?, unix_socket : Bool) : Symbol
        if unix_socket
          return :disable if value.nil? || value == "disable"
          raise ArgumentError.new("Unix socket connections must use sslmode=disable")
        end

        return :verify_full if value.nil? || value == "verify-full"
        raise ArgumentError.new("TCP connections require sslmode=verify-full")
      end

      private def self.validate_socket_directory(path : String) : Nil
        unless Path.new(path).absolute?
          raise ArgumentError.new("Unix socket host must be an absolute directory")
        end

        info = File.info?(path, false)
        unless info && info.directory?
          raise ArgumentError.new("Unix socket host must be an existing directory")
        end
        unless info.owner_id == LibC.getuid.to_s
          raise ArgumentError.new("Unix socket directory must belong to the current user")
        end
        if (info.permissions.value & 0o077) != 0
          raise ArgumentError.new("Unix socket directory must not be group- or world-accessible")
        end
      end
    end

    def self.open(url : String, pool_size : Int = Config::DEFAULT_POOL_SIZE) : DB::Database
      config = Config.parse(url, pool_size)
      connection_options = config.connection_options
      database : DB::Database? = nil

      database = DB::Database.new(connection_options, config.pool_options) do
        build_connection(config, connection_options)
      end
      database
    rescue ex
      database.try(&.close)
      raise ex
    end

    private def self.build_connection(config : Config, options : DB::Connection::Options) : PG::Connection
      if config.unix_socket?
        socket = UNIXSocket.new(File.join(config.host, ".s.PGSQL.#{config.port}"))
        socket.sync = false
        socket.read_timeout = IO_TIMEOUT
        socket.write_timeout = IO_TIMEOUT
        connection_from(socket, config, options)
      else
        socket = open_tls_socket(config)
        connection_from(socket, config, options)
      end
    end

    private def self.connection_from(socket : UNIXSocket | OpenSSL::SSL::Socket::Client, config : Config, options : DB::Connection::Options) : PG::Connection
      connection : PG::Connection? = nil
      begin
        pq = PQ::Connection.new(socket, config.conninfo)
        connection = PG::Connection.new(options, pq)
        connection.exec("SET TIME ZONE 'UTC'")
        connection
      rescue ex
        close_failed_connection(connection, socket)
        raise ex
      end
    end

    # DB::Database installs its setup callback after construction. Running the
    # session setup here keeps the connection and transport in one cleanup
    # scope for both initial and lazily-created pool resources.
    private def self.close_failed_connection(connection : PG::Connection?, socket : UNIXSocket | OpenSSL::SSL::Socket::Client) : Nil
      begin
        connection.try(&.close)
      rescue
      ensure
        begin
          socket.close
        rescue
        end
      end
    end

    private def self.open_tls_socket(config : Config) : OpenSSL::SSL::Socket::Client
      socket = TCPSocket.new(
        config.host,
        config.port,
        CONNECT_TIMEOUT_SECONDS,
        CONNECT_TIMEOUT_SECONDS,
      )
      socket.sync = false
      socket.read_timeout = IO_TIMEOUT
      socket.write_timeout = IO_TIMEOUT
      begin
        send_ssl_request(socket)

        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
        context.ca_certificates = config.sslrootcert.not_nil! if config.sslrootcert
        context.certificate_chain = config.sslcert.not_nil! if config.sslcert
        context.private_key = config.sslkey.not_nil! if config.sslkey

        tls_socket = OpenSSL::SSL::Socket::Client.new(
          socket,
          context: context,
          sync_close: true,
          hostname: config.host,
        )
        tls_socket.read_timeout = IO_TIMEOUT
        tls_socket.write_timeout = IO_TIMEOUT
        tls_socket
      rescue ex
        socket.close rescue nil
        raise ex
      end
    end

    private def self.send_ssl_request(socket : TCPSocket) : Nil
      socket.write_bytes(8_i32, IO::ByteFormat::NetworkEndian)
      socket.write_bytes(80877103_i32, IO::ByteFormat::NetworkEndian)
      socket.flush
      response = socket.read_byte
      unless response == 'S'.ord.to_u8
        raise IO::Error.new("PostgreSQL server did not accept TLS")
      end
    end
  end
end
