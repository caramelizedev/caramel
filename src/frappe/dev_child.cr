require "c/unistd"
require "c/signal"

lib CaramelDevNative
  fun setsid : LibC::PidT
end

module Caramel::Frappe
  # The parent owns a pipe, not a persisted PID. EOF (including a killed
  # terminal owner) cancels this isolated session and all of its descendants.
  # This internal runner never signals an existing/recovered process group.
  module DevChild
    def self.run(args : Array(String)) : Int32
      return 2 if args.empty?
      group = CaramelDevNative.setsid
      raise "Could not isolate development child" unless group == Process.pid
      events = Channel(Process::Status?).new(3)
      Process.on_terminate { events.send(nil) }
      child = Process.new(args.first, args[1..], input: Process::Redirect::Close,
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      spawn { events.send(child.wait) }
      spawn do
        STDIN.read_byte
        events.send(nil)
      rescue IO::Error
        events.send(nil)
      end
      status = events.receive
      Signal::TERM.ignore
      Signal::INT.ignore
      LibC.kill(-group, Signal::TERM.value)
      if status
        sleep 50.milliseconds
        status.normal_exit? ? status.exit_code : 1
      else
        # Keep the group leader alive until escalation so its ID cannot be
        # reused. SIGKILL includes this helper and stubborn grandchildren.
        sleep 1.second
        LibC.kill(-group, Signal::KILL.value)
        1
      end
    end
  end
end
