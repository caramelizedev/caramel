require "html"
require "./process"
require "./server"

module Caramel::Latte
  # The opt-in login item: a per-user LaunchAgent that starts Latte when the
  # user logs in. Without it, Frappé starts Latte when a command needs it.
  class LoginItem
    LABEL = "dev.caramel.latte"

    getter label : String
    getter plist : String

    def initialize(@arguments : Array(String), @label : String = LABEL,
                   directory : String = File.join(Path.home.to_s, "Library/LaunchAgents"))
      @plist = File.join(directory, "#{@label}.plist")
    end

    # Runs `latte daemon --detach` from the checkout of *latte*.
    def self.for_latte(latte : String) : LoginItem
      new([latte, "daemon", "--detach"])
    end

    def domain : String
      "gui/#{LibC.getuid}"
    end

    # RunAtLoad starts Latte at login and when installed. There is no
    # KeepAlive: `latte stop` means stopped, and Frappé restarts Latte on
    # demand after a crash. AbandonProcessGroup keeps launchd from killing
    # Latte's services when the daemon exits, as they survive `latte stop`.
    def render : String
      <<-PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>#{HTML.escape(@label)}</string>
          <key>ProgramArguments</key>
          <array>#{@arguments.map { |argument| "<string>#{HTML.escape(argument)}</string>" }.join}</array>
          <key>RunAtLoad</key><true/>
          <key>AbandonProcessGroup</key><true/>
        </dict>
        </plist>

        PLIST
    end

    # Writes the agent and loads it into this login session, replacing an
    # earlier copy of the same item.
    def install : Nil
      directory = File.dirname(@plist)
      Dir.mkdir_p(directory, 0o755)
      if info = File.info?(@plist, follow_symlinks: false)
        unless info.file? && info.owner_id.to_i64? == LibC.getuid.to_i64
          raise PublicError.new("login_item", "#{@plist} is not a file you own; remove it and try again")
        end
      end
      bootout
      temporary = File.join(directory, ".#{@label}.#{Random::Secure.hex(6)}.tmp")
      begin
        File.write(temporary, render, perm: 0o644)
        File.rename(temporary, @plist)
      ensure
        File.delete?(temporary)
      end
      result = ProcessRunner.run(["/bin/launchctl", "bootstrap", domain, @plist], timeout: 30.seconds)
      unless result.success?
        raise PublicError.new("login_item", "launchctl could not load #{@plist}: #{result.stderr.strip}")
      end
    end

    # Unloads the agent, which ends the daemon it started, and deletes it.
    # Returns false when it was neither loaded nor installed.
    def uninstall : Bool
      loaded = bootout
      present = File.info?(@plist, follow_symlinks: false)
      File.delete(@plist) if present
      loaded || !present.nil?
    end

    private def bootout : Bool
      ProcessRunner.run(["/bin/launchctl", "bootout", "#{domain}/#{@label}"], timeout: 30.seconds).success?
    end
  end
end
