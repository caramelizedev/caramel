require "./project"
require "./installations"

module Caramel::Frappe
  # Small scripts in ~/.local/bin that run a registered checkout's `frappe`
  # and `latte`, so both work by name from any directory. They are the only
  # files these commands write or delete there.
  class Launchers
    NAMES  = {"frappe", "latte"}
    MARKER = "# Managed by Caramel: frappe installations register writes this file and frappe installations remove deletes it."

    getter directory : String

    def initialize(directory : String? = nil)
      @directory = directory || File.join(Path.home.to_s, ".local/bin")
    end

    def path(name : String) : String
      File.join(@directory, name)
    end

    # Points both launchers at the checkout *root*. Refuses before writing
    # anything when either name is taken by a file Caramel did not create.
    def install(root : String) : Nil
      prepare_directory
      NAMES.each do |name|
        if foreign?(path(name))
          raise Error.new("#{path(name)} exists and was not created by Caramel; move it aside and run frappe installations register again")
        end
      end
      NAMES.each { |name| publish(path(name), script(root, name)) }
    end

    # Deletes the launchers that run *root*; returns the paths removed.
    def remove(root : String) : Array(String)
      NAMES.compact_map do |name|
        destination = path(name)
        info = File.info?(destination, follow_symlinks: false)
        next unless info && info.file? && owned?(info)
        next unless File.read(destination) == script(root, name)
        File.delete(destination)
        destination
      end
    end

    # Points both launchers at the newest registered release (ADR 0016), or,
    # when none remains, deletes the ones that ran *previous*. Returns the
    # checkout they run, if any.
    def follow(installations : Installations, previous : String? = nil) : String?
      if newest = installations.newest
        install(newest[1])
        newest[1]
      else
        previous.try { |root| remove(root) }
        nil
      end
    end

    # Whether the directory is on this process's PATH.
    def on_path?(path : String? = ENV["PATH"]?) : Bool
      return false unless path
      real = File.realpath(@directory) rescue @directory
      path.split(':').any? { |entry| !entry.empty? && (File.realpath(entry) rescue entry) == real }
    end

    def script(root : String, name : String) : String
      "#!/bin/sh\n#{MARKER}\nexec #{shell_quote(File.join(root, "bin", name))} \"$@\"\n"
    end

    private def prepare_directory : Nil
      Dir.mkdir_p(@directory, 0o755)
      info = File.info(@directory)
      unless info.directory? && owned?(info) && (info.permissions.value & 0o022) == 0
        raise Error.new("#{@directory} must be a directory you own that no one else can write")
      end
    end

    private def foreign?(destination : String) : Bool
      info = File.info?(destination, follow_symlinks: false)
      return false unless info
      return true unless info.file? && owned?(info)
      !File.read(destination).starts_with?("#!/bin/sh\n#{MARKER}\n")
    end

    # Replaces a launcher Caramel wrote, or creates one where no file exists:
    # the link fails instead of replacing a file that appeared meanwhile.
    private def publish(destination : String, content : String) : Nil
      temporary = File.join(@directory, ".#{File.basename(destination)}.#{Random::Secure.hex(6)}.tmp")
      begin
        File.write(temporary, content, perm: 0o755)
        File.chmod(temporary, 0o755)
        if File.exists?(destination) || File.symlink?(destination)
          File.rename(temporary, destination)
        else
          File.link(temporary, destination)
        end
      ensure
        File.delete?(temporary)
      end
    end

    private def owned?(info : File::Info) : Bool
      info.owner_id.to_i64? == LibC.getuid.to_i64
    end

    private def shell_quote(value : String) : String
      "'" + value.gsub("'", %('"'"')) + "'"
    end
  end
end
