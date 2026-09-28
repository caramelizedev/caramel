require "yaml"
require "json"
require "random/secure"
require "../caramel/version"
require "../latte/site"
require "../latte/paths"

module Caramel::Frappe
  class Error < Exception
  end

  # Environment metadata is versioned application source. Credentials belong
  # in the separate private .env file, never in this manifest.
  struct EnvironmentManifest
    include YAML::Serializable
    include YAML::Serializable::Strict

    getter version : Int32
    getter name : String
    getter postgresql_major : Int32
    getter extensions : Array(String)
    getter domain_suffix : String

    def validate! : Nil
      raise Error.new("Unsupported environment.yml version; expected 1") unless @version == 1
      Latte::Site.validate_name(@name)
      @domain_suffix = Latte::Site.normalize_suffix(@domain_suffix)
      raise Error.new("This Caramel release requires PostgreSQL major 18") unless @postgresql_major == 18
      unless @extensions.uniq.size == @extensions.size && @extensions.all?(&.matches?(/\A[a-z][a-z0-9_-]*\z/))
        raise Error.new("PostgreSQL extensions must be unique lowercase identifiers")
      end
    rescue ex : ArgumentError
      raise Error.new(ex.message)
    end
  end

  # A deliberately literal dotenv format: no evaluation, variable expansion,
  # export statements, multiline literals, or hidden shell execution.
  module LocalEnvironment
    # ameba:disable Metrics/CyclomaticComplexity -- a single-pass .env parser
    def self.parse(text : String) : Hash(String, String)
      raise Error.new("Invalid local environment encoding") if !text.valid_encoding? || text.includes?('\0')
      values = {} of String => String
      text.each_line.with_index(1) do |line, number|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        key, separator, raw = line.partition('=')
        key = key.strip
        unless separator == "=" && key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise Error.new("Invalid .env assignment on line #{number}")
        end
        raise Error.new("Duplicate .env key #{key}") if values.has_key?(key)
        raw = raw.strip
        value = if raw.starts_with?('"')
                  begin
                    JSON.parse(raw).as_s
                  rescue JSON::ParseException | TypeCastError
                    raise Error.new("Invalid .env quoted value on line #{number}")
                  end
                elsif raw.starts_with?('\'')
                  if raw.bytesize < 2 || !raw.ends_with?('\'') || raw[1...-1].includes?('\'')
                    raise Error.new("Invalid .env quoted value on line #{number}")
                  end
                  raw[1...-1]
                else
                  raw
                end
        raise Error.new("Invalid .env value on line #{number}") if value.includes?('\0')
        values[key] = value
      end
      values
    end

    def self.dump(values : Hash(String, String)) : String
      String.build do |io|
        values.each do |key, value|
          raise Error.new("Invalid environment key") unless key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise Error.new("Invalid environment value") if value.includes?('\0')
          io << key << '=' << value.to_json << '\n'
        end
      end
    end
  end

  class Project
    getter root : String
    getter metadata : EnvironmentManifest

    def initialize(@root, @metadata)
    end

    def self.load(directory : String = Dir.current) : self
      root = Latte::Site.canonical_directory(directory)
      pin = pin(root)
      unless pin == Caramel::VERSION
        raise Error.new(pin ? "This project uses Caramel #{pin}, not #{Caramel::VERSION}; use its matching Caramel installation" : "shard.lock does not pin caramel; restore it from version control")
      end
      begin
        metadata = EnvironmentManifest.from_yaml(File.read(File.join(root, "config/environment.yml")))
      rescue YAML::Error | File::Error
        raise Error.new("Invalid or missing config/environment.yml")
      end
      metadata.validate!
      new(root, metadata)
    rescue ex : ArgumentError
      raise Error.new(ex.message)
    end

    # The Caramel release a project pins (ADR 0016): the version of the caramel
    # entry in its shard.lock, without build metadata.
    def self.pin(root : String) : String?
      path = File.join(root, "shard.lock")
      info = File.info?(path, follow_symlinks: false)
      return unless info && info.file? && info.size <= 1_048_576
      entry = YAML.parse(File.read(path))["shards"]?.try(&.as_h?).try(&.[YAML::Any.new("caramel")]?).try(&.as_h?)
      entry.try(&.[YAML::Any.new("version")]?).try(&.as_s?).try(&.split('+').first)
    rescue YAML::ParseException
      nil
    end

    def name : String
      @metadata.name
    end

    def shard_name : String
      name.tr("-", "_")
    end

    def module_name : String
      name.split('-').map(&.capitalize).join
    end

    def origin : String
      "https://#{name}.#{@metadata.domain_suffix}"
    end

    # The local site name may change when a clone runs beside its original.
    # Compilation follows the application's declared Shards target instead.
    def entrypoint : String
      manifest = YAML.parse(File.read(File.join(@root, "shard.yml")))
      target = manifest["name"].as_s
      source = manifest["targets"][target]["main"].as_s
      if !source.matches?(/\Asrc\/[A-Za-z0-9_\/-]+\.cr\z/) || source.split('/').includes?("..")
        raise Error.new("shard.yml application target must be a Crystal file under src/")
      end
      path = File.realpath(File.join(@root, source))
      raise Error.new("Application entry point must remain inside the project") unless path.starts_with?(@root + "/") && File.file?(path)
      source
    rescue YAML::Error | KeyError | TypeCastError | File::Error
      raise Error.new("shard.yml must declare an existing main source for its named application target")
    end

    def local_environment : Hash(String, String)
      path = File.join(@root, ".env")
      info = File.info?(path, follow_symlinks: false)
      raise Error.new("Local configuration is missing; run frappe setup") unless info
      unless Latte::StateSecurity.owned_file?(info)
        raise Error.new(".env must be an owned regular file")
      end
      raise Error.new(".env must be private (mode 0600)") unless info.permissions.value == 0o600
      raise Error.new(".env exceeds 64 KiB") if info.size > 65_536
      LocalEnvironment.parse(File.read(path))
    end

    def ensure_local_environment(connections : Hash(String, String)) : Hash(String, String)
      path = File.join(@root, ".env")
      expected = connections.merge({"APP_ORIGIN" => origin})
      if File.info?(path, follow_symlinks: false)
        values = local_environment
        expected.each do |key, value|
          raise Error.new("Local #{key} differs from Latte; .env was preserved") unless values[key]? == value
        end
        unless values["APP_SECRET"]?.try(&.matches?(/\A[0-9a-f]{64}\z/))
          raise Error.new("Local APP_SECRET is missing or invalid; .env was preserved")
        end
        return values
      end
      values = expected.merge({"APP_SECRET" => Random::Secure.hex(32)})
      # Publish without replacing a file created by another setup process.
      private_directory = Latte::StateSecurity.ensure_owned_directory(File.join(@root, ".caramel"))
      temporary = File.tempfile("env-", dir: private_directory)
      begin
        temporary << LocalEnvironment.dump(values)
        temporary.flush
        temporary.fsync
        temporary.close
        File.link(temporary.path, path)
      rescue File::Error
        raise Error.new("Could not publish local configuration; existing files were preserved")
      ensure
        temporary.close
        File.delete(temporary.path) if File.exists?(temporary.path)
      end
      values
    end
  end
end
