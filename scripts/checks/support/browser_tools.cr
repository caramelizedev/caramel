require "./harness"

module Caramel::Checks
  # The Chrome for Testing that scripts/check browser drives, pinned in
  # tools/browser-darwin-arm64.json. scripts/install-browser-tools installs
  # it into the toolchain's data/installs, which every `scripts/check all`
  # lane prefix links; the check only verifies it.
  module BrowserTools
    MANIFEST = File.join(REPO, "tools/browser-darwin-arm64.json")

    # Same list as Caramel::Frappe::EditorTools::CURL (src/frappe/editor_tools.cr):
    # requiring that file would pull in Frappé.
    CURL = %w[
      /usr/bin/curl --fail --location --silent --show-error --proto =https
      --proto-redir =https --connect-timeout 15 --max-time 600 --retry 2
    ]

    # The one directory each archive extracts to.
    TOPS = {
      "chrome-headless-shell" => "chrome-headless-shell-mac-arm64",
      "chromedriver"          => "chromedriver-mac-arm64",
    }

    class Error < Exception; end

    struct Archive
      include JSON::Serializable
      getter url : String
      getter archive_sha256 : String
      getter binary_sha256 : String
    end

    struct Release
      include JSON::Serializable
      getter version : String
      @[JSON::Field(key: "chrome-headless-shell")]
      getter headless_shell : Archive
      getter chromedriver : Archive
      getter license : String
      getter license_url : String

      def archive(name : String) : Archive
        name == "chromedriver" ? chromedriver : headless_shell
      end
    end

    struct Manifest
      include JSON::Serializable
      getter version : Int32
      @[JSON::Field(key: "chrome-for-testing")]
      getter chrome : Release
    end

    record Installed, directory : String, headless_shell : String, chromedriver : String

    def self.release : Release
      Manifest.from_json(File.read(MANIFEST)).chrome
    rescue JSON::ParseException | File::Error
      raise Error.new("tools/browser-darwin-arm64.json is missing or invalid")
    end

    def self.directory(root : String = Checks.toolchain_root) : String
      File.join(root, "data/installs/chrome-for-testing", release.version)
    end

    def self.installed : Installed
      verify(directory)
    end

    def self.install : Installed
      {% unless flag?(:darwin) && flag?(:aarch64) %}
        raise Error.new("install-browser-tools supports Apple Silicon macOS")
      {% end %}
      pin = release
      root = Checks.toolchain_root
      require_complete(root)
      parent = root
      %w[data installs chrome-for-testing].each do |component|
        parent = owned_directory(File.join(parent, component))
      end
      target = directory(root)
      return verify(target) if File.info?(target, follow_symlinks: false)

      stage = File.join(parent, ".install-#{Random::Secure.hex(8)}")
      begin
        Dir.mkdir(stage, 0o700)
        payload = File.join(stage, "payload")
        Dir.mkdir(payload, 0o700)
        TOPS.each_key { |name| fetch(name, pin.archive(name), stage, payload) }
        paths = layout(payload)
        {paths.headless_shell, paths.chromedriver}.each do |path|
          unless digest(path) == pin.archive(File.basename(path)).binary_sha256
            raise Error.new("checksum mismatch for #{path}; nothing was installed")
          end
          File.chmod(path, 0o755)
          probe(path, pin.version, stage)
        end
        File.write(File.join(payload, "receipt.json"), pin.to_json, perm: 0o600)
        publish(payload, target)
      ensure
        FileUtils.rm_rf(stage)
      end
      verify(target)
    end

    private def self.layout(directory : String) : Installed
      Installed.new(directory,
        File.join(directory, TOPS["chrome-headless-shell"], "chrome-headless-shell"),
        File.join(directory, TOPS["chromedriver"], "chromedriver"))
    end

    # Fails unless *directory* holds both pinned executables, owned by this
    # user and byte-identical to the manifest.
    private def self.verify(directory : String) : Installed
      pin = release
      unless File.info?(directory, follow_symlinks: false)
        raise Error.new("Chrome for Testing #{pin.version} is not installed in " \
                        "#{Checks.toolchain_root}.\nRun scripts/install-browser-tools.")
      end
      installed = layout(directory)
      sound = owned?(directory, directory: true) &&
              {installed.headless_shell, installed.chromedriver}.all? do |path|
                owned?(path, directory: false) &&
                  digest(path) == pin.archive(File.basename(path)).binary_sha256
              end
      return installed if sound

      raise Error.new("Chrome for Testing #{pin.version} failed verification; " \
                      "remove #{directory} and run scripts/install-browser-tools.")
    end

    private def self.fetch(name : String, archive : Archive, stage : String, payload : String) : Nil
      zip = File.join(stage, "#{name}.zip")
      result = Checks.run(CURL + ["--output", zip, archive.url], timeout: 660.seconds)
      raise Error.new("download failed: #{archive.url}") unless result.success? && File.file?(zip)
      unless digest(zip) == archive.archive_sha256
        raise Error.new("checksum mismatch for #{archive.url}; nothing was installed")
      end

      listing = Checks.run(["/usr/bin/zipinfo", "-1", zip], timeout: 60.seconds)
      names = listing.stdout.lines.reject(&.empty?)
      safe = listing.success? && !names.empty? && names.all? { |entry| safe_entry?(entry, name) }
      raise Error.new("unexpected contents in #{archive.url}; nothing was installed") unless safe
      extracted = Checks.run(["/usr/bin/ditto", "-x", "-k", zip, payload], timeout: 300.seconds)
      return if extracted.success?

      raise Error.new("could not extract #{archive.url}: #{extracted.stderr.strip}")
    end

    private def self.safe_entry?(entry : String, name : String) : Bool
      entry.starts_with?("#{TOPS[name]}/") && !entry.split('/').includes?("..")
    end

    private def self.probe(path : String, version : String, stage : String) : Nil
      home = File.join(stage, "home")
      Dir.mkdir_p(home, 0o700)
      result = Checks.run([path, "--version"],
        env: {"PATH" => "/usr/bin:/bin", "HOME" => home},
        clear_env: true,
        timeout: 20.seconds)
      return if result.success? && result.stdout.includes?(version)

      raise Error.new("#{path} did not report #{version}")
    end

    private def self.publish(payload : String, target : String) : Nil
      File.rename(payload, target)
    rescue ex : File::Error
      raise ex unless File.info?(target, follow_symlinks: false)
    end

    private def self.require_complete(root : String) : Nil
      complete = begin
        toolchain = JSON.parse(File.read(File.join(root, ".caramel-toolchain.json")))
        toolchain["status"]?.try(&.as_s?) == "complete"
      rescue JSON::ParseException | File::Error
        false
      end
      return if complete

      raise Error.new("#{root} is not a completed Caramel toolchain; " \
                      "run scripts/install-toolchain.")
    end

    private def self.owned_directory(path : String) : String
      Caramel::Latte::StateSecurity.ensure_owned_directory(path)
    rescue ex : ArgumentError | File::Error
      raise Error.new("#{path}: #{ex.message}")
    end

    private def self.owned?(path : String, *, directory : Bool) : Bool
      info = File.info?(path, follow_symlinks: false)
      return false unless info && info.owner_id.to_i64? == Caramel::Latte::StateSecurity.current_uid

      directory ? info.directory? : info.file?
    end

    private def self.digest(path : String) : String
      Digest::SHA256.new.file(path).hexfinal
    end
  end
end
