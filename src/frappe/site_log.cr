require "./project"

module Caramel::Frappe
  class SiteLog < IO
    MAX_BYTES = 1024 * 1024

    def self.validate_file(path : String) : Nil
      info = File.info?(path, follow_symlinks: false)
      if info && !Latte::StateSecurity.private_file?(info)
        raise Caramel::Frappe::Error.new("Site log must be an owned private file: #{path}")
      end
    end

    def initialize(@path : String, @warnings : IO)
      self.class.validate_file(@path)
      @file = File.open(@path, "a", perm: 0o600)
      @disabled = false
    end

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      return if @disabled
      begin
        @file.write(slice)
        @file.flush
        if @file.size > MAX_BYTES
          @file.close
          File.rename(@path, @path + ".previous")
          @file = File.open(@path, "a", perm: 0o600)
        end
      rescue ex : IO::Error | File::Error
        @disabled = true
        @warnings.puts("Site logging stopped for #{@path}: #{ex.message}")
      end
    end

    def mark(event : String) : Nil
      puts("=== #{Time.utc.to_rfc3339} #{event} ===")
    end

    def close : Nil
      @file.close unless @file.closed?
    end
  end
end
