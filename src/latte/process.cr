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
    getter? timed_out : Bool

    def initialize(@status : Process::Status,
                   @stdout : String,
                   @stderr : String,
                   @timed_out : Bool = false)
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
      getter? truncated : Bool

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

    # ameba:disable Metrics/CyclomaticComplexity -- launch, deadline and cleanup of one command
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
      unless output_limit > 0
        raise ArgumentError.new("managed command output limit must be positive")
      end
      unless timeout > Time::Span.zero
        raise ArgumentError.new("managed command deadline must be positive")
      end

      output_capture = BoundedOutput.new(output_limit)
      error_capture = BoundedOutput.new(output_limit)
      input_file : File? = nil
      input_path : String? = nil
      begin
        if input
          staged = File.tempfile("caramel-latte-in", ".sql", dir: Dir.tempdir)
          input_file = staged
          input_path = staged.path
          staged.chmod(0o600)
          staged << input
          staged.flush
          staged.rewind
        end

        # File staging is part of this command's launch budget too; refresh
        # the outer operation's remaining time immediately before spawning.
        timeout = OperationDeadline.limit(timeout)
        child = Process.new(
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

        completion = Channel(Process::Status | Exception).new(1)
        spawn do
          completion.send(child.wait)
        rescue ex
          completion.send(ex)
        end

        timed_out = false
        outcome = select
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
              Process::Status[124]
            end
          end
        end

        raise outcome if outcome.is_a?(Exception)
        ProcessResult.new(outcome, output_capture.contents, error_capture.contents, timed_out)
      rescue ex : ProcessFailure
        raise ex
      ensure
        input_file.try(&.close)
        if path = input_path
          begin
            File.delete(path) if File.exists?(path)
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

      def initialize(@name : String,
                     @pid : Int64,
                     @executable : String,
                     @argument_digest : String,
                     @owner_token : String,
                     @start_time : String)
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
      rescue File::Error
        raise ArgumentError.new("managed child executable is unavailable")
      end
      ensure_private_parent(@record_path)
      ensure_private_parent(@log_path)
    end

    def identity : Identity?
      return unless File.exists?(@record_path)
      check_record(File.info(@record_path, follow_symlinks: false))
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
          message = "managed process PID is live but does not match its owner record"
          raise OwnershipError.new(message)
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
        launched = Process.new(
          [@executable, *@args],
          env: @environment,
          output: output,
          error: output,
          chdir: @working_directory,
        )
        child = launched
        snapshot = process_snapshot(launched.pid)
        unless snapshot
          raise launch_failure("managed child exited before identity could be recorded")
        end
        uid, start_time, command_line = snapshot
        unless uid == LibC.getuid.to_i64 && command_line == expected_command
          raise launch_failure("managed child identity did not match its launch command")
        end
        identity = Identity.new(
          name: @name,
          pid: launched.pid,
          executable: @executable,
          argument_digest: digest_args(@args),
          owner_token: owner_token,
          start_time: start_time,
        )
        write_identity(identity)
        @process = launched
        wait_for_start(launched, timeout)
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
          child.terminate
        rescue
          # The child may have exited between identity verification and the
          # signal. Its wait below still reaps it and proves that outcome.
        end
        return stop_owned_child(child, saved, timeout)
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
      unless verify_identity(saved)
        raise OwnershipError.new("managed process did not stop before its deadline")
      end
      begin
        Process.signal(Signal::KILL, saved.pid)
      rescue ex
        raise OwnershipError.new("could not terminate the verified managed process: #{ex.message}")
      end
      wait_for_exit(saved.pid, 2.seconds)
      if Process.exists?(saved.pid)
        raise OwnershipError.new("managed process remains after termination")
      end
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
        check_record(info)
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

    # A process record is a regular file of this user's that no one else can
    # use, never a symlink.
    private def check_record(info : File::Info) : Nil
      raise OwnershipError.new("managed process record is a symlink") if info.symlink?
      raise OwnershipError.new("managed process record is not a regular file") unless info.file?
      unless owned?(info)
        raise OwnershipError.new("managed process record has foreign ownership")
      end
      raise OwnershipError.new("managed process record must be private") if shared?(info)
    end

    private def owned?(info : File::Info) : Bool
      info.owner_id.to_i64? == LibC.getuid.to_i64
    end

    # Whether the group or other users hold any permission on it.
    private def shared?(info : File::Info) : Bool
      (info.permissions.value & 0o077) != 0
    end

    private def verify_identity(saved : Identity) : Bool
      return false unless saved.name == @name && saved.executable == @executable
      return false unless saved.argument_digest == digest_args(@args)
      return false unless Process.exists?(saved.pid)
      snapshot = process_snapshot(saved.pid)
      return false unless snapshot
      uid, start_time, command_line = snapshot
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
      result = ProcessRunner.run(
        [ps, "-ww", "-p", pid.to_s, "-o", "uid=,lstart=,command="],
        timeout: 2.seconds,
        output_limit: 16 * 1024,
      )
      return unless result.success?
      fields = result.stdout.strip.split(/\s+/, 7)
      return if fields.size < 7
      uid = fields[0].to_i64?
      return unless uid
      start_time = fields[1, 5].join(" ")
      command_line = fields[6]
      {uid, start_time, command_line}
    end

    # ameba:disable Metrics/CyclomaticComplexity -- verifies each listing field before adopting
    private def adopt_existing_identity : Identity?
      ps = if File.exists?("/bin/ps")
             "/bin/ps"
           else
             "/usr/bin/ps"
           end
      # Keep the listing bounded by selecting only the executable name. Full
      # argv is fetched for that candidate set below, and only processes
      # whose command line matches exactly can be adopted or make the choice
      # ambiguous: another Latte's service or a check fixture's runs the same
      # executable with other arguments.
      result = ProcessRunner.run(
        [ps, "-ww", "-U", LibC.getuid.to_s, "-o", "uid=,pid=,comm="],
        timeout: 2.seconds,
        output_limit: PROCESS_LISTING_LIMIT,
      )
      return unless result.success?
      if result.stdout.bytesize >= PROCESS_LISTING_LIMIT
        message = "process listing exceeded 1 MiB; " \
                  "refusing to guess managed child ownership"
        raise OwnershipError.new(message)
      end
      candidates = [] of Int64
      result.stdout.each_line do |line|
        fields = line.strip.split(/\s+/, 3)
        next if fields.size < 3
        uid = fields[0].to_i64?
        pid = fields[1].to_i64?
        next unless uid && pid && uid == LibC.getuid.to_i64 && pid > 1
        executable_name = fields[2]
        expected_name = File.basename(@executable)
        exact = executable_name == @executable
        candidates << pid if exact || File.basename(executable_name) == expected_name
      end
      matches = candidates.compact_map do |pid|
        uid, start_time, command_line = process_snapshot(pid) || next
        {pid, start_time} if uid == LibC.getuid.to_i64 && command_line == expected_command
      end
      if matches.size > 1
        raise OwnershipError.new("multiple unrecorded managed children match this identity")
      end
      pid, start_time = matches.first? || return
      Identity.new(
        name: @name,
        pid: pid,
        executable: @executable,
        argument_digest: digest_args(@args),
        owner_token: Random::Secure.hex(24),
        start_time: start_time,
      )
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
        raise launch_failure("managed child exited before readiness")
      end
    end

    # A launch that failed before Latte could own the child; *reason* is its
    # stderr, and its exception says only that the command failed.
    private def launch_failure(reason : String) : ProcessFailure
      ProcessFailure.new(ProcessResult.new(Process::Status[1], "", reason))
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
      unless verify_identity(saved)
        raise OwnershipError.new("managed process did not stop before its deadline")
      end
      begin
        child.terminate(graceful: false)
      rescue ex
        raise OwnershipError.new("could not terminate the verified managed process: #{ex.message}")
      end
      unless receive_child(completion, 2.seconds)
        raise OwnershipError.new("managed process remains after termination")
      end
      File.delete(@record_path) if File.exists?(@record_path)
      @process = nil
      true
    end

    private def child_wait_channel(child : Process) : Channel(Process::Status | Exception)
      completion = Channel(Process::Status | Exception).new(1)
      spawn do
        completion.send(child.wait)
      rescue ex
        completion.send(ex)
      end
      completion
    end

    private def receive_child(completion : Channel(Process::Status | Exception),
                              timeout : Time::Span) : Bool
      select
      when item = completion.receive
        raise item if item.is_a?(Exception)
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
        unless owned?(info)
          raise OwnershipError.new("managed process parent has foreign ownership")
        end
        raise OwnershipError.new("managed process parent must be private") if shared?(info)
        File.chmod(parent, 0o700) if info.permissions.value != 0o700
      rescue
        raise OwnershipError.new("managed process parent is not a private owned directory")
      end
    end

    private def prepare_log_file! : Nil
      if info = File.info?(@log_path, follow_symlinks: false)
        raise OwnershipError.new("managed process log is a symlink") if info.symlink?
        raise OwnershipError.new("managed process log is not a regular file") unless info.file?
        unless owned?(info)
          raise OwnershipError.new("managed process log has foreign ownership")
        end
        raise OwnershipError.new("managed process log must be private") if shared?(info)
        File.chmod(@log_path, 0o600) if info.permissions.value != 0o600
        if info.size > 1024 * 1024
          File.open(@log_path, "r+", &.truncate(0))
        end
      end
    end
  end
end
