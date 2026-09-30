require "spec"
require "file_utils"
require "uri"
require "../../src/caramel/database"

private def private_socket_directory
  path = File.join(Dir.tempdir, "caramel-db-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(path, 0o700)
  path
end

private def remove_directory(path : String)
  Dir.delete(path) if Dir.exists?(path)
end

describe Caramel::Database::Config do
  it "requires verified TLS for TCP and creates a bounded pool" do
    config = Caramel::Database::Config.parse(
      "postgresql://alice:secret@db.example.test/books?sslrootcert=%2Fetc%2Fcaramel%2Fca.pem"
    )

    config.host.should eq("db.example.test")
    config.port.should eq(5432)
    config.database.should eq("books")
    config.user.should eq("alice")
    config.password.should eq("secret")
    config.sslmode.should eq(:verify_full)
    config.unix_socket?.should be_false
    config.pool_options.initial_pool_size.should eq(1)
    config.pool_options.max_pool_size.should eq(4)
    config.pool_options.max_idle_pool_size.should eq(4)
    config.pool_options.retry_attempts.should eq(0)
    config.sslrootcert.should eq("/etc/caramel/ca.pem")
  end

  it "decodes URI credentials and database names exactly once" do
    config = Caramel::Database::Config.parse(
      "postgresql://alice%40example:pa%24ss@db.example.test/books%20archive"
    )

    config.user.should eq("alice@example")
    config.password.should eq("pa$ss")
    config.database.should eq("books archive")
  end

  it "rejects decoded NUL bytes from identities, host, database and certificate paths" do
    urls = [
      "postgresql://ali%00ce:sensitive@db.example.test/books",
      "postgresql://alice:sens%00itive@db.example.test/books",
      "postgresql://alice:sensitive@db%00.example.test/books",
      "postgresql://alice:sensitive@db.example.test/books%00archive",
      "postgresql://alice:sensitive@/books?host=db.example.test%00suffix",
      "postgresql://alice:sensitive@db.example.test/books?sslrootcert=%2Ftmp%2Fsensitive%00ca.pem",
      "postgresql://alice:sensitive@db.example.test/books?sslcert=%2Ftmp%2Fsensitive%00cert.pem",
      "postgresql://alice:sensitive@db.example.test/books?sslkey=%2Ftmp%2Fsensitive%00key.pem",
    ]

    urls.each do |url|
      error = expect_raises(ArgumentError) do
        Caramel::Database::Config.parse(url)
      end
      message = error.message.not_nil!
      message.should_not contain("sensitive")
      message.should_not contain("\0")
    end
  end

  it "redacts the password from inspection" do
    config = Caramel::Database::Config.parse("postgresql://alice:secret@db.example.test/books")
    config.inspect.should_not contain("secret")
  end

  it "accepts an explicit pool bound from one through thirty two" do
    url = "postgresql://alice:secret@db.example.test/books"
    config = Caramel::Database::Config.parse(url, pool_size: 7)

    config.pool_options.initial_pool_size.should eq(1)
    config.pool_options.max_pool_size.should eq(7)
    config.pool_options.max_idle_pool_size.should eq(7)

    expect_raises(ArgumentError) { Caramel::Database::Config.parse(url, pool_size: 0) }
    expect_raises(ArgumentError) { Caramel::Database::Config.parse(url, pool_size: 33) }
  end

  it "rejects conflicting authority/query addresses and URL fragments" do
    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse(
        "postgresql://alice:secret@db.example.test/books?host=other.example.test"
      )
    end

    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse(
        "postgresql://alice:secret@db.example.test:5432/books?port=55432"
      )
    end

    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse(
        "postgresql://alice:secret@db.example.test/books#fragment"
      )
    end
  end

  it "rejects missing identity, database and host instead of reading PG defaults" do
    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse("postgresql:///books?host=db.example.test")
    end

    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse("postgresql://alice:secret@db.example.test/")
    end

    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse("postgresql://alice:secret@/books")
    end
  end

  it "rejects downgradeable TLS modes and unknown query options" do
    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse(
        "postgresql://alice:secret@db.example.test/books?sslmode=require"
      )
    end

    expect_raises(ArgumentError) do
      Caramel::Database::Config.parse(
        "postgresql://alice:secret@db.example.test/books?unknown=option"
      )
    end
  end

  it "uses an explicit empty password for private Unix sockets and validates privacy" do
    socket_dir = private_socket_directory
    begin
      config = Caramel::Database::Config.parse(
        "postgresql://caramel:@/books?host=#{URI.encode_path(socket_dir)}&port=55439"
      )

      config.host.should eq(socket_dir)
      config.port.should eq(55439)
      config.password.should eq("")
      config.sslmode.should eq(:disable)
      config.unix_socket?.should be_true
    ensure
      remove_directory(socket_dir)
    end
  end

  it "rejects insecure or foreign Unix socket directories" do
    insecure = private_socket_directory
    begin
      File.chmod(insecure, 0o755)
      expect_raises(ArgumentError) do
        Caramel::Database::Config.parse(
          "postgresql://caramel:@/books?host=#{URI.encode_path(insecure)}"
        )
      end
    ensure
      remove_directory(insecure)
    end
  end
end
