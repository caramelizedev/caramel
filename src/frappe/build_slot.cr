require "digest/sha256"
require "json"
require "random/secure"
require "./project"

module Caramel::Frappe
  # One reusable build: a binary, its `.dwarf` on macOS, and a JSON record of
  # what it was built from. The slot holds a build of a source fingerprint
  # while the record names that fingerprint, this toolchain, this framework
  # version and this mode, and the binary and debug file still hash to what
  # it recorded. A build is therefore reused only while every input Frappé
  # hashes is unchanged (ADR 0012, ADR 0013 §5, ADR 0010).
  class BuildSlot
    # `frappe dev` and one-shot commands build with the same flags.
    DEVELOPMENT = "caramel_development"

    getter binary : String

    def initialize(@binary : String, @record : String, @toolchain : String, @mode : String)
    end

    # `frappe dev`'s build of *fingerprint*, which commands reuse.
    def self.development(root : String, fingerprint : String, toolchain : String) : self
      directory = File.join(root, ".caramel/dev")
      binary = File.join(directory, "application-#{fingerprint[0, 16]}")
      new(binary, File.join(directory, "build.json"), toolchain, DEVELOPMENT)
    end

    # The build one-shot commands run.
    def self.command(root : String, toolchain : String) : self
      directory = File.join(root, ".caramel")
      record = File.join(directory, "application.json")
      new(File.join(directory, "application"), record, toolchain, DEVELOPMENT)
    end

    def holds?(fingerprint : String) : Bool
      reject_symlink(@record)
      reject_symlink(@binary)
      return false unless File.file?(@record) && File.file?(@binary)
      debug = debug_checksum
      {% if flag?(:darwin) %}
        return false unless debug
      {% end %}
      saved = JSON.parse(File.read(@record))
      saved["source"].as_s == fingerprint && saved["binary"].as_s == checksum(@binary) &&
        saved["debug"].as_s? == debug && saved["toolchain"].as_s == @toolchain &&
        saved["framework"].as_s == Caramel::VERSION && saved["mode"].as_s == @mode
    rescue JSON::ParseException | KeyError | TypeCastError
      false
    end

    # Moves the finished build at *temporary*, with its debug file, into the
    # slot and records *fingerprint*. Without one it is never reused.
    def install(temporary : String, fingerprint : String?) : Nil
      reject_symlink(@binary)
      {% if flag?(:darwin) %}
        reject_symlink(@binary + ".dwarf")
        unless File.file?(temporary + ".dwarf")
          raise Error.new("Compiler did not produce development debug information")
        end
        File.rename(temporary + ".dwarf", @binary + ".dwarf")
      {% end %}
      File.rename(temporary, @binary)
      if fingerprint
        write_record(fingerprint)
      else
        reject_symlink(@record)
        File.delete?(@record)
      end
    end

    # Hard-links *source*'s build into the slot and records *fingerprint*.
    # Unlike a path, a link survives `frappe dev` deleting the original.
    def link(source : BuildSlot, fingerprint : String) : Nil
      {% if flag?(:darwin) %}
        replace(source.binary + ".dwarf", @binary + ".dwarf")
      {% end %}
      replace(source.binary, @binary)
      write_record(fingerprint)
    end

    private def replace(existing : String, path : String) : Nil
      reject_symlink(path)
      temporary = "#{path}.#{Random::Secure.hex(4)}"
      File.link(existing, temporary)
      File.rename(temporary, path)
    ensure
      temporary.try { |name| File.delete?(name) }
    end

    private def write_record(fingerprint : String) : Nil
      contents = {
        source: fingerprint, binary: checksum(@binary), debug: debug_checksum,
        toolchain: @toolchain, framework: Caramel::VERSION, mode: @mode,
      }.to_json
      reject_symlink(@record)
      temporary = File.tempfile("build-", dir: File.dirname(@record))
      begin
        temporary << contents
        temporary.close
        File.rename(temporary.path, @record)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    private def debug_checksum : String?
      {% if flag?(:darwin) %}
        path = @binary + ".dwarf"
        reject_symlink(path)
        checksum(path) if File.file?(path)
      {% else %}
        nil
      {% end %}
    end

    private def checksum(path : String) : String
      Digest::SHA256.hexdigest(File.read(path))
    end

    private def reject_symlink(path : String) : Nil
      if info = File.info?(path, follow_symlinks: false)
        unless Latte::StateSecurity.owned_file?(info)
          raise Error.new("Development artifacts must be owned regular files")
        end
      end
    end
  end

  # Serializes one application's builds across processes. `frappe dev` holds
  # it while it checks, builds and installs, and a command while it looks for
  # a build or makes one. So a command waits for a build in flight and can
  # reuse it, and no two builds write the program's compiler cache at once.
  class BuildLock
    def initialize(root : String)
      state = Latte::StateSecurity.ensure_owned_directory(File.join(root, ".caramel"))
      path = File.join(state, "build.lock")
      if info = File.info?(path, follow_symlinks: false)
        unless Latte::StateSecurity.owned_file?(info)
          raise Error.new("The build lock must be an owned regular file")
        end
      end
      @file = File.open(path, "a", perm: Latte::StateSecurity::FILE_MODE)
    end

    # Takes the lock unless another build holds it.
    def acquire? : Bool
      @file.flock_exclusive(blocking: false)
      true
    rescue IO::Error
      false
    end

    # Takes the lock, yielding once first if another build holds it.
    def acquire(&) : Nil
      return if acquire?
      yield
      @file.flock_exclusive
    end

    # Closing the file releases the lock.
    def release : Nil
      @file.close
    end
  end
end
