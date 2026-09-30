require "./project"

module Caramel::Frappe
  class DevCommand
    class Output < IO
      getter contents = ""
      # A quiet start forwards nothing until the command proves healthy.
      setter forward : IO?
      setter log : IO?

      def initialize(@forward : IO? = nil, @log : IO? = nil)
      end

      def read(slice : Bytes)
        0
      end

      def write(slice : Bytes) : Nil
        @forward.try(&.write(slice))
        @forward.try(&.flush)
        @log.try(&.write(slice))
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

    # The compiler's standard output under `--stats`. Stage timings and the
    # macro and object reuse reports stop here; any other line, such as a
    # macro's `puts`, goes on to the command's output. `checked` closes when
    # the last semantic stage completes: the type check passed and code
    # generation starts.
    class Stages < IO
      STAGE   = /\A(?:Parse|Semantic \([^)]*\)|Codegen \([^)]*\)|dsymutil):\s*/
      TIMING  = /\A\d+:\d\d:\d\d(?:\.\d+)? \(\s*[\d.]+MB\)\z/
      CHECKED = /\ASemantic \(recursive struct check\):\s+\d/
      REPORTS = ["Macro runs:", "Codegen (bc+obj):", "These modules were not reused:"]

      getter? checked = false
      @line = ""
      @report = false

      def initialize(@output : Output, @passed : Channel(Nil))
      end

      def read(slice : Bytes)
        0
      end

      def write(slice : Bytes) : Nil
        @line += String.new(slice).scrub
        while index = @line.index('\n')
          pass(@line[0, index])
          @line = @line[(index + 1)..]
        end
      end

      private def pass(line : String) : Nil
        if REPORTS.includes?(line) || (@report && line.starts_with?(" - "))
          @report = true
          return
        end
        @report = false
        kept = line.split('\r').reject do |segment|
          stage = stage?(segment)
          notify if stage && segment.matches?(CHECKED)
          stage
        end
        text = kept.join('\r')
        @output.write("#{text}\n".to_slice) unless text.strip.empty?
      end

      # A stage's padded name, alone as the stage starts or with its time and
      # memory once it completes.
      private def stage?(segment : String) : Bool
        name = segment.match(STAGE) || return false
        rest = segment[name.end..]
        rest.empty? || rest.matches?(TIMING)
      end

      private def notify : Nil
        return if @checked
        @checked = true
        @passed.close
      end
    end

    getter status : Process::Status? = nil
    getter output : Output
    # Closed when the command exits, so a waiter wakes at once.
    getter finished = Channel(Nil).new
    # With stages, closed once the build's type check passes.
    getter checked = Channel(Nil).new
    getter pid : Int64
    @process : Process
    @stages : Stages? = nil

    # With *stages*, the command is a `--stats` build whose stage lines are
    # read, not shown.
    def initialize(command : Array(String),
                   environment : Hash(String, String),
                   directory : String,
                   forward : IO? = nil,
                   log : IO? = nil,
                   *,
                   stages : Bool = false)
      @output = Output.new(forward, log)
      output = stages ? Stages.new(@output, @checked).tap { |filter| @stages = filter } : @output
      launcher = Process.executable_path || raise Error.new("Cannot locate Frappé")
      @process = Process.new(launcher, ["__caramel_dev_child", *command],
        env: environment,
        clear_env: true,
        chdir: directory,
        input: Process::Redirect::Pipe,
        output: output,
        error: @output)
      @pid = @process.pid.to_i64
      spawn do
        @status = @process.wait
        @finished.close
      end
    end

    # Whether the build reported that its type check passed.
    def checked? : Bool
      @stages.try(&.checked?) || false
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
      select
      when @finished.receive?
      when timeout(5.seconds)
        raise Error.new("Development child did not close its owned process group") if running?
      end
    end
  end
end
