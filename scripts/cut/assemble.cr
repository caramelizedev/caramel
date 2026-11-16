require "../../src/frappe/published"

REPOSITORY = File.expand_path("../..", __DIR__)

commit = nil
if ARGV.first? == "--commit"
  ARGV.shift
  commit = ARGV.shift?
end
unless ARGV.size == 1 && !ARGV.first.starts_with?('-')
  STDERR.puts("usage: scripts/assemble-shards [--commit REV] DIRECTORY")
  exit 2
end
begin
  directory = File.expand_path(ARGV.first)
  shards = Caramel::Frappe::Published.assemble(REPOSITORY, directory, commit)
  shards.each_value do |shard|
    puts "#{shard.name} #{shard.version} #{shard.commit} #{shard.directory}"
    puts "  #{shard.push}" if commit
  end
rescue ex : Caramel::Frappe::Error
  STDERR.puts("scripts/assemble-shards: #{ex.message}")
  exit 1
end
