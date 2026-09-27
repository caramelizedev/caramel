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
    SERVERS      = %w(crystalline ameba-ls)
    BUILD_RECIPE = 3 # bump whenever the crystalline build flags or steps change
    LLVM_VERSION = "15.0.7"
    MAX_BINARY   = 128 * 1024 * 1024
    DYLD_LINE    = /^dyld\[\d+\]: <[0-9A-Fa-f-]+> (\/.+)$/
    SYSTEM_LIBRARY_PREFIXES = {"/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/"}

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

    record Server, name : String, version : String, binary : String, root : String, source : String, crystal : String

    @manifest : Manifest? = nil

    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
    end

    def manifest : Manifest
      @manifest ||= begin
        Manifest.from_json(File.read(File.join(@framework_root, "tools/editor-darwin-arm64.json")))
      rescue JSON::ParseException | File::Error
        raise Error.new("frappe lsp: tools/editor-darwin-arm64.json is missing or invalid in Caramel at #{@framework_root}")
      end
    end

    # First 12 hex characters of SHA-256 over every crystalline build input.
    # The source commit covers crystalline's own shard.lock.
    def crystalline_fingerprint : String
      pins = manifest
      Digest::SHA256.hexdigest("#{pins.crystalline.commit}\n#{pins.crystalline.crystal}\n#{pins.llvmdev.sha256}\n#{BUILD_RECIPE}")[0, 12]
    end

    # CARAMEL_TOOLCHAIN_ROOT wins; the installer-written pointer is the
    # fallback for editors started without the variable.
    def toolchain_root(env : ENV.class | Hash(String, String) = ENV) : {String, String}
      value, source = if (selected = env["CARAMEL_TOOLCHAIN_ROOT"]?) && !selected.empty?
                        {selected, "CARAMEL_TOOLCHAIN_ROOT"}
                      elsif (line = pointer_line) && !line.empty?
                        {line, ".caramel-toolchain"}
                      else
                        raise Error.new("frappe lsp: no Caramel toolchain is configured. Set CARAMEL_TOOLCHAIN_ROOT or run frappe lsp install.")
                      end
      toolchain = begin
        Latte::Toolchain.new(value)
      rescue ex : Latte::Toolchain::Unavailable
        raise Error.new("frappe lsp: #{ex.message}")
      end
      {toolchain.root, source}
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
        failed_verification(binary, directory) unless owned?(directory, directory: true) &&
                                                      owned?(binary, directory: false) &&
                                                      digest(binary) == pins.ameba_ls.binary_sha256
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
      %w(CRYSTAL_LIBRARY_PATH CRYSTAL_OPTS CRYSTAL_CACHE_DIR CRYSTAL_CONFIG_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR).each do |key|
        values[key] = nil
      end
      values["CRYSTAL_PATH"] = "lib:#{server.crystal}/src"
      # crystalline's prelude index runs the native compiler and invokes
      # pkg-config for stdlib metadata. Both helpers come from this root.
      values["PATH"] = "#{server.crystal}/embedded/bin:#{server.root}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      values["PKG_CONFIG_LIBDIR"] = File.join(server.root, "data/installs/conda-openssl", Latte::Toolchain::OPENSSL_VERSION, "lib/pkgconfig")
      values["CARAMEL_TOOLCHAIN_ROOT"] = server.root
      values["XDG_CACHE_HOME"] = owned_directory(File.join(server.root, "editor/cache"))
      values
    end

    def exec(name : String, args : Array(String), directory : String) : NoReturn
      selected = server(name)
      env = environment(selected)
      # stdout is the LSP stream; diagnostics go to stderr only.
      @error.puts("frappe lsp: #{selected.name} #{selected.version} at #{selected.binary}; toolchain #{selected.root} (from #{selected.source}); PATH=#{env["PATH"]}")
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
        unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise Error.new("frappe lsp: editor tools installation lock must be an owned private file")
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
        write_pointer(root)
        @output.puts("Verified ameba-ls #{manifest.ameba_ls.version}: #{ameba}")
        @output.puts("Verified crystalline #{manifest.crystalline.reported_version}: #{crystalline}")
      end
    end

    private def install_ameba(root : String) : String
      pin = manifest.ameba_ls
      target = ameba_directory(root)
      binary = File.join(target, "ameba-ls")
      if File.info?(target, follow_symlinks: false)
        unless owned?(target, directory: true) && owned?(binary, directory: false) && digest(binary) == pin.binary_sha256
          raise Error.new("frappe lsp: existing ameba-ls installation failed verification; preserved for inspection: #{target}")
        end
        return binary
      end
      stage = File.join(root, "editor/ameba-ls/.install-#{Random::Secure.hex(8)}")
      Dir.mkdir(stage, 0o700)
      begin
        archive = File.join(stage, "archive.tar.gz")
        download(pin.url, archive, pin.archive_sha256)
        listing = run!(["/usr/bin/tar", "-tzf", archive], "could not list #{pin.url}")
        unless listing.stdout.lines.map(&.strip).reject(&.empty?).sort == ["ameba-ls", "ameba-ls.dwarf"]
          raise Error.new("frappe lsp: unexpected contents in #{pin.url}; nothing was installed")
        end
        payload = File.join(stage, "payload")
        Dir.mkdir(payload, 0o700)
        run!(["/usr/bin/tar", "-xzf", archive, "-C", payload, "ameba-ls"], "could not extract #{pin.url}")
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
          raise Error.new("frappe lsp: existing crystalline build failed verification; preserved for inspection: #{target}. Remove it to rebuild.")
        end
        return binary
      end
      @output.puts("Building crystalline #{pin.version} with Crystal #{pin.crystal} (this can take up to 20 minutes)…")
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
        # The Crystal distribution includes dangling cross-platform symlinks;
        # /bin/cp -R preserves them, whereas FileUtils.cp_r follows them.
        copy = Latte::ProcessRunner.run(["/bin/cp", "-R", File.join(crystal, "src"), compiler_source],
          env: {"PATH" => "/usr/bin:/bin"} of String => String?, clear_env: true, timeout: 120.seconds)
        raise Error.new("frappe lsp: could not copy the pinned Crystal source: #{copy.stderr.strip}") unless copy.success?
        ext = File.join(compiler_source, "llvm/ext")
        result = Latte::ProcessRunner.run([
          "/usr/bin/clang++", "-std=c++14", "-stdlib=libc++", "-fno-exceptions", "-fno-rtti",
          "-I#{build}/llvm/include", "-c", File.join(ext, "llvm_ext.cc"), "-o", File.join(ext, "llvm_ext.o"),
        ], env: {"PATH" => "/usr/bin:/bin"} of String => String?, clear_env: true, timeout: 120.seconds)
        raise Error.new("frappe lsp: could not build llvm_ext.o against pinned LLVM: #{result.stderr.strip}") unless result.success?
        source = File.join(build, "crystalline")
        fetch_crystalline(source, pin)
        tools.run(File.join(@framework_root, "scripts/shards"), ["install", "--production"], source)
        enable_save_notifications(source)
        Dir.mkdir(File.join(source, "bin"), 0o700)
        extras = {
          "CRYSTAL_PATH"  => "lib:#{build}/crystal-src",
          "LLVM_CONFIG"   => llvm,
          "LLVM_VERSION"  => LLVM_VERSION,
          "LLVM_TARGETS"  => targets,
          "LLVM_LDFLAGS"  => Process.quote_posix(libfiles + system_libs),
        }
        tools.run(File.join(@framework_root, "scripts/crystal"), ["build", "src/crystalline.cr", "-o", "bin/crystalline", "--release", "--no-debug"], source, extras)
        publish_crystalline(root, File.join(source, "bin/crystalline"), target)
        FileUtils.rm_rf(build)
      rescue ex
        @error.puts("frappe lsp: crystalline build directory preserved for inspection: #{build}")
        raise ex
      end
      binary
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
        "    text_document_sync: LSP::TextDocumentSyncOptions.new(open_close: true, change: LSP::TextDocumentSyncKind::Incremental, save: true),\n")
    end

    private def patch_once(path : String, original : String, replacement : String) : Nil
      content = File.read(path)
      raise Error.new("frappe lsp: pinned crystalline source differs at #{path}") unless content.split(original).size == 2
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

    private def llvm_configuration(build : String, config : String) : {String, Array(String), Array(String)}
      env = {"PATH" => "/usr/bin:/bin", "DYLD_FALLBACK_LIBRARY_PATH" => "/usr/lib"} of String => String?
      query = ->(args : Array(String)) do
        result = Latte::ProcessRunner.run([config, *args], env: env, clear_env: true, timeout: 30.seconds)
        raise Error.new("frappe lsp: llvm-config #{args.join(' ')} failed: #{result.stderr.strip}") unless result.success?
        result.stdout.strip
      end
      version = query.call(["--version"])
      raise Error.new("frappe lsp: llvm-config reports #{version}, expected #{LLVM_VERSION}") unless version == LLVM_VERSION
      targets = query.call(["--targets-built"])
      library_root = File.join(build, "llvm/lib") + "/"
      libfiles = query.call(["--link-static", "--libfiles"]).split
      libfiles.each do |file|
        unless file.starts_with?(library_root) && File.file?(file)
          raise Error.new("frappe lsp: llvm-config named a library outside the pinned LLVM: #{file}")
        end
      end
      system_libs = query.call(["--link-static", "--system-libs"]).split
      system_libs.each do |flag|
        raise Error.new("frappe lsp: unexpected llvm-config system library flag: #{flag}") unless flag.starts_with?("-l")
      end
      {targets, libfiles, system_libs}
    end

    private def fetch_crystalline(source : String, pin : CrystallinePin) : Nil
      git = "/usr/bin/git"
      run!([git, "init", "-q", source], "git init failed", 600.seconds)
      run!([git, "-C", source, "fetch", "--depth", "1", pin.git, pin.commit], "could not fetch #{pin.git} #{pin.commit}", 600.seconds)
      run!([git, "-C", source, "checkout", "-q", "--detach", "FETCH_HEAD"], "could not check out #{pin.commit}", 600.seconds)
      head = run!([git, "-C", source, "rev-parse", "HEAD"], "git rev-parse failed", 600.seconds).stdout.strip
      raise Error.new("frappe lsp: fetched crystalline #{head}, expected #{pin.commit}") unless head == pin.commit
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

    private def write_pointer(root : String) : Nil
      destination = File.join(@framework_root, ".caramel-toolchain")
      temporary = File.join(@framework_root, ".caramel-toolchain.#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temporary, root + "\n", perm: 0o644)
        File.rename(temporary, destination)
      ensure
        File.delete?(temporary)
      end
    end

    private def download(url : String, path : String, sha256 : String) : Nil
      result = Latte::ProcessRunner.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "600", "--retry", "2", "--output", path, url], timeout: 660.seconds)
      raise Error.new("frappe lsp: download failed: #{url}") unless result.success? && File.file?(path)
      raise Error.new("frappe lsp: checksum mismatch for #{url}; nothing was installed") unless digest(path) == sha256
    end

    private def run!(command : Array(String), failure : String, timeout : Time::Span = 120.seconds) : Latte::ProcessResult
      result = Latte::ProcessRunner.run(command, timeout: timeout)
      raise Error.new("frappe lsp: #{failure}: #{result.stderr.strip}") unless result.success?
      result
    end

    # Port of verifyNativeOutput in tools/installer/install_toolchain.swift: every image
    # dyld loads must come from the toolchain root or macOS itself.
    private def verify_libraries(root : String, command : Array(String), expected : String) : Array(String)
      env = {"PATH" => "/usr/bin:/bin", "HOME" => ENV["HOME"]?, "DYLD_PRINT_LIBRARIES" => "1"} of String => String?
      result = Latte::ProcessRunner.run(command, env: env, clear_env: true, chdir: root, timeout: 20.seconds, output_limit: 1_048_576)
      unless result.success? && result.stdout.starts_with?(expected)
        raise Error.new("frappe lsp: #{command[0]} did not report #{expected}")
      end
      libraries = [] of String
      result.stderr.each_line do |line|
        next unless match = DYLD_LINE.match(line)
        # Shared-cache images have no file on disk; keep their lexical path.
        path = File.realpath(match[1]) rescue Path[match[1]].normalize.to_s
        unless path.starts_with?(root + "/") || SYSTEM_LIBRARY_PREFIXES.any? { |prefix| path.starts_with?(prefix) }
          raise Error.new("frappe lsp: #{command[0]} loaded a library outside Caramel or macOS: #{path}")
        end
        libraries << path
      end
      raise Error.new("frappe lsp: #{command[0]} produced no library evidence") if libraries.empty?
      libraries.uniq.sort
    end

    private def require_complete(root : String) : Nil
      complete = begin
        JSON.parse(File.read(File.join(root, ".caramel-toolchain.json")))["status"]?.try(&.as_s?) == "complete"
      rescue JSON::ParseException | File::Error
        false
      end
      raise Error.new("frappe lsp: #{root} is not a completed Caramel toolchain") unless complete
    end

    private def crystal_directory(root : String) : String
      version = manifest.crystalline.crystal
      crystal = File.join(root, "data/installs/github-crystal-lang-crystal", version)
      unless File.file?(File.join(crystal, "embedded/bin/crystal"))
        raise Error.new("frappe lsp: #{root} does not provide Crystal #{version} required by Caramel at #{@framework_root}")
      end
      crystal
    end

    private def ameba_directory(root : String) : String
      File.join(root, "editor/ameba-ls", manifest.ameba_ls.version)
    end

    private def crystalline_directory(root : String) : String
      File.join(root, "editor/crystalline", "#{manifest.crystalline.reported_version}-#{crystalline_fingerprint}")
    end

    private def pointer_line : String?
      path = File.join(@framework_root, ".caramel-toolchain")
      return nil unless File.file?(path)
      File.read(path).lines.first?.try(&.strip)
    end

    private def not_installed(name : String, version : String, root : String) : NoReturn
      raise Error.new("frappe lsp: #{name} #{version} is not installed in #{root} for Caramel at #{@framework_root}. Run frappe lsp install.")
    end

    private def failed_verification(binary : String, directory : String) : NoReturn
      raise Error.new("frappe lsp: #{binary} failed verification; remove #{directory} and run frappe lsp install.")
    end

    private def owned?(path : String, *, directory : Bool) : Bool
      info = File.info?(path, follow_symlinks: false)
      return false unless info && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64
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
