require "json"
require "file_utils"
require "socket"
require "http/client"
require "digest/sha256"
require "../../../src/latte/process"
require "../../../src/latte/paths"
require "../../../src/latte/toolchain"

module Caramel::Checks
  REPO = File.expand_path("../../..", __DIR__)

  # A check and every tool it starts use one toolchain, resolved the way
  # Frappé resolves it: CARAMEL_TOOLCHAIN_ROOT, else .caramel-toolchain.
  if located = Caramel::Latte::Toolchain.locate(REPO)
    ENV["CARAMEL_TOOLCHAIN_ROOT"] = located[0]
  end

  def self.run(argv : Array(String), *, chdir : String = REPO, env : Hash(String, String?)? = nil, clear_env : Bool = false, input : String? = nil, timeout : Time::Span = 90.seconds) : Caramel::Latte::ProcessResult
    Caramel::Latte::ProcessRunner.run(argv, chdir: chdir, env: env, clear_env: clear_env, input: input, timeout: timeout, output_limit: 16 * 1024 * 1024)
  end

  def self.crystal(args : Array(String), **options)
    run([File.join(REPO, "scripts/crystal")] + args, **options)
  end

  def self.shards(args : Array(String), **options)
    run([File.join(REPO, "scripts/shards")] + args, **options)
  end

  def self.fail(message : String) : NoReturn
    STDERR.puts message
    exit 1
  end

  def self.toolchain_root : String
    root = ENV["CARAMEL_TOOLCHAIN_ROOT"]?
    return root if root && !root.empty?
    fail("No Caramel toolchain is installed for #{REPO}. Run scripts/install-toolchain.")
  end

  def self.private_temp(prefix : String) : String
    path = File.tempname(prefix, dir: "/private/tmp")
    Dir.mkdir(path, 0o700)
    path
  end

  def self.runtime_root(state_root : String) : String
    Caramel::Latte::StateSecurity.runtime_root(File.realpath(state_root))
  end

  def self.free_tcp_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.port
  ensure
    server.try &.close
  end

  def self.free_udp_port : Int32
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    socket.local_address.port
  ensure
    socket.try &.close
  end

  def self.wait_until(timeout : Time::Span, interval : Time::Span, & : -> Bool) : Bool
    deadline = Time.instant + timeout
    loop do
      return true if yield
      return false if Time.instant >= deadline
      sleep interval
    end
  end

  def self.stop(process : Process, grace : Time::Span = 5.seconds) : Nil
    unless process.terminated?
      process.terminate
      unless wait_until(grace, 50.milliseconds) { process.terminated? }
        process.terminate(graceful: false)
      end
    end
    process.wait
  rescue
    begin
      process.terminate(graceful: false)
      process.wait
    rescue
    end
  end

  def self.gone?(pid : Int64) : Bool
    result = run(["/bin/ps", "-p", pid.to_s, "-o", "stat="], timeout: 5.seconds)
    state = result.stdout.strip
    state.empty? || state.starts_with?('Z')
  end
end
