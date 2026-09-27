require "./support/harness"

root = Caramel::Checks.private_temp("caramel-dev-child-")
child : Process? = nil
begin
  runner = File.join(root, "runner")
  build = Caramel::Checks.crystal(["build", "spec/fixtures/dev_child_runner.cr", "-o", runner], timeout: 180.seconds)
  raise "Could not build dev child runner: #{build.stderr}" unless build.success?
  command = Process.new([runner, "/bin/sh", "-c", "printf child-output; exit 7"],
    input: Process::Redirect::Pipe, output: Process::Redirect::Pipe)
  raise "command did not exit" unless Caramel::Checks.wait_until(8.seconds, 30.milliseconds) { command.terminated? }
  output = command.output.not_nil!.gets_to_end
  status = command.wait
  raise "command output or exit status differed" unless status.normal_exit? && status.exit_code == 7 && output == "child-output"
  puts "PASS: command output and exit status"

  child = Process.new([runner, "/bin/sh", "-c", "trap \"\" TERM; printf \"%s\" \"$$\" > descendant.pid; while :; do /bin/sleep 1; done"],
    chdir: root, input: Process::Redirect::Pipe, output: Process::Redirect::Inherit)
  pid_file = File.join(root, "descendant.pid")
  raise "descendant did not start" unless Caramel::Checks.wait_until(8.seconds, 30.milliseconds) { File.exists?(pid_file) || child.not_nil!.terminated? } && File.exists?(pid_file)
  pid = File.read(pid_file).to_i64
  child.input.not_nil!.close
  raise "parent did not exit after lease closure" unless Caramel::Checks.wait_until(8.seconds, 30.milliseconds) { child.not_nil!.terminated? }
  child.wait
  raise "owned descendant survived parent lease closure" unless Caramel::Checks.wait_until(5.seconds, 50.milliseconds) { Caramel::Checks.gone?(pid) }
  puts "PASS: closed parent lease kills TERM-resistant descendants"
ensure
  if process = child
    unless process.terminated?
      process.input.try { |io| io.close unless io.closed? }
      Caramel::Checks.stop(process)
    end
  end
  FileUtils.rm_rf(root)
end
