require "./latte/daemon"
require "./latte/login_item"
require "./latte/trust"
require "./latte/control_api"
require "./latte/installed_releases"

# Names the rescued errors below. A rescue of an alias for a union of
# exception types would catch every exception, so this aliases the namespace.
alias Latte = Caramel::Latte

begin
  case ARGV
  when ["daemon"], ["daemon", "--detach"]
    paths = Caramel::Latte::Paths.new
    # One Latte, the newest installed (ADR 0016): however this daemon was
    # started, an older release hands over to the newest release's latte.
    if newer = Caramel::Latte::InstalledReleases.newer_latte(paths.root, Caramel::VERSION)
      Process.exec(newer, ARGV)
    end
    # Detach first, so every later failure reaches logs/latte.log.
    Caramel::Latte::Daemon.detach(paths) if ARGV[1]? == "--detach"
    registry = Caramel::Latte::Registry.new(paths)
    Caramel::Latte::Daemon.new(registry, Caramel::Latte::Supervisor.new(registry)).run
  when ["stop"]
    stopped = Caramel::Latte::Daemon.stop(Caramel::Latte::Paths.new)
    if stopped
      puts "Latte stopped; its services were left as they were " \
           "(frappe services stop stops them)."
    else
      puts "Latte is not running."
    end
  when ["service", "install"]
    paths = Caramel::Latte::Paths.new
    # The login item runs the newest installed release's Latte (ADR 0016).
    newest = Caramel::Latte::InstalledReleases.newer_latte(paths.root, Caramel::VERSION)
    missing = "Cannot locate this latte executable"
    latte = newest || Process.executable_path ||
            raise Caramel::Latte::PublicError.new("login_item", missing)
    item = Caramel::Latte::LoginItem.for_latte(latte)
    # The login item's daemon takes over from one Frappé started.
    Caramel::Latte::Daemon.stop(paths)
    item.install
    deadline = Time.instant + 30.seconds
    until Caramel::Latte::Daemon.running?(paths)
      if Time.instant >= deadline
        log = File.join(paths.logs_dir, Caramel::Latte::Paths::DAEMON_LOG)
        message = "The login item did not start Latte; see #{log}"
        raise Caramel::Latte::PublicError.new("login_item", message)
      end
      sleep 100.milliseconds
    end
    puts "Latte now starts when you log in (#{item.plist}), and is running."
  when ["service", "uninstall"]
    item = Caramel::Latte::LoginItem.new([] of String)
    if item.uninstall
      puts "Latte no longer starts at login; the Latte it started has stopped. " \
           "Services keep running, and Frappé starts Latte when a command needs it."
    else
      puts "The Latte login item is not installed."
    end
  when ["trust", "install"], ["trust", "remove"]
    registry = Caramel::Latte::Registry.new
    trust = Caramel::Latte::Trust.new(registry.paths, Caramel::Latte::Proxy.new(registry))
    ARGV[1] == "install" ? trust.install : trust.remove
    puts "Latte certificate trust #{ARGV[1] == "install" ? "installed" : "removed"}."
  when ["version"], ["--version"]
    versions = Caramel::Latte::ControlAPI::VERSIONS.join(", ")
    puts "Latte #{Caramel::VERSION} (control API #{versions})"
  when ["--help"], ["help"], [] of String
    puts <<-TEXT
      Latte — Caramel's local environment
      Usage: latte daemon [--detach] | stop | service install | service uninstall | \
        trust install | trust remove | version
        daemon             Run Latte in this terminal.
        daemon --detach    Run Latte in its own session, logging to logs/latte.log. \
          Frappé starts Latte this way when it is not running.
        stop               Stop the running Latte. Services keep running.
        service install    Start Latte whenever you log in (a per-user login item), and now.
        service uninstall  Remove that login item; the Latte it started stops.
        version            Print this Latte's release and the control API versions it serves.
      Start and inspect services from Latte in the menu bar or with Frappé.
      TEXT
  else
    STDERR.puts "Unknown command. Use latte --help."
    exit 2
  end
rescue ex : Latte::PublicError | Latte::Toolchain::Unavailable | Latte::StateFormat::Newer
  STDERR.puts ex.message
  exit 1
rescue ex
  STDERR.puts "Latte could not start (#{ex.class}). " \
              "Check the managed toolchain and private state directory."
  exit 1
end
