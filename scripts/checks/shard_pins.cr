require "yaml"
require "./support/harness"

# Every git dependency in shard.lock is locked to a commit, written in
# Shards' own pin form `version: X+git.commit.SHA`, so a moved release tag
# cannot change what `shards install --frozen` checks out (ADR 0016). When
# lib/.shards.info is present, what Shards installed must match the lock;
# scripts/shards makes the same comparison after every install.
#
#   scripts/check shard-pins
module Caramel::Checks::ShardPins
  extend self

  PIN = /\A(?<version>[^+]+)\+git\.commit\.(?<commit>[0-9a-f]{40})\z/

  def main : Int32
    locked = git_shards(File.join(Checks::REPO, "shard.lock"))
    Checks.fail("shard.lock has no git dependencies") if locked.empty?
    info = File.join(Checks::REPO, "lib/.shards.info")
    installed = File.file?(info) ? git_shards(info) : nil
    problems = [] of String
    locked.each do |name, version|
      pin = PIN.match(version)
      unless pin
        problems << "#{name}: version #{version} pins no commit; " \
                    "write #{version}+git.commit.<the commit tag v#{version} points at>"
        next
      end
      if installed && (actual = installed[name]?) && actual != version
        problems << "#{name}: shard.lock pins #{version} but lib has #{actual}; " \
                    "run scripts/shards install --frozen"
      end
      puts "#{name} #{pin["version"]} at #{pin["commit"]}"
    end
    return 0 if problems.empty?
    problems.each { |problem| STDERR.puts problem }
    1
  end

  # Each git shard's name and version in a lock or in Shards' record of
  # what it installed.
  private def git_shards(path : String) : Hash(String, String)
    shards = YAML.parse(File.read(path))["shards"]?.try(&.as_h?) ||
             Checks.fail("#{path}: no shards")
    pins = {} of String => String
    shards.each do |name, entry|
      next unless entry["git"]?
      version = entry["version"]?.try(&.as_s?) || Checks.fail("#{path}: #{name} has no version")
      pins[name.as_s] = version
    end
    pins
  end
end

exit Caramel::Checks::ShardPins.main
