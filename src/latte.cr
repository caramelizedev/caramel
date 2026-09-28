require "./latte/daemon"
require "./latte/login_item"
require "./latte/trust"

begin
  case ARGV
  when ["daemon"], ["daemon", "--detach"]
    registry = Caramel::Latte::Registry.new
    Caramel::Latte::Daemon.detach(registry.paths) if ARGV[1]? == "--detach"
    Caramel::Latte::Daemon.new(registry, Caramel::Latte::Supervisor.new(registry)).run
  when ["stop"]
    stopped = Caramel::Latte::Daemon.stop(Caramel::Latte::Paths.new)
    puts stopped ? "Latte stopped. Services keep running; frappe services stop stops them." : "Latte is not running."
  when ["service", "install"]
    latte = Process.executable_path || raise Caramel::Latte::PublicError.new("login_item", "Cannot locate this latte executable")
    paths = Caramel::Latte::Paths.new
    item = Caramel::Latte::LoginItem.for_latte(latte)
    # The login item's daemon takes over from one Frappé started.
    Caramel::Latte::Daemon.stop(paths)
    item.install
    deadline = Time.instant + 30.seconds
    until Caramel::Latte::Daemon.running?(paths)
      if Time.instant >= deadline
        raise Caramel::Latte::PublicError.new("login_item", "The login item did not start Latte; see #{File.join(paths.logs_dir, Caramel::Latte::Paths::DAEMON_LOG)}")
      end
      sleep 100.milliseconds
    end
    puts "Latte now starts when you log in (#{item.plist}), and is running."
  when ["service", "uninstall"]
    item = Caramel::Latte::LoginItem.new([] of String)
    if item.uninstall
      puts "Latte no longer starts at login; the Latte it started has stopped. Services keep running, and Frappé starts Latte when a command needs it."
    else
      puts "The Latte login item is not installed."
    end
  when ["trust", "install"], ["trust", "remove"]
    registry = Caramel::Latte::Registry.new
    trust = Caramel::Latte::Trust.new(registry.paths, Caramel::Latte::Proxy.new(registry))
    ARGV[1] == "install" ? trust.install : trust.remove
    puts "Latte certificate trust #{ARGV[1] == "install" ? "installed" : "removed"}."
  when ["--help"], ["help"], [] of String
    puts "Latte — Caramel's local environment"
    puts "Usage: latte daemon [--detach] | stop | service install | service uninstall | trust install | trust remove"
    puts "  daemon             Run Latte in this terminal."
    puts "  daemon --detach    Run Latte in its own session, logging to logs/latte.log. Frappé starts Latte this way when it is not running."
    puts "  stop               Stop the running Latte. Services keep running."
    puts "  service install    Start Latte whenever you log in (a per-user login item), and now."
    puts "  service uninstall  Remove that login item; the Latte it started stops."
    puts "Start and inspect services from Latte in the menu bar or with Frappé."
  else
    STDERR.puts "Unknown command. Use latte --help."
    exit 2
  end
rescue ex : Caramel::Latte::PublicError | Caramel::Latte::Toolchain::Unavailable
  STDERR.puts ex.message
  exit 1
rescue ex
  STDERR.puts "Latte could not start (#{ex.class}). Check the managed toolchain and private state directory."
  exit 1
end
