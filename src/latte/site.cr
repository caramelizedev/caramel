require "digest/sha256"
require "json"
require "./paths"

module Caramel
  module Latte
    struct Site
      DEFAULT_SUFFIX   = "caramel"
      TEST_SUFFIX      = "test"
      # RFC 6761 reserves .localhost for loopback; macOS and browsers resolve
      # its names without a system resolver entry.
      LOCALHOST_SUFFIX = "localhost"
      SUFFIXES         = {DEFAULT_SUFFIX, TEST_SUFFIX, LOCALHOST_SUFFIX}

      getter id : String
      getter name : String
      getter directory : String
      getter suffix : String
      getter upstream : String?

      def initialize(name : String, directory : String, suffix : String = DEFAULT_SUFFIX, id : String? = nil, upstream : String? = nil, validate_directory : Bool = true)
        normalized_name = self.class.validate_name(name)
        canonical_directory = validate_directory ? self.class.canonical_directory(directory) : self.class.stored_directory(directory)
        normalized_suffix = self.class.normalize_suffix(suffix)
        generated_id = self.class.id_for(normalized_name, canonical_directory, normalized_suffix)
        if id && id != generated_id
          raise ArgumentError.new("site id does not match site metadata")
        end

        @id = id || generated_id
        @name = normalized_name
        @directory = canonical_directory
        @suffix = normalized_suffix
        @upstream = upstream
      end

      def self.from_stored(id : String, name : String, directory : String, suffix : String, upstream : String? = nil) : self
        normalized_name = validate_name(name)
        normalized_suffix = normalize_suffix(suffix)
        normalized_directory = stored_directory(directory)
        if upstream
          StateSecurity.reject_controls!(upstream, "upstream socket")
        end
        generated_id = id_for(normalized_name, normalized_directory, normalized_suffix)
        unless id == generated_id
          raise ArgumentError.new("registry site id does not match site metadata")
        end
        new(normalized_name, normalized_directory, normalized_suffix, id, upstream, validate_directory: false)
      end

      def with_upstream(socket : String) : Site
        self.class.from_stored(@id, @name, @directory, @suffix, socket)
      end

      def without_upstream : Site
        self.class.from_stored(@id, @name, @directory, @suffix)
      end

      def domain : String
        "#{@name}.#{@suffix}"
      end

      def origin : String
        "https://#{domain}"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", @id
          json.field "name", @name
          json.field "directory", @directory
          json.field "suffix", @suffix
          if upstream = @upstream
            json.field "upstream", upstream
          end
        end
      end

      def self.validate_name(name : String) : String
        StateSecurity.reject_controls!(name, "site name")
        unless (1..63).includes?(name.bytesize) && name =~ /\A[a-z][a-z0-9-]*\z/ && !name.ends_with?('-')
          raise ArgumentError.new("site name must be lowercase ASCII, start with a letter, and end with a letter or digit")
        end
        name
      end

      def self.normalize_suffix(suffix : String) : String
        StateSecurity.reject_controls!(suffix, "site suffix")
        suffix = suffix.lchop('.')
        unless SUFFIXES.includes?(suffix)
          raise ArgumentError.new("site suffix must be caramel, test or localhost")
        end
        suffix
      end

      def self.canonical_directory(directory : String) : String
        StateSecurity.reject_controls!(directory, "project directory")
        candidate = Path[directory].expand(home: Path.home).normalize.to_s
        begin
          canonical = File.realpath(candidate)
        rescue ex : File::Error
          raise ArgumentError.new("project directory must exist")
        end
        info = File.info?(canonical, follow_symlinks: false)
        raise ArgumentError.new("project directory must be a directory") unless info && info.directory?
        StateSecurity.reject_controls!(canonical, "project directory")
        canonical
      end

      def self.id_for(name : String, directory : String, suffix : String = DEFAULT_SUFFIX) : String
        normalized_suffix = normalize_suffix(suffix)
        digest = Digest::SHA256.hexdigest("#{name}\0#{directory}\0#{normalized_suffix}")
        digest[0, 16]
      end

      def self.stored_directory(directory : String) : String
        StateSecurity.reject_controls!(directory, "registry project directory")
        candidate = Path[directory].expand(home: Path.home).normalize.to_s
        if info = File.info?(candidate, follow_symlinks: false)
          raise ArgumentError.new("registry project directory contains a symlink") if info.symlink?
          raise ArgumentError.new("registry project directory is not a directory") unless info.directory?
          begin
            canonical = File.realpath(candidate)
          rescue ex : File::Error
            raise ArgumentError.new("registry project directory is invalid")
          end
          raise ArgumentError.new("registry project directory is not canonical") unless canonical == candidate
        end
        candidate
      end
    end
  end
end
