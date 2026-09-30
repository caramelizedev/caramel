require "./support/harness"

root = Caramel::Checks.private_temp("caramel-dev-child-")
child : Process? = nil
begin
  runner = File.join(root, "runner")
  fixture = "spec/fixtures/dev_child_runner.cr"
  build = Caramel::Checks.crystal(["build", fixture, "-o", runner], timeout: 180.seconds)
  raise "Could not build dev child runner: #{build.stderr}" unless build.success?
  command = Process.new([runner, "/bin/sh", "-c", "printf child-output; exit 7"],
    input: Process::Redirect::Pipe, output: Process::Redirect::Pipe)
  finished = Caramel::Checks.wait_until(8.seconds, 30.milliseconds) do
    command.terminated?
  end
  raise "command did not exit" unless finished
  output = command.output.not_nil!.gets_to_end
  status = command.wait
  passed = status.normal_exit? && status.exit_code == 7 && output == "child-output"
  raise "command output or exit status differed" unless passed
  puts "PASS: command output and exit status"

  stubborn = "trap \"\" TERM; printf \"%s\" \"$$\" > descendant.pid; " \
             "while :; do /bin/sleep 1; done"
  child = Process.new([runner, "/bin/sh", "-c", stubborn],
    chdir: root, input: Process::Redirect::Pipe, output: Process::Redirect::Inherit)
  pid_file = File.join(root, "descendant.pid")
  started = Caramel::Checks.wait_until(8.seconds, 30.milliseconds) do
    File.exists?(pid_file) || child.not_nil!.terminated?
  end
  raise "descendant did not start" unless started && File.exists?(pid_file)
  pid = File.read(pid_file).to_i64
  child.input.not_nil!.close
  parent_exited = Caramel::Checks.wait_until(8.seconds, 30.milliseconds) do
    child.not_nil!.terminated?
  end
  raise "parent did not exit after lease closure" unless parent_exited
  child.wait
  killed = Caramel::Checks.wait_until(5.seconds, 50.milliseconds) do
    Caramel::Checks.gone?(pid)
  end
  raise "owned descendant survived parent lease closure" unless killed
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
