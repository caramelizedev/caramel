require "digest/sha256"
require "json"
require "random/secure"
require "c/unistd"
require "./deadline"

module Caramel::Latte
  # A bounded result for commands launched by Latte. Command arguments and
  # environment values are intentionally not included in diagnostics because
  # they can contain database credentials.
  struct ProcessResult
    getter status : Process::Status
    getter stdout : String
    getter stderr : String
    getter timed_out : Bool

    def initialize(@status : Process::Status, @stdout : String, @stderr : String, @timed_out : Bool = false)
    end

    def success? : Bool
      @status.success? && !@timed_out
    end

    def diagnostic : String
      if @timed_out
        "managed command exceeded its deadline"
      elsif @status.success?
        "managed command completed"
      else
        # Command output can echo SQL, URLs, role names, or credentials. Keep
        # it available to the caller that deliberately requested stdout/stderr
        # while exposing only a stable status in exceptions and service state.
        "managed command exited with status #{@status.exit_code}"
      end
    end
  end

  class ProcessFailure < Exception
    getter result : ProcessResult

    def initialize(@result : ProcessResult)
      super(@result.diagnostic)
    end
  end

  # Runs an argv vector without a shell, captures output through private
  # bounded sinks, and always enforces an outer wall-clock deadline.
  module ProcessRunner
    MAX_OUTPUT_BYTES = 64 * 1024

    # Process output is drained continuously so a noisy command cannot block
    # on a full pipe. Bytes beyond the diagnostic limit are discarded while
    # the retained prefix stays in memory; no unbounded temporary output file
    # is created.
    private class BoundedOutput < IO
      getter truncated : Bool

      def initialize(@limit : Int32)
        @data = IO::Memory.new
        @truncated = false
      end

      def read(slice : Bytes)
        0
      end

      def write(slice : Bytes) : Nil
        remaining = @limit - @data.size
        if remaining > 0
          amount = Math.min(remaining, slice.size)
          @data.write(slice[0, amount])
          @truncated = true if amount < slice.size
        else
          @truncated = true unless slice.empty?
        end
      end

      def contents : String
        @data.to_s
      end
    end

    def self.run(
      argv : Enumerable(String),
      *,
      input : String? = nil,
      env : Hash(String, String?)? = nil,
      clear_env : Bool = false,
      chdir : String? = nil,
      timeout : Time::Span = 30.seconds,
      output_limit : Int32 = MAX_OUTPUT_BYTES,
    ) : ProcessResult
      timeout = OperationDeadline.limit(timeout)
      command = argv.to_a
      raise ArgumentError.new("managed command must not be empty") if command.empty?
      raise ArgumentError.new("managed command output limit must be positive") unless output_limit > 0
      raise ArgumentError.new("managed command deadline must be positive") unless timeout > Time::Span.zero

      output_capture = BoundedOutput.new(output_limit)
      error_capture = BoundedOutput.new(output_limit)
      input_file : File? = nil
      input_path : String? = nil
      process : Process? = nil
      begin
        if input
          input_file = File.tempfile("caramel-latte-in", ".sql", dir: Dir.tempdir)
          input_path = input_file.not_nil!.path
          input_file.not_nil!.chmod(0o600)
          input_file.not_nil! << input
          input_file.not_nil!.flush
          input_file.not_nil!.rewind
        end

        # File staging is part of this command's launch budget too; refresh
        # the outer operation's remaining time immediately before spawning.
        timeout = OperationDeadline.limit(timeout)
        process = Process.new(
          command,
          env: env,
          clear_env: clear_env,
          input: input_file || Process::Redirect::Close,
          output: output_capture,
          error: error_capture,
          chdir: chdir,
        )
        input_file.try(&.close)
        input_file = nil

        completion = Channel({Process::Status?, Exception?}).new(1)
        child = process.not_nil!
        spawn do
          begin
            completion.send({child.wait, nil})
          rescue ex
            completion.send({nil, ex})
          end
        end

        timed_out = false
        event = select
        when item = completion.receive
          item
        when timeout(timeout)
          timed_out = true
          OperationDeadline.without do
            begin
              # A command used for startup/readiness must not outlive its owner.
              # The final signal is intentionally unconditional after the
              # deadline; identity checks are required for managed long-lived
              # children before this runner is used to stop them.
              child.terminate(graceful: false)
            rescue
            end
            select
            when item = completion.receive
              item
            when timeout(2.seconds)
              # SIGKILL should reap a native command promptly. Keep this outer
              # wait bounded as well if the platform cannot report its status.
              {Process::Status[124], nil}
            end
          end
        end

        status, exception = event
        raise exception.not_nil! if exception
        ProcessResult.new(status.not_nil!, output_capture.contents, error_capture.contents, timed_out)
      rescue ex : ProcessFailure
        raise ex
      ensure
        input_file.try(&.close)
        if input_file
          begin
            File.delete(input_path.not_nil!) if input_path && File.exists?(input_path.not_nil!)
          rescue
          end
        elsif input_path
          begin
            File.delete(input_path.not_nil!) if File.exists?(input_path.not_nil!)
          rescue
          end
        end
      end
    end

    def self.run!(*args, **options) : ProcessResult
      result = run(*args, **options)
      raise ProcessFailure.new(result) unless result.success?
      result
    end
  end

  class OwnershipError < Exception
  end

  # Record and lifecycle boundary for a long-lived child owned by Latte. The
  # record is deliberately small and private; a later supervisor can adopt a
  # child only after checking both the PID owner and its command line.
  class ManagedChild
    PROCESS_LISTING_LIMIT = 1024 * 1024

    struct Identity
      include JSON::Serializable

      getter name : String
      getter pid : Int64
      getter executable : String
      getter argument_digest : String
      getter owner_token : String
      getter start_time : String

      def initialize(@name : String, @pid : Int64, @executable : String, @argument_digest : String, @owner_token : String, @start_time : String)
      end
    end

    getter name : String
    getter executable : String
    getter args : Array(String)
    getter record_path : String
    getter log_path : String
    @process : Process?

    def initialize(
      name : String,
      executable : String,
      args : Enumerable(String),
      record_path : String,
      log_path : String,
      environment : Hash(String, String?)? = nil,
      working_directory : String? = nil,
    )
      @name = name
      @executable = ""
      @args = args.to_a
      @record_path = record_path
      @log_path = log_path
      @environment = environment
      @working_directory = working_directory
      @process = nil
      @executable = begin
        File.realpath(executable)
      rescue ex : File::Error
        raise ArgumentError.new("managed child executable is unavailable")
      end
      ensure_private_parent(@record_path)
      ensure_private_parent(@log_path)
    end

    def identity : Identity?
      return nil unless File.exists?(@record_path)
      info = File.info(@record_path, follow_symlinks: false)
      raise OwnershipError.new("managed process record is a symlink") if info.symlink?
      raise OwnershipError.new("managed process record is not a regular file") unless info.file?
      raise OwnershipError.new("managed process record has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
      raise OwnershipError.new("managed process record must be private") if (info.permissions.value & 0o077) != 0
      Identity.from_json(File.read(@record_path))
    rescue JSON::ParseException
      raise OwnershipError.new("managed process record is corrupt; it was preserved")
    end

    def running? : Bool
      saved = identity
      return false unless saved
      verify_identity(saved)
    end

    def start(timeout : Time::Span = 10.seconds) : Identity
      if saved = identity
        if verify_identity(saved)
          return saved
        elsif Process.exists?(saved.pid)
          raise OwnershipError.new("managed process PID is live but does not match its owner record")
        else
          File.delete(@record_path)
        end
      end

      prepare_log_file!

      # A crash can occur after the child is launched but before the atomic
      # record rename. Recover only an unambiguous process owned by this user
      # whose full executable/argv identity matches this child. A missing
      # match or more than one match fails closed and leaves the existing
      # processes untouched.
      if adopted = adopt_existing_identity
        write_identity(adopted)
        return adopted
      end

      owner_token = Random::Secure.hex(24)
      output = File.open(@log_path, "a", 0o600)
      child : Process? = nil
      begin
        child = Process.new([@executable, *@args], env: @environment, output: output, error: output, chdir: @working_directory)
        snapshot = process_snapshot(child.not_nil!.pid)
        raise ProcessFailure.new(ProcessResult.new(Process::Status[1], "", "managed child exited before identity could be recorded")) unless snapshot
        uid, start_time, command_line = snapshot.not_nil!
        unless uid == LibC.getuid.to_i64 && command_line == expected_command
          raise ProcessFailure.new(ProcessResult.new(Process::Status[1], "", "managed child identity did not match its launch command"))
        end
        identity = Identity.new(@name, child.not_nil!.pid, @executable, digest_args(@args), owner_token, start_time)
        write_identity(identity)
        @process = child
        wait_for_start(child.not_nil!, timeout)
        identity
      rescue ex
        begin
          if failed_child = child
            failed_child.terminate(graceful: false)
            failed_child.wait
          end
        rescue
        end
        raise ex
      ensure
        output.close unless output.closed?
      end
    end

    def stop(timeout : Time::Span = 10.seconds) : Bool
      saved = identity
      return false unless saved
      unless verify_identity(saved)
        raise OwnershipError.new("refusing to stop an unverified managed PID")
      end

      child = @process
      if child
        begin
          child.not_nil!.terminate
        rescue
          # The child may have exited between identity verification and the
          # signal. Its wait below still reaps it and proves that outcome.
        end
        return stop_owned_child(child.not_nil!, saved, timeout)
      else
        begin
          Process.signal(Signal::TERM, saved.pid)
        rescue ex
          raise OwnershipError.new("could not signal the verified managed process: #{ex.message}")
        end
        wait_for_exit(saved.pid, timeout)
      end

      unless Process.exists?(saved.pid)
        File.delete(@record_path) if File.exists?(@record_path)
        @process = nil
        return true
      end

      # Re-check identity immediately before escalation so a reused PID can
      # never receive a signal from an old record.
      raise OwnershipError.new("managed process did not stop before its deadline") unless verify_identity(saved)
      begin
        Process.signal(Signal::KILL, saved.pid)
      rescue ex
        raise OwnershipError.new("could not terminate the verified managed process: #{ex.message}")
      end
      wait_for_exit(saved.pid, 2.seconds)
      raise OwnershipError.new("managed process remains after termination") if Process.exists?(saved.pid)
      File.delete(@record_path) if File.exists?(@record_path)
      @process = nil
      true
    end

    def restart(timeout : Time::Span = 10.seconds) : Identity
      stop(timeout) if identity
      start(timeout)
    end

    private def write_identity(value : Identity) : Nil
      if info = File.info?(@record_path, follow_symlinks: false)
        raise OwnershipError.new("managed process record is a symlink") if info.symlink?
        raise OwnershipError.new("managed process record is not a regular file") unless info.file?
        raise OwnershipError.new("managed process record has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
        raise OwnershipError.new("managed process record must be private") if (info.permissions.value & 0o077) != 0
      end
      temporary = File.tempfile("caramel-process-record", ".tmp", dir: File.dirname(@record_path))
      begin
        temporary.chmod(0o600)
        temporary << value.to_json
        temporary << '\n'
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, @record_path)
      ensure
        temporary.close unless temporary.closed?
        File.delete(temporary.path) if File.exists?(temporary.path)
      end
    end

    private def verify_identity(saved : Identity) : Bool
      return false unless saved.name == @name && saved.executable == @executable
      return false unless saved.argument_digest == digest_args(@args)
      return false unless Process.exists?(saved.pid)
      snapshot = process_snapshot(saved.pid)
      return false unless snapshot
      uid, start_time, command_line = snapshot.not_nil!
      return false unless uid == LibC.getuid.to_i64 && start_time == saved.start_time
      command_line == expected_command
    rescue
      false
    end

    private def process_snapshot(pid : Int64) : {Int64, String, String}?
      ps = if File.exists?("/bin/ps")
             "/bin/ps"
           else
             "/usr/bin/ps"
           end
      result = ProcessRunner.run([ps, "-ww", "-p", pid.to_s, "-o", "uid=,lstart=,command="], timeout: 2.seconds, output_limit: 16 * 1024)
      return nil unless result.success?
      fields = result.stdout.strip.split(/\s+/, 7)
      return nil if fields.size < 7
      uid = fields[0].to_i64?
      return nil unless uid
      start_time = fields[1, 5].join(" ")
      command_line = fields[6]
      {uid, start_time, command_line}
    end

    private def adopt_existing_identity : Identity?
      ps = if File.exists?("/bin/ps")
             "/bin/ps"
           else
             "/usr/bin/ps"
           end
      # Keep the listing bounded by selecting only the executable name. Full
      # argv is fetched for the small candidate set below and compared exactly
      # before a process can be adopted.
      result = ProcessRunner.run([ps, "-ww", "-U", LibC.getuid.to_s, "-o", "uid=,pid=,comm="], timeout: 2.seconds, output_limit: PROCESS_LISTING_LIMIT)
      return nil unless result.success?
      raise OwnershipError.new("process listing exceeded 1 MiB; refusing to guess managed child ownership") if result.stdout.bytesize >= PROCESS_LISTING_LIMIT
      candidates = [] of Int64
      result.stdout.each_line do |line|
        fields = line.strip.split(/\s+/, 3)
        next if fields.size < 3
        uid = fields[0].to_i64?
        pid = fields[1].to_i64?
        next unless uid && pid && uid == LibC.getuid.to_i64 && pid > 1
        executable_name = fields[2]
        expected_name = File.basename(@executable)
        candidates << pid if executable_name == @executable || File.basename(executable_name) == expected_name
      end
      raise OwnershipError.new("multiple unrecorded managed children match this identity") if candidates.size > 1
      return nil unless candidates.size == 1
      pid = candidates.first
      snapshot = process_snapshot(pid)
      return nil unless snapshot
      uid, start_time, command_line = snapshot.not_nil!
      return nil unless uid == LibC.getuid.to_i64 && command_line == expected_command
      Identity.new(@name, pid, @executable, digest_args(@args), Random::Secure.hex(24), start_time)
    rescue ex : OwnershipError
      raise ex
    rescue
      nil
    end

    private def wait_for_start(child : Process, timeout : Time::Span) : Nil
      # Identity is the supervisor boundary; service readiness has its own
      # bounded probe. Do not wait for a long lifecycle timeout while a child
      # remains alive after its exact command identity was recorded.
      _ = timeout
      if child.terminated? || !Process.exists?(child.pid)
        raise ProcessFailure.new(ProcessResult.new(Process::Status[1], "", "managed child exited before readiness"))
      end
    end

    private def wait_for_exit(pid : Int64, timeout : Time::Span) : Nil
      deadline = Time.instant + timeout
      while Process.exists?(pid) && Time.instant < deadline
        sleep 20.milliseconds
      end
    end

    private def stop_owned_child(child : Process, saved : Identity, timeout : Time::Span) : Bool
      completion = child_wait_channel(child)
      if receive_child(completion, timeout)
        File.delete(@record_path) if File.exists?(@record_path)
        @process = nil
        return true
      end

      # Re-check identity immediately before escalation so a reused PID can
      # never receive a signal from an old record.
      raise OwnershipError.new("managed process did not stop before its deadline") unless verify_identity(saved)
      begin
        child.terminate(graceful: false)
      rescue ex
        raise OwnershipError.new("could not terminate the verified managed process: #{ex.message}")
      end
      raise OwnershipError.new("managed process remains after termination") unless receive_child(completion, 2.seconds)
      File.delete(@record_path) if File.exists?(@record_path)
      @process = nil
      true
    end

    private def child_wait_channel(child : Process) : Channel({Process::Status?, Exception?})
      completion = Channel({Process::Status?, Exception?}).new(1)
      spawn do
        begin
          completion.send({child.wait, nil})
        rescue ex
          completion.send({nil, ex})
        end
      end
      completion
    end

    private def receive_child(completion : Channel({Process::Status?, Exception?}), timeout : Time::Span) : Bool
      event = select
      when item = completion.receive
        status, exception = item
        raise exception.not_nil! if exception
        status
        true
      when timeout(timeout)
        false
      end
    end

    private def digest_args(arguments : Array(String)) : String
      Digest::SHA256.hexdigest(arguments.join("\0"))
    end

    private def expected_command : String
      [@executable, *@args].join(" ")
    end

    private def ensure_private_parent(path : String) : Nil
      parent = File.dirname(path)
      begin
        Dir.mkdir_p(parent, mode: 0o700)
        info = File.info(parent, follow_symlinks: false)
        raise OwnershipError.new("managed process parent is a symlink") if info.symlink?
        raise OwnershipError.new("managed process parent is not a directory") unless info.directory?
        raise OwnershipError.new("managed process parent has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
        raise OwnershipError.new("managed process parent must be private") if (info.permissions.value & 0o077) != 0
        File.chmod(parent, 0o700) if info.permissions.value != 0o700
      rescue ex
        raise OwnershipError.new("managed process parent is not a private owned directory")
      end
    end

    private def prepare_log_file! : Nil
      if info = File.info?(@log_path, follow_symlinks: false)
        raise OwnershipError.new("managed process log is a symlink") if info.symlink?
        raise OwnershipError.new("managed process log is not a regular file") unless info.file?
        raise OwnershipError.new("managed process log has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
        raise OwnershipError.new("managed process log must be private") if (info.permissions.value & 0o077) != 0
        File.chmod(@log_path, 0o600) if info.permissions.value != 0o600
        if info.size > 1024 * 1024
          File.open(@log_path, "r+") { |file| file.truncate(0) }
        end
      end
    end
  end
end
