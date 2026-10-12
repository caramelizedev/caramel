require "../checks/support/browser_tools"

unless ARGV.empty?
  STDERR.puts "usage: scripts/install-browser-tools"
  exit 2
end

begin
  installed = Caramel::Checks::BrowserTools.install
  puts "Verified Chrome for Testing #{Caramel::Checks::BrowserTools.release.version}: " \
       "#{installed.directory}"
rescue ex : Caramel::Checks::BrowserTools::Error
  STDERR.puts "install-browser-tools: #{ex.message}"
  exit 1
end
