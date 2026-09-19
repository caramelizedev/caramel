require "random/secure"

module Caramel::Latte
  # Publish an entire owned configuration; readers never see a partial write.
  module ConfigFile
    def self.directory(path : String)
      raise ArgumentError.new("managed directory must not be a symlink") if File.symlink?(path)
      Dir.mkdir(path, 0o700) unless Dir.exists?(path)
      info = File.info(path, follow_symlinks: false)
      unless info.directory? && info.owner_id == LibC.getuid.to_s && info.permissions.value == 0o700
        raise ArgumentError.new("managed directory must be private and owned by this user")
      end
    end

    def self.write(path : String, content : String)
      directory(File.dirname(path))
      if File.exists?(path) || File.symlink?(path)
        info = File.info(path, follow_symlinks: false)
        unless info.file? && info.owner_id == LibC.getuid.to_s && info.permissions.value == 0o600
          raise ArgumentError.new("managed configuration must be a private owned regular file")
        end
      end
      file = File.tempfile(".config-", ".tmp", dir: File.dirname(path))
      begin
        file << content
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      ensure
        file.close
        File.delete(file.path) if File.exists?(file.path)
      end
      path
    end
  end
end
