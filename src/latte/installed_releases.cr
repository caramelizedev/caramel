require "json"
require "semantic_version"
require "./paths"
require "./state_format"

module Caramel::Latte
  # installations.json in Caramel's state root: each Caramel release on this
  # Mac and its checkout (ADR 0016). `frappe installations` writes it; Frappé
  # and Latte read it to run the newest release's Latte.
  module InstalledReleases
    FORMAT = 1

    class Invalid < Exception
    end

    def self.path(root : String) : String
      File.join(root, "installations.json")
    end

    # Raises Invalid for an unsafe or malformed file, and StateFormat::Newer
    # for one a newer Caramel wrote.
    def self.read(path : String) : Hash(String, String)
      entries = {} of String => String
      return entries unless info = File.info?(path, follow_symlinks: false)
      raise Invalid.new("Caramel installation registry must be a private owned file: #{path}") unless StateSecurity.private_file?(info)
      document = JSON.parse(File.read(path))
      StateFormat.check!(path, document["version"].as_i, FORMAT)
      document["installations"].as_h.each do |release, value|
        SemanticVersion.parse(release)
        root = value.as_s
        raise ArgumentError.new("installation root must be absolute") unless Path[root].absolute?
        entries[release] = root
      end
      entries
    rescue JSON::ParseException | KeyError | TypeCastError | ArgumentError
      raise Invalid.new("Caramel installation registry is invalid: #{path}")
    end

    # The newest release by semantic version, and its checkout.
    def self.newest(entries : Hash(String, String)) : {String, String}?
      entries.max_by? { |release, _| SemanticVersion.parse(release) }
    end

    # The newest installed release's built `latte`, when that release is newer
    # than *version*; nil when this release is the newest or the registry
    # cannot be read.
    def self.newer_latte(state_root : String, version : String) : String?
      release, root = newest(read(path(state_root))) || return
      return unless SemanticVersion.parse(release) > SemanticVersion.parse(version)
      latte = File.join(root, "bin/latte")
      latte if File::Info.executable?(latte)
    rescue Invalid | StateFormat::Newer
      nil
    end
  end
end
