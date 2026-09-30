require "./support/harness"
require "c/signal"

module Caramel::Checks::LattePostgres
  extend self

  # How `ps -o lstart=` prints a process's start time.
  LSTART_FORMAT = "%a %b %e %H:%M:%S %Y"

  private def owned_postgres_pid(data : String, pid_file : String, postgres : String) : Int64?
    info = File.info?(pid_file, follow_symlinks: false)
    return unless info
    return if !info.file? || info.symlink? || info.owner_id.to_i64? != LibC.getuid.to_i64
    return if (info.permissions.value & 0o077) != 0
    lines = File.read(pid_file).lines.map(&.strip)
    return if lines.size < 3 || lines[1] != data
    pid = lines[0].to_i64
    postmaster_start = lines[2].to_i64
    return unless pid > 1 && pid <= Int32::MAX
    ps = ["/bin/ps", "-ww", "-p", pid.to_s, "-o", "uid=,lstart=,command="]
    snapshot = Checks.run(ps, env: {"LC_ALL" => "C"}, timeout: 2.seconds)
    return unless snapshot.success?
    fields = snapshot.stdout.strip.split(/\s+/, 7)
    return unless fields.size == 7 && fields[0].to_i64 == LibC.getuid.to_i64
    lstart = fields[1..5].join(" ")
    process_start = Time.parse(lstart, LSTART_FORMAT, Time::Location.local).to_unix
    return if (process_start - postmaster_start).abs > 1
    expected = "#{postgres} -D #{data}"
    command = fields[6]
    return pid if command == expected || command.starts_with?(expected + " ")
    nil
  rescue
    nil
  end

  def main : Int32
    keep = false
    ARGV.each do |arg|
      if arg == "--keep-on-failure"
        keep = true
      else
        STDERR.puts "usage: scripts/check latte-postgres [--keep-on-failure]"
        return 2
      end
    end
    toolchain = File.realpath(Checks.toolchain_root)
    pg = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin")
    unless File.file?(File.join(pg, "initdb")) && File.file?(File.join(pg, "pg_ctl"))
      STDERR.puts "Pinned PostgreSQL 18.6 tools are unavailable " \
                  "in the managed toolchain; rerun scripts/install-toolchain."
      return 2
    end

    root = Checks.private_temp("caramel-latte-postgres-")
    project = File.join(root, "project")
    Dir.mkdir(project, 0o700)
    environment = Hash(String, String?).new
    ENV.each do |key, _|
      environment[key] = nil if key.starts_with?("PG") || key.starts_with?("CARAMEL_LATTE_")
    end
    environment["CARAMEL_TOOLCHAIN_ROOT"] = toolchain
    environment["CARAMEL_LATTE_ROOT"] = root
    environment["CARAMEL_LATTE_PROJECT"] = project
    environment["LC_ALL"] = "C"

    code = begin
      spec = "spec/latte_integration/postgres_spec.cr"
      result = Checks.crystal(["spec", spec, "--error-trace"],
        env: environment, timeout: 180.seconds)
      print result.stdout
      STDERR.print result.stderr
      if result.timed_out?
        STDERR.puts "PostgreSQL integration exceeded its 180-second budget; " \
                    "cleaning up owned state."
        124
      else
        result.status.exit_code
      end
    rescue ex : IO::Error | File::Error
      STDERR.puts "Could not launch PostgreSQL integration: #{ex.message}"
      127
    end

    data = File.join(root, "services/postgres/18/data")
    pid_file = File.join(data, "postmaster.pid")
    stopped = true
    if File.exists?(pid_file) || File.symlink?(pid_file)
      if pid = owned_postgres_pid(data, pid_file, File.join(pg, "postgres"))
        begin
          stop = [File.join(pg, "pg_ctl"), "-D", data, "-m", "fast", "-w", "stop"]
          result = Checks.run(stop, env: environment, timeout: 30.seconds)
          stopped = false
          unless result.timed_out?
            if result.success? && !File.exists?(pid_file) && !File.symlink?(pid_file)
              stopped = LibC.kill(pid.to_i, 0) != 0 && Errno.value == Errno::ESRCH
            end
          end
        rescue ex : Exception
          stopped = false
          STDERR.puts "Owned PostgreSQL cleanup failed: #{ex.message}"
        end
      else
        stopped = false
        STDERR.puts "Refusing to stop an unverified PostgreSQL PID; preserving #{root}"
      end
      STDERR.puts "Owned PostgreSQL did not stop; preserving #{root}" unless stopped
    end
    if stopped && (code == 0 || !keep)
      FileUtils.rm_rf(root)
    else
      STDERR.puts "Preserved owned integration root: #{root}"
    end
    stopped ? code : 1
  rescue ex : Exception
    STDERR.puts "check-latte-postgres: #{ex.message}"
    1
  end
end

exit Caramel::Checks::LattePostgres.main
