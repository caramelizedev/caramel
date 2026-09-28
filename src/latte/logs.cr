require "./paths"
require "./config_file"

module Caramel::Latte
  # Live retention for direct service logs and the detached daemon's own log.
  # Keeping the same inode lets independently surviving children continue
  # appending after daemon restart.
  # The daemon sweeps once per second; bytes written between sweeps can exceed
  # the threshold. Each previous log retains at most one MiB of recent output.
  module Logs
    MAX_BYTES = 1024 * 1024

    def self.sweep(paths : Paths) : Nil
      %w[postgres dns proxy latte].each do |name|
        path = File.join(paths.logs_dir, "#{name}.log")
        info = File.info?(path, follow_symlinks: false)
        next unless info
        unless StateSecurity.private_file?(info)
          raise ArgumentError.new("Managed service log is not a private owned file")
        end
        next unless info.size > MAX_BYTES
        File.open(path, "r+") do |file|
          file.seek(-MAX_BYTES, IO::Seek::End)
          buffer = Bytes.new(MAX_BYTES)
          length = file.read_fully?(buffer)
          retained = length ? String.new(buffer) : ""
          ConfigFile.write(path + ".previous", retained)
          file.truncate(0)
        end
      end
    end
  end
end
