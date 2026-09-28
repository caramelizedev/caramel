require "set"
require "./dev_command"

module Caramel::Frappe
  # Retired commands remain owned until termination and cleanup finish. Waiting
  # happens at shutdown, not on the path to compiling the next edit.
  class DevRetirement
    @pending = Set(DevCommand).new
    @failures = [] of Exception

    def empty? : Bool
      @pending.empty?
    end

    def retire(command : DevCommand, &cleanup : -> Nil) : Nil
      raise Error.new("Development command is already retiring") if @pending.includes?(command)
      @pending.add(command)
      command.request_stop
      spawn do
        command.stop
        cleanup.call
      rescue ex
        @failures << ex
      ensure
        @pending.delete(command) unless command.running?
      end
    end

    def check! : Nil
      if failure = @failures.first?
        raise failure
      end
    end

    def drain : Nil
      @pending.to_a.each(&.request_stop)
      deadline = Time.instant + 10.seconds
      until @pending.empty?
        raise Error.new("Retired development commands did not finish cleanup") if Time.instant >= deadline
        sleep 25.milliseconds
      end
      check!
    end
  end
end
