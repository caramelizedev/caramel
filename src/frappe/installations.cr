require "json"
require "./project"
require "../latte/config_file"
require "../latte/installed_releases"

module Caramel::Frappe
  # The Caramel releases installed on this Mac (ADR 0016), in
  # installations.json under Caramel's state root.
  class Installations
    getter root : String

    def initialize(root : String? = nil)
      @root = Latte::StateSecurity.canonical_creation_path(root || ENV["CARAMEL_HOME"]? || Latte::Paths::DEFAULT_ROOT)
      @path = Latte::InstalledReleases.path(@root)
      @lock_path = @path + ".lock"
    end

    def lookup(release : String) : String?
      list[release]?
    end

    def list : Hash(String, String)
      Latte::InstalledReleases.read(@path)
    rescue ex : Latte::InstalledReleases::Invalid | Latte::StateFormat::Newer
      raise Error.new(ex.message)
    end

    # The newest registered release and its checkout, by semantic version:
    # the one whose Latte, relay and launchers serve every project.
    def newest : {String, String}?
      Latte::InstalledReleases.newest(list)
    end

    def register(release : String, framework_root : String) : String?
      raise Error.new("Caramel installation root must be absolute") unless Path[framework_root].absolute?
      with_lock do
        entries = list
        previous = entries[release]?
        entries[release] = framework_root
        write(entries)
        previous
      end
    end

    def remove(release : String) : Bool
      with_lock do
        entries = list
        next false unless entries.delete(release)
        write(entries)
        true
      end
    end

    private def write(entries : Hash(String, String)) : Nil
      Latte::ConfigFile.write(@path, {version: Latte::InstalledReleases::FORMAT, installations: entries}.to_json + "\n")
    end

    private def with_lock(& : -> T) : T forall T
      Latte::Paths.new(@root)
      if info = File.info?(@lock_path, follow_symlinks: false)
        unless Latte::StateSecurity.private_file?(info)
          raise Error.new("Caramel installation registry lock must be a private owned file: #{@lock_path}")
        end
      end
      File.open(@lock_path, "a+", perm: 0o600) do |lock|
        lock.flock_exclusive { yield }
      end
    end
  end
end
