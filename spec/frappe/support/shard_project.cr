require "file_utils"
require "yaml"
require "../../../src/caramel/version"

# Projects for specs of the commands shards contribute: a directory whose shard.lock pins
# this Caramel release, with the manifests of its shards under lib/.
module ShardProject
  # The shard under spec/fixtures: a valid manifest and the code that registers its commands.
  FIXTURE = File.expand_path("../../fixtures/shards/demo", __DIR__)

  # The fixture shard's manifest.
  def self.fixture : String
    File.read(File.join(FIXTURE, "frappe.yml"))
  end

  # Yields a project that holds each of *manifests*, a frappe.yml by shard name, under
  # lib/ and locks *locked* beside caramel; removes it afterwards.
  def self.create(manifests : Hash(String, String),
                  locked : Array(String) = manifests.keys,
                  &)
    root = File.tempname("caramel-shard-project-")
    Dir.mkdir(root)
    begin
      File.write(File.join(root, "shard.lock"), lock(["caramel"] + locked))
      manifests.each do |shard, manifest|
        directory = File.join(root, "lib", shard)
        Dir.mkdir_p(directory)
        File.write(File.join(directory, "frappe.yml"), manifest)
      end
      yield root
    ensure
      FileUtils.rm_rf(root)
    end
  end

  # A shard.lock that locks *shards*, caramel at this release.
  def self.lock(shards : Array(String)) : String
    entries = shards.to_h do |shard|
      version = shard == "caramel" ? Caramel::VERSION : "0.1.0"
      {shard, {"path" => "../#{shard}", "version" => version}}
    end
    {"version" => 2.0, "shards" => entries}.to_yaml
  end

  # A command as a manifest writes it; a nil field is left out.
  def self.entry(syntax : String,
                 brief : String? = "Do it",
                 description : String? = "Does it.",
                 run : String? = "application",
                 examples : Array(String) = [] of String) : Hash(String, String | Array(String))
    fields = {"syntax" => syntax, "brief" => brief, "description" => description, "run" => run}
    written = {} of String => String | Array(String)
    fields.each { |field, value| written[field] = value if value }
    written["examples"] = examples unless examples.empty?
    written
  end

  # A manifest of *entries* with the lines *families*.
  def self.manifest(entries : Array(Hash(String, String | Array(String))),
                    families : Hash(String, String) = {} of String => String,
                    format : Int32 = 1) : String
    {"format" => format, "commands" => entries, "families" => families}.to_yaml
  end
end
