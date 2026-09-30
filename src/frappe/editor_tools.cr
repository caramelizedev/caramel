require "json"
require "digest/sha256"
require "file_utils"
require "random/secure"
require "./project"
require "./tools"
require "../latte/toolchain"
require "../latte/process"
require "../latte/paths"

module Caramel::Frappe
  # Optional Crystal language servers, pinned per Caramel installation and
  # installed into its private toolchain root. `frappe lsp` is the only
  # launcher: it selects the verified binaries and the pinned compiler
  # explicitly, so an editor never reaches a different Crystal.
  class EditorTools
    SERVERS                 = %w[crystalline ameba-ls]
    BUILD_RECIPE            = 3 # bump whenever the crystalline build flags or steps change
    LLVM_VERSION            = "15.0.7"
    MAX_BINARY              = 128 * 1024 * 1024
    DYLD_LINE               = /^dyld\[\d+\]: <[0-9A-Fa-f-]+> (\/.+)$/
    SYSTEM_LIBRARY_PREFIXES = {"/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/"}

    # Variables that would point the compiler or the loader elsewhere.
    CLEARED = %w[
      CRYSTAL_LIBRARY_PATH CRYSTAL_OPTS CRYSTAL_CACHE_DIR CRYSTAL_CONFIG_PATH
      DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES
      PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
    ]

    # A pinned download: HTTPS only, bounded in time, retried twice.
    CURL = %w[
      /usr/bin/curl --fail --location --silent --show-error --proto =https
      --proto-redir =https --connect-timeout 15 --max-time 600 --retry 2
    ]

    struct AmebaPin
      include JSON::Serializable
      getter version : String
      getter url : String
      getter archive_sha256 : String
      getter binary_sha256 : String
    end

    struct CrystallinePin
      include JSON::Serializable
      getter version : String
      getter git : String
      getter commit : String
      getter reported_version : String
      getter crystal : String
    end

    struct LlvmPin
      include JSON::Serializable
      getter version : String
      getter url : String
      getter sha256 : String
    end

    struct Manifest
      include JSON::Serializable
      getter version : Int32
      @[JSON::Field(key: "ameba-ls")]
      getter ameba_ls : AmebaPin
      getter crystalline : CrystallinePin
      getter llvmdev : LlvmPin
    end

    record Server,
      name : String,
      version : String,
      binary : String,
      root : String,
      source : String,
      crystal : String

    @manifest : Manifest? = nil

    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
    end

    def manifest : Manifest
      @manifest ||= begin
        Manifest.from_json(File.read(File.join(@framework_root, "tools/editor-darwin-arm64.json")))
      rescue JSON::ParseException | File::Error
        raise Error.new("frappe lsp: tools/editor-darwin-arm64.json is missing " \
                        "or invalid in Caramel at #{@framework_root}")
      end
    end

    # First 12 hex characters of SHA-256 over every crystalline build input.
    # The source commit covers crystalline's own shard.lock.
    def crystalline_fingerprint : String
      pins = manifest
      inputs = "#{pins.crystalline.commit}\n#{pins.crystalline.crystal}\n" \
               "#{pins.llvmdev.sha256}\n#{BUILD_RECIPE}"
      Digest::SHA256.hexdigest(inputs)[0, 12]
    end

    # The same toolchain every Frappé command uses (Latte::Toolchain.locate):
    # editors started without CARAMEL_TOOLCHAIN_ROOT find it through the
    # checkout's .caramel-toolchain.
    def toolchain_root(env : ENV.class | Hash(String, String) = ENV) : {String, String}
      located = Latte::Toolchain.locate(@framework_root, env)
      unless located
        raise Error.new("frappe lsp: no Caramel toolchain is configured. " \
                        "Run scripts/install-toolchain.")
      end
      value, source = located
      {Latte::Toolchain.new(value).root, source}
    rescue ex : Latte::Toolchain::Unavailable
      raise Error.new("frappe lsp: #{ex.message}")
    end

    def server(name : String, env : ENV.class | Hash(String, String) = ENV) : Server
      raise Error.new("frappe lsp: unknown language server #{name}") unless SERVERS.includes?(name)
      root, source = toolchain_root(env)
      require_complete(root)
      crystal = crystal_directory(root)
      pins = manifest
      if name == "ameba-ls"
        version = pins.ameba_ls.version
        directory = ameba_directory(root)
        binary = File.join(directory, "ameba-ls")
        not_installed(name, version, root) unless File.exists?(binary)
        failed_verification(binary, directory) unless ameba_verified?(directory, binary)
      else
        version = pins.crystalline.reported_version
        directory = crystalline_directory(root)
        binary = File.join(directory, "crystalline")
        not_installed(name, version, root) unless File.exists?(binary)
        failed_verification(binary, directory) unless crystalline_receipt_valid?(directory)
      end
      Server.new(name, version, binary, root, source, crystal)
    end

    def environment(server : Server) : Hash(String, String?)
      values = {} of String => String?
      CLEARED.each { |key| values[key] = nil }
      values["CRYSTAL_PATH"] = "lib:#{server.crystal}/src"
      # crystalline's prelude index runs the native compiler and invokes
      # pkg-config for stdlib metadata. Both helpers come from this root.
      values["PATH"] = "#{server.crystal}/embedded/bin:#{server.root}/bin:" \
                       "/usr/bin:/bin:/usr/sbin:/sbin"
      openssl = File.join("data/installs/conda-openssl", Latte::Toolchain::OPENSSL_VERSION)
      values["PKG_CONFIG_LIBDIR"] = File.join(server.root, openssl, "lib/pkgconfig")
      values["CARAMEL_TOOLCHAIN_ROOT"] = server.root
      values["XDG_CACHE_HOME"] = owned_directory(File.join(server.root, "editor/cache"))
      values
    end

    def exec(name : String, args : Array(String), directory : String) : NoReturn
      selected = server(name)
      env = environment(selected)
      # stdout is the LSP stream; diagnostics go to stderr only.
      @error.puts("frappe lsp: #{selected.name} #{selected.version} " \
                  "at #{selected.binary}; toolchain #{selected.root} " \
                  "(from #{selected.source}); PATH=#{env["PATH"]}")
      @error.flush
      Process.exec(selected.binary, args, env: env, clear_env: false, chdir: directory)
    end

    def install(tools : Tools) : Nil
      {% unless flag?(:darwin) && flag?(:aarch64) %}
        raise Error.new("frappe lsp: editor tools support Apple Silicon macOS")
      {% end %}
      root = tools.toolchain.root
      tools.check_compiler
      require_complete(root)
      crystal = crystal_directory(root)
      editor = owned_directory(File.join(root, "editor"))
      owned_directory(File.join(editor, "cache"))
      owned_directory(File.join(editor, "ameba-ls"))
      owned_directory(File.join(editor, "crystalline"))
      lock_path = File.join(editor, ".install.lock")
      if info = File.info?(lock_path, follow_symlinks: false)
        unless Latte::StateSecurity.private_file?(info)
          raise Error.new("frappe lsp: editor tools installation lock must be " \
                          "an owned private file")
        end
      end
      File.open(lock_path, "a+", perm: 0o600) do |lock|
        begin
          lock.flock_exclusive(blocking: false)
        rescue IO::Error
          raise Error.new("frappe lsp: another editor tools installation is running")
        end
        ameba = install_ameba(root)
        crystalline = install_crystalline(root, crystal, tools)
        @output.puts("Verified ameba-ls #{manifest.ameba_ls.version}: #{ameba}")
        version = manifest.crystalline.reported_version
        @output.puts("Verified crystalline #{version}: #{crystalline}")
      end
    end

    private def install_ameba(root : String) : String
      pin = manifest.ameba_ls
      target = ameba_directory(root)
      binary = File.join(target, "ameba-ls")
      if File.info?(target, follow_symlinks: false)
        unless ameba_verified?(target, binary)
          raise Error.new("frappe lsp: existing ameba-ls installation failed " \
                          "verification; preserved for inspection: #{target}")
        end
        return binary
      end
      stage = File.join(root, "editor/ameba-ls/.install-#{Random::Secure.hex(8)}")
      Dir.mkdir(stage, 0o700)
      begin
        archive = File.join(stage, "archive.tar.gz")
        download(pin.url, archive, pin.archive_sha256)
        listing = run!(["/usr/bin/tar", "-tzf", archive], "could not list #{pin.url}")
        entries = listing.stdout.lines.map(&.strip).reject(&.empty?).sort!
        unless entries == ["ameba-ls", "ameba-ls.dwarf"]
          raise Error.new("frappe lsp: unexpected contents in #{pin.url}; nothing was installed")
        end
        payload = File.join(stage, "payload")
        Dir.mkdir(payload, 0o700)
        extract = ["/usr/bin/tar", "-xzf", archive, "-C", payload, "ameba-ls"]
        run!(extract, "could not extract #{pin.url}")
        staged = File.join(payload, "ameba-ls")
        info = File.info?(staged, follow_symlinks: false)
        unless info && info.file? && info.size <= MAX_BINARY && digest(staged) == pin.binary_sha256
          raise Error.new("frappe lsp: checksum mismatch for #{pin.url}; nothing was installed")
        end
        File.chmod(staged, 0o755)
        verify_libraries(root, [staged, "--version"], pin.version)
        File.rename(payload, target)
      ensure
        FileUtils.rm_rf(stage)
      end
      binary
    end

    private def install_crystalline(root : String, crystal : String, tools : Tools) : String
      pins = manifest
      pin = pins.crystalline
      target = crystalline_directory(root)
      binary = File.join(target, "crystalline")
      if File.info?(target, follow_symlinks: false)
        unless owned?(target, directory: true) && crystalline_receipt_valid?(target)
          raise Error.new("frappe lsp: existing crystalline build failed verification; " \
                          "preserved for inspection: #{target}. Remove it to rebuild.")
        end
        return binary
      end
      @output.puts("Building crystalline #{pin.version} with Crystal #{pin.crystal} " \
                   "(this can take up to 20 minutes)…")
      @output.flush
      # Crystal pastes link flags into a shell command unquoted, so both LLVM
      # and the compiler source live in a space-free build directory. Rebuild
      # llvm_ext.o against this LLVM: the distribution's object enables ABI
      # breaking checks, while the pinned llvmdev libraries disable them.
      build = File.tempname("caramel-editor-build-", dir: "/private/tmp")
      Dir.mkdir(build, 0o700)
      begin
        llvm = prepare_llvm(build)
        targets, libfiles, system_libs = llvm_configuration(build, llvm)
        compiler_source = File.join(build, "crystal-src")
        copy_compiler_source(crystal, compiler_source)
        rebuild_llvm_ext(build, compiler_source)
        source = File.join(build, "crystalline")
        fetch_crystalline(source, pin)
        shards = File.join(@framework_root, "scripts/shards")
        tools.run(shards, ["install", "--production"], source)
        enable_save_notifications(source)
        Dir.mkdir(File.join(source, "bin"), 0o700)
        extras = {
          "CRYSTAL_PATH" => "lib:#{build}/crystal-src",
          "LLVM_CONFIG"  => llvm,
          "LLVM_VERSION" => LLVM_VERSION,
          "LLVM_TARGETS" => targets,
          "LLVM_LDFLAGS" => Process.quote_posix(libfiles + system_libs),
        }
        compiler = File.join(@framework_root, "scripts/crystal")
        release = %w[build src/crystalline.cr -o bin/crystalline --release --no-debug]
        tools.run(compiler, release, source, extras)
        publish_crystalline(root, File.join(source, "bin/crystalline"), target)
        FileUtils.rm_rf(build)
      rescue ex
        @error.puts("frappe lsp: crystalline build directory preserved for inspection: #{build}")
        raise ex
      end
      binary
    end

    # The Crystal distribution includes dangling cross-platform symlinks;
    # /bin/cp -R preserves them, whereas FileUtils.cp_r follows them.
    private def copy_compiler_source(crystal : String, destination : String) : Nil
      command = ["/bin/cp", "-R", File.join(crystal, "src"), destination]
      copy = Latte::ProcessRunner.run(command,
        env: {"PATH" => "/usr/bin:/bin"} of String => String?,
        clear_env: true,
        timeout: 120.seconds)
      return if copy.success?
      raise Error.new("frappe lsp: could not copy the pinned Crystal source: " \
                      "#{copy.stderr.strip}")
    end

    # Compiles the compiler source's llvm_ext.o against the pinned LLVM.
    private def rebuild_llvm_ext(build : String, compiler_source : String) : Nil
      ext = File.join(compiler_source, "llvm/ext")
      command = [
        "/usr/bin/clang++", "-std=c++14", "-stdlib=libc++",
        "-fno-exceptions", "-fno-rtti", "-I#{build}/llvm/include",
        "-c", File.join(ext, "llvm_ext.cc"),
        "-o", File.join(ext, "llvm_ext.o"),
      ]
      result = Latte::ProcessRunner.run(command,
        env: {"PATH" => "/usr/bin:/bin"} of String => String?,
        clear_env: true,
        timeout: 120.seconds)
      return if result.success?
      raise Error.new("frappe lsp: could not build llvm_ext.o against pinned LLVM: " \
                      "#{result.stderr.strip}")
    end

    # The pinned crystalline/lsp revisions implement didSave diagnostics but
    # advertise only incremental sync. Zed correctly omits didSave unless the
    # server advertises save support. Patch the two pinned source files before
    # building; changed upstream text fails closed instead of silently dropping
    # diagnostics. BUILD_RECIPE fingerprints this local build change.
    private def enable_save_notifications(source : String) : Nil
      options = File.join(source, "lib/lsp/src/base/capabilities/server_capabilities.cr")
      patch_once(options,
        "    property change : TextDocumentSyncKind?\n  end\n",
        "    property change : TextDocumentSyncKind?\n\n    property save : Bool?\n  end\n")
      main = File.join(source, "src/crystalline/main.cr")
      patch_once(main,
        "    text_document_sync: LSP::TextDocumentSyncKind::Incremental,\n",
        "    text_document_sync: LSP::TextDocumentSyncOptions.new(open_close: true, " \
        "change: LSP::TextDocumentSyncKind::Incremental, save: true),\n")
    end

    private def patch_once(path : String, original : String, replacement : String) : Nil
      content = File.read(path)
      unless content.split(original).size == 2
        raise Error.new("frappe lsp: pinned crystalline source differs at #{path}")
      end
      File.write(path, content.sub(original, replacement))
    end

    private def prepare_llvm(build : String) : String
      pin = manifest.llvmdev
      package = File.join(build, "llvmdev.conda")
      download(pin.url, package, pin.sha256)
      conda = File.join(build, "conda")
      Dir.mkdir(conda, 0o700)
      run!(["/usr/bin/tar", "-xf", package, "-C", conda], "could not extract #{pin.url}")
      inner = Dir.glob("#{conda}/pkg-*.tar.zst")
      raise Error.new("frappe lsp: unexpected contents in #{pin.url}") unless inner.size == 1
      llvm = File.join(build, "llvm")
      Dir.mkdir(llvm, 0o700)
      run!(["/usr/bin/tar", "-xf", inner.first, "-C", llvm], "could not extract #{pin.url}")
      config = File.join(llvm, "bin/llvm-config")
      raise Error.new("frappe lsp: #{pin.url} has no bin/llvm-config") unless File.file?(config)
      config
    end

    private def llvm_configuration(build : String,
                                   config : String) : {String, Array(String), Array(String)}
      env = {
        "PATH"                       => "/usr/bin:/bin",
        "DYLD_FALLBACK_LIBRARY_PATH" => "/usr/lib",
      } of String => String?
      query = ->(args : Array(String)) do
        result = Latte::ProcessRunner.run([config, *args],
          env: env,
          clear_env: true,
          timeout: 30.seconds)
        unless result.success?
          raise Error.new("frappe lsp: llvm-config #{args.join(' ')} failed: " \
                          "#{result.stderr.strip}")
        end
        result.stdout.strip
      end
      version = query.call(["--version"])
      unless version == LLVM_VERSION
        raise Error.new("frappe lsp: llvm-config reports #{version}, " \
                        "expected #{LLVM_VERSION}")
      end
      targets = query.call(["--targets-built"])
      library_root = File.join(build, "llvm/lib") + "/"
      libfiles = query.call(["--link-static", "--libfiles"]).split
      libfiles.each do |file|
        unless file.starts_with?(library_root) && File.file?(file)
          raise Error.new("frappe lsp: llvm-config named a library outside " \
                          "the pinned LLVM: #{file}")
        end
      end
      system_libs = query.call(["--link-static", "--system-libs"]).split
      system_libs.each do |flag|
        next if flag.starts_with?("-l")
        raise Error.new("frappe lsp: unexpected llvm-config system library flag: #{flag}")
      end
      {targets, libfiles, system_libs}
    end

    private def fetch_crystalline(source : String, pin : CrystallinePin) : Nil
      git = "/usr/bin/git"
      limit = 600.seconds
      run!([git, "init", "-q", source], "git init failed", limit)
      fetch = [git, "-C", source, "fetch", "--depth", "1", pin.git, pin.commit]
      run!(fetch, "could not fetch #{pin.git} #{pin.commit}", limit)
      checkout = [git, "-C", source, "checkout", "-q", "--detach", "FETCH_HEAD"]
      run!(checkout, "could not check out #{pin.commit}", limit)
      rev_parse = [git, "-C", source, "rev-parse", "HEAD"]
      head = run!(rev_parse, "git rev-parse failed", limit).stdout.strip
      return if head == pin.commit
      raise Error.new("frappe lsp: fetched crystalline #{head}, expected #{pin.commit}")
    end

    private def publish_crystalline(root : String, built : String, target : String) : Nil
      pins = manifest
      stage = File.join(root, "editor/crystalline/.install-#{Random::Secure.hex(8)}")
      Dir.mkdir(stage, 0o700)
      begin
        payload = File.join(stage, "payload")
        Dir.mkdir(payload, 0o700)
        staged = File.join(payload, "crystalline")
        File.copy(built, staged)
        File.chmod(staged, 0o755)
        # dyld reports the main executable too, so only a copy inside the
        # toolchain root can pass the library rule.
        libraries = verify_libraries(root, [staged, "--version"], pins.crystalline.reported_version)
        receipt = {
          version:          1,
          fingerprint:      crystalline_fingerprint,
          reported_version: pins.crystalline.reported_version,
          commit:           pins.crystalline.commit,
          crystal:          pins.crystalline.crystal,
          llvm:             LLVM_VERSION,
          llvmdev_sha256:   pins.llvmdev.sha256,
          build_recipe:     BUILD_RECIPE,
          sha256:           digest(staged),
          libraries:        libraries,
        }
        File.write(File.join(payload, "receipt.json"), receipt.to_pretty_json + "\n", perm: 0o600)
        File.rename(payload, target)
      ensure
        FileUtils.rm_rf(stage)
      end
    end

    private def crystalline_receipt_valid?(directory : String) : Bool
      pins = manifest
      binary = File.join(directory, "crystalline")
      receipt = JSON.parse(File.read(File.join(directory, "receipt.json")))
      receipt["fingerprint"]?.try(&.as_s?) == crystalline_fingerprint &&
        receipt["commit"]?.try(&.as_s?) == pins.crystalline.commit &&
        receipt["crystal"]?.try(&.as_s?) == pins.crystalline.crystal &&
        receipt["llvmdev_sha256"]?.try(&.as_s?) == pins.llvmdev.sha256 &&
        receipt["build_recipe"]?.try(&.as_i?) == BUILD_RECIPE &&
        receipt["reported_version"]?.try(&.as_s?) == pins.crystalline.reported_version &&
        owned?(directory, directory: true) &&
        owned?(File.join(directory, "receipt.json"), directory: false) &&
        owned?(binary, directory: false) &&
        receipt["sha256"]?.try(&.as_s?) == digest(binary)
    rescue JSON::ParseException | File::Error
      false
    end

    private def download(url : String, path : String, sha256 : String) : Nil
      command = CURL + ["--output", path, url]
      result = Latte::ProcessRunner.run(command, timeout: 660.seconds)
      unless result.success? && File.file?(path)
        raise Error.new("frappe lsp: download failed: #{url}")
      end
      return if digest(path) == sha256
      raise Error.new("frappe lsp: checksum mismatch for #{url}; nothing was installed")
    end

    private def run!(command : Array(String),
                     failure : String,
                     timeout : Time::Span = 120.seconds) : Latte::ProcessResult
      result = Latte::ProcessRunner.run(command, timeout: timeout)
      raise Error.new("frappe lsp: #{failure}: #{result.stderr.strip}") unless result.success?
      result
    end

    # Port of verifyNativeOutput in tools/installer/install_toolchain.swift: every image
    # dyld loads must come from the toolchain root or macOS itself.
    private def verify_libraries(root : String,
                                 command : Array(String),
                                 expected : String) : Array(String)
      env = {
        "PATH"                 => "/usr/bin:/bin",
        "HOME"                 => ENV["HOME"]?,
        "DYLD_PRINT_LIBRARIES" => "1",
      } of String => String?
      result = Latte::ProcessRunner.run(command,
        env: env,
        clear_env: true,
        chdir: root,
        timeout: 20.seconds,
        output_limit: 1_048_576)
      unless result.success? && result.stdout.starts_with?(expected)
        raise Error.new("frappe lsp: #{command[0]} did not report #{expected}")
      end
      libraries = [] of String
      result.stderr.each_line do |line|
        next unless match = DYLD_LINE.match(line)
        # Shared-cache images have no file on disk; keep their lexical path.
        path = File.realpath(match[1]) rescue Path[match[1]].normalize.to_s
        unless allowed_library?(root, path)
          raise Error.new("frappe lsp: #{command[0]} loaded a library outside " \
                          "Caramel or macOS: #{path}")
        end
        libraries << path
      end
      raise Error.new("frappe lsp: #{command[0]} produced no library evidence") if libraries.empty?
      libraries.uniq.sort!
    end

    # Whether dyld may load *path*: from the toolchain *root* or macOS itself.
    private def allowed_library?(root : String, path : String) : Bool
      path.starts_with?(root + "/") ||
        SYSTEM_LIBRARY_PREFIXES.any? { |prefix| path.starts_with?(prefix) }
    end

    # Whether *binary* in *directory* is the pinned ameba-ls, owned by this user.
    private def ameba_verified?(directory : String, binary : String) : Bool
      owned?(directory, directory: true) &&
        owned?(binary, directory: false) &&
        digest(binary) == manifest.ameba_ls.binary_sha256
    end

    private def require_complete(root : String) : Nil
      complete = begin
        toolchain = JSON.parse(File.read(File.join(root, ".caramel-toolchain.json")))
        toolchain["status"]?.try(&.as_s?) == "complete"
      rescue JSON::ParseException | File::Error
        false
      end
      raise Error.new("frappe lsp: #{root} is not a completed Caramel toolchain") unless complete
    end

    private def crystal_directory(root : String) : String
      version = manifest.crystalline.crystal
      crystal = File.join(root, "data/installs/github-crystal-lang-crystal", version)
      unless File.file?(File.join(crystal, "embedded/bin/crystal"))
        raise Error.new("frappe lsp: #{root} does not provide Crystal #{version} " \
                        "required by Caramel at #{@framework_root}")
      end
      crystal
    end

    private def ameba_directory(root : String) : String
      File.join(root, "editor/ameba-ls", manifest.ameba_ls.version)
    end

    private def crystalline_directory(root : String) : String
      version = manifest.crystalline.reported_version
      File.join(root, "editor/crystalline", "#{version}-#{crystalline_fingerprint}")
    end

    private def not_installed(name : String, version : String, root : String) : NoReturn
      raise Error.new("frappe lsp: #{name} #{version} is not installed in #{root} " \
                      "for Caramel at #{@framework_root}. Run frappe lsp install.")
    end

    private def failed_verification(binary : String, directory : String) : NoReturn
      raise Error.new("frappe lsp: #{binary} failed verification; " \
                      "remove #{directory} and run frappe lsp install.")
    end

    private def owned?(path : String, *, directory : Bool) : Bool
      info = File.info?(path, follow_symlinks: false)
      return false unless info && info.owner_id.to_i64? == Latte::StateSecurity.current_uid
      directory ? info.directory? : info.file?
    end

    private def owned_directory(path : String) : String
      Latte::StateSecurity.ensure_owned_directory(path)
    rescue ex : ArgumentError | File::Error
      raise Error.new("frappe lsp: #{path}: #{ex.message}")
    end

    private def digest(path : String) : String
      Digest::SHA256.new.file(path).hexfinal
    end
  end
end
