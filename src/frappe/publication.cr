require "file_utils"
require "./project"

module Caramel::Frappe
  # Writes generated files into a project all at once, or not at all.
  module Publication
    extend self

    def validate_path(root : String, relative : String) : Nil
      current = root
      relative.split('/').each do |part|
        current = File.join(current, part)
        if info = File.info?(current, follow_symlinks: false)
          raise Error.new("Generator refuses symlinked paths: #{relative}") if info.symlink?
        end
      end
    end

    private def preflight(root : String,
                          files : Hash(String, String),
                          originals : Hash(String, String)) : Nil
      # Repeat the version check while holding the publication lock: another
      # generator may have planned a different resource in the same second.
      files.each_key do |relative|
        next unless relative.starts_with?("db/migrations/")
        version = File.basename(relative).split('_', 2).first
        unless Dir.glob(File.join(root, "db/migrations/#{version}_*.cr")).empty?
          raise Error.new("Migration version already exists; retry generation")
        end
      end
      files.each_key do |relative|
        validate_path(root, relative)
        path = File.join(root, relative)
        if original = originals[relative]?
          unless File.file?(path) && File.read(path) == original
            raise Error.new("Source changed while planning generation: #{relative}")
          end
        elsif File.info?(path, follow_symlinks: false)
          raise Error.new("File already exists: #{relative}; source was preserved")
        end
      end
    end

    def publish(project : Project,
                files : Hash(String, String),
                originals : Hash(String, String)) : Nil
      preflight(project.root, files, originals)
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(project.root, ".caramel"))
      lock_path = File.join(directory, "generation.lock")
      raise Error.new("Generator lock must be a regular file") if File.symlink?(lock_path)
      File.open(lock_path, "a", perm: 0o600) do |lock|
        lock.flock_exclusive do
          preflight(project.root, files, originals)
          stage = File.join(directory, "generate-#{Random::Secure.hex(8)}")
          Dir.mkdir(stage, 0o700)
          published = [] of String
          begin
            files.each do |relative, content|
              path = File.join(stage, relative)
              FileUtils.mkdir_p(File.dirname(path))
              File.write(path, content)
            end
            files.each_key do |relative|
              path = File.join(project.root, relative)
              FileUtils.mkdir_p(File.dirname(path))
              if originals.has_key?(relative)
                unless File.read(path) == originals[relative]
                  raise Error.new("Source changed while generating: #{relative}")
                end
                File.rename(File.join(stage, relative), path)
              else
                File.link(File.join(stage, relative), path)
              end
              published << relative
            end
          rescue ex
            published.reverse_each do |relative|
              path = File.join(project.root, relative)
              next unless File.file?(path) && File.read(path) == files[relative]
              if original = originals[relative]?
                File.write(path, original)
              else
                File.delete(path)
              end
            end
            raise ex
          ensure
            FileUtils.rm_rf(stage)
          end
        end
      end
    end
  end
end
