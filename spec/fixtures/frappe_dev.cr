require "../../src/frappe/dev_session"
require "../../src/frappe/dev_child"

if ARGV.first? == "__caramel_dev_child"
  exit Caramel::Frappe::DevChild.run(ARGV[1..])
end

project = Caramel::Frappe::Project.load(ARGV[0])
tools = Caramel::Frappe::Tools.new(File.expand_path("../..", __DIR__))
client = Caramel::Frappe::LatteClient.new
client.ready!
Caramel::Frappe::DevSession.new(project, tools, client, project.local_environment, runtime_url: ENV["CARAMEL_DEV_RUNTIME_URL"]?).run(open_browser: false)
