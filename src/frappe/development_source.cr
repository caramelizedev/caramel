require "yaml"
require "./new_project"

module Caramel::Frappe
  # An application generated before releases published their shards takes the caramel
  # shard from the repository Caramel is developed in, and Shards copies that whole
  # repository into lib/. This tells its author what to write instead; it changes no file.
  module DevelopmentSource
    # The development repository, as a `github:` dependency names it.
    NAME = Caramel::REPOSITORY.lchop("https://github.com/")
    # Any git URL of it on GitHub, with or without the `.git` ending.
    URL = /github\.com[\/:]#{Regex.escape(NAME)}(\.git)?\/?\z/
    # Each file that states the shard's source, with the section its entry is under.
    SECTIONS = {"shard.yml" => "dependencies", "shard.lock" => "shards"}

    # Raises, with the two entries to write instead, when the project at *root* names
    # the development repository as the source of its caramel shard. The entries are
    # the ones `frappe new` writes from the installation at *framework_root*.
    def self.check(root : String, framework_root : String) : Nil
      stale = SECTIONS.keys.select { |file| development?(entry(root, file)) }
      return if stale.empty?
      current = NewProject.new(framework_root).dependency
      raise Error.new(<<-TEXT)
        #{stale.join(" and ")} #{stale.size == 1 ? "takes" : "take"} the caramel shard \
        from #{NAME}, where Caramel is developed, so Shards copies that whole repository \
        into lib/. Replace both entries. Under dependencies: in shard.yml, write
        #{current.manifest_entry.chomp}
        and under shards: in shard.lock, write
        #{current.lock_entry.chomp}
        Then run frappe setup.
        TEXT
    end

    # The caramel entry of *file* in the project at *root*, when it has one.
    private def self.entry(root : String, file : String) : YAML::Any?
      document = YAML.parse(File.read(File.join(root, file)))
      section = document.as_h? ? document[SECTIONS[file]]? : nil
      section.try { |shards| shards.as_h? ? shards["caramel"]? : nil }
    rescue YAML::ParseException | File::Error
      nil
    end

    private def self.development?(entry : YAML::Any?) : Bool
      source = entry.try { |stated| stated.as_h? ? stated : nil } || return false
      return true if source["github"]?.try(&.as_s?) == NAME
      source["git"]?.try(&.as_s?).try(&.matches?(URL)) || false
    end
  end
end
