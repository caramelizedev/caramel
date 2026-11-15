# The sweettalk shard's tool program: Frappé builds it once, inside an application, and
# runs it for the commands that frappe.yml declares with run: tool. It is the one file of
# the shard that requires the framework, and by its shard name: nothing else compiles it
# (ADR 0030). It requires the toolkit and the release's version, not the shard, so it
# builds in an application that does not require the shard yet.
require "caramel/frappe/toolkit"
require "caramel/version"
require "./tool/commands"

exit SweetTalk::Tool.run(ARGV, STDOUT, STDERR)
