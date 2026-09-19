require "./project"

module Caramel::Frappe
  class DevCommand
    class Output < IO
      getter contents = ""

      def initialize(@forward : IO? = nil)
      end

      def read(slice : Bytes)
        0
      end

      def write(slice : Bytes) : Nil
        @forward.try(&.write(slice))
        @forward.try(&.flush)
        combined = @contents + String.new(slice).scrub
        if combined.bytesize > 32_768
          tail = combined.byte_slice(combined.bytesize - 32_768).scrub
          # A clipped first line might contain only part of a credential,
          # which exact-value redaction could no longer recognize.
          @contents = tail.partition('\n')[2]
        else
          @contents = combined
        end
      end
    end

    getter status : Process::Status? = nil
    getter output : Output
    getter pid : Int64
    @process : Process

    def initialize(command : Array(String), environment : Hash(String, String), directory : String, forward : IO? = nil)
      @output = Output.new(forward)
      launcher = Process.executable_path || raise Error.new("Cannot locate Frappé")
      @process = Process.new(launcher, ["__caramel_dev_child", *command], env: environment, clear_env: true,
        chdir: directory, input: Process::Redirect::Pipe, output: @output, error: @output)
      @pid = @process.pid.to_i64
      spawn { @status = @process.wait }
    end

    def running? : Bool
      @status.nil?
    end

    def request_stop : Nil
      return unless running?
      @process.input.close unless @process.input.closed?
    end

    def stop : Nil
      request_stop
      deadline = Time.instant + 5.seconds
      while running?
        raise Error.new("Development child did not close its owned process group") if Time.instant >= deadline
        sleep 25.milliseconds
      end
    end
  end
end
