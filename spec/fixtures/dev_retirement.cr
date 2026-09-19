require "../../src/frappe/dev_retirement"
require "../../src/frappe/dev_child"

if ARGV.first? == "__caramel_dev_child"
  exit Caramel::Frappe::DevChild.run(ARGV[1..])
end

directory = ARGV[0]
environment = {"PATH" => "/usr/bin:/bin"}
child = Caramel::Frappe::DevCommand.new(["/usr/bin/python3", File.join(directory, "resistant.py")], environment, directory)
retirement = Caramel::Frappe::DevRetirement.new
begin
  deadline = Time.instant + 5.seconds
  until File.exists?(File.join(directory, "ready"))
    raise "Child did not become ready" if Time.instant >= deadline || !child.running?
    sleep 10.milliseconds
  end
  completed = false
  retirement.retire(child) do
    sleep 100.milliseconds
    completed = true
  end
  raise "Retirement blocked the next build" unless child.running? && !completed
  raise "Retiring child was not tracked" if retirement.empty?
  retirement.drain
  raise "Retirement returned before cleanup" unless completed && !child.running? && retirement.empty?

  failed_cleanup = Caramel::Frappe::DevCommand.new(["/bin/sleep", "30"], environment, directory)
  retirement.retire(failed_cleanup) { raise "cleanup-failure-proof" }
  begin
    retirement.drain
    raise "Cleanup failure was swallowed"
  rescue ex
    raise ex unless ex.message.try(&.includes?("cleanup-failure-proof"))
  end
  raise "Failed cleanup left command alive" if failed_cleanup.running?
  puts "PASS: nonblocking retirement, tracked shutdown, completed cleanup, and surfaced cleanup failure"
ensure
  child.stop
end
