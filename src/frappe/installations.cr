require "json"
require "./project"
require "../latte/config_file"

module Caramel::Frappe
  class Installations
    def initialize(root : String? = nil)
      @root = Latte::StateSecurity.canonical_creation_path(root || ENV["CARAMEL_HOME"]? || Latte::Paths::DEFAULT_ROOT)
      @path = File.join(@root, "installations.json")
      @lock_path = @path + ".lock"
    end

    def lookup(release : String) : String?
      list[release]?
    end

    def list : Hash(String, String)
      read_entries
    end

    def register(release : String, framework_root : String) : String?
      raise Error.new("Caramel installation root must be absolute") unless Path[framework_root].absolute?
      with_lock do
        entries = read_entries
        previous = entries[release]?
        entries[release] = framework_root
        Latte::ConfigFile.write(@path, {version: 1, installations: entries}.to_json + "\n")
        previous
      end
    end

    def remove(release : String) : Bool
      with_lock do
        entries = read_entries
        if entries.delete(release)
          Latte::ConfigFile.write(@path, {version: 1, installations: entries}.to_json + "\n")
          true
        else
          false
        end
      end
    end

    private def read_entries : Hash(String, String)
      return {} of String => String unless info = File.info?(@path, follow_symlinks: false)
      unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
        raise Error.new("Caramel installation registry must be a private owned file: #{@path}")
      end
      begin
        document = JSON.parse(File.read(@path))
        raise Error.new("invalid version") unless document["version"].as_i == 1
        entries = {} of String => String
        document["installations"].as_h.each do |release, value|
          root = value.as_s
          raise Error.new("installation root must be absolute") unless Path[root].absolute?
          entries[release] = root
        end
        entries
      rescue JSON::ParseException | KeyError | TypeCastError | Error
        raise Error.new("Caramel installation registry is invalid: #{@path}")
      end
    end

    private def with_lock(& : -> T) : T forall T
      Latte::Paths.new(@root)
      if info = File.info?(@lock_path, follow_symlinks: false)
        unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise Error.new("Caramel installation registry lock must be a private owned file: #{@lock_path}")
        end
      end
      File.open(@lock_path, "a+", perm: 0o600) do |lock|
        lock.flock_exclusive { yield }
      end
    end
  end
end
