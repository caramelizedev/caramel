require "./support/lsp"

module EditorCheck
  REPO     = Caramel::Checks::REPO
  FRAPPE   = File.join(REPO, "bin/frappe")
  POINTER  = File.join(REPO, ".caramel-toolchain")
  Caramel::Checks.fail("run scripts/install-toolchain, scripts/build-frappe and bin/frappe lsp install first") unless File.file?(FRAPPE) && File.file?(POINTER)
  ROOT = File.read(POINTER).lines.first.strip
  CRYSTAL = File.join(ROOT, "data/installs/github-crystal-lang-crystal/1.21.0")
  MANIFEST = JSON.parse(File.read(File.join(REPO, "tools/editor-darwin-arm64.json")))
  VERSIONS = {"ameba-ls"    => MANIFEST["ameba-ls"]["version"].as_s,
              "crystalline" => MANIFEST["crystalline"]["reported_version"].as_s}
  HOME = ENV["HOME"]

  def self.expect_startup(client : Caramel::Checks::LSPClient, source : String) : Nil
    marker = "frappe lsp: #{client.name} #{VERSIONS[client.name]}"
    compiler_path = "PATH=#{CRYSTAL}/embedded/bin:#{ROOT}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    binary_path = File.join(ROOT, "editor", client.name) + "/"
    return if Caramel::Checks.wait_until(10.seconds, 100.milliseconds) do
                text = client.stderr_text
                [marker, "(from #{source})", compiler_path, binary_path].all? { |part| text.includes?(part) }
              end
    client.fail("startup line missing #{marker.inspect}, (from #{source}), or pinned binary/compiler paths")
  end

  def self.check_ameba(cwd : String, env : Hash(String, String?), source : String, path : String, label : String) : Nil
    client = Caramel::Checks::LSPClient.new("ameba-ls", cwd, env)
    begin
      expect_startup(client, source)
      text = File.read(path) + "pp! 1\n"
      client.open(path, text)
      lint = ->(item : JSON::Any) { item["code"]?.try(&.as_s?) == "Lint/DebugCalls" }
      unless client.wait_diagnostics(path, 30.seconds, &lint)
        client.notify("textDocument/didSave", {"textDocument" => {"uri" => Caramel::Checks::LSPClient.uri(path)}, "text" => text})
        unless client.wait_diagnostics(path, 30.seconds, &lint)
          client.fail("no Lint/DebugCalls diagnostic: #{client.diagnostics[File.realpath(path)]?.inspect}")
        end
      end
      puts "PASS: #{label}"
    ensure
      client.close
    end
  end

  def self.framework_phase : Nil
    scratch = Caramel::Checks.private_temp("caramel-editor-env-")
    begin
      bash_env = File.join(scratch, "bash_env")
      File.write(bash_env, "export CRYSTAL_PATH=/wrong\n")
      env = {"HOME" => HOME, "PATH" => "/usr/bin:/bin", "CRYSTAL_PATH" => "/wrong", "BASH_ENV" => bash_env} of String => String?
      navigation = File.join(REPO, "spec/fixtures/editor/navigation.cr")
      check_ameba(REPO, env, ".caramel-toolchain", navigation, "ameba-ls #{VERSIONS["ameba-ls"]} lint diagnostics")
      client = Caramel::Checks::LSPClient.new("crystalline", REPO, env)
      begin
        expect_startup(client, ".caramel-toolchain")
        text = client.open(navigation)
        response = File.join(REPO, "src/caramel/response.cr")
        client.definition_until(navigation, Caramel::Checks::LSPClient.position(text, "Caramel::Response", 11), 180.seconds) { |item| item == response }
        puts "PASS: crystalline definition into project source"
        stdlib = File.realpath(File.join(CRYSTAL, "src")) + "/"
        client.definition_until(navigation, Caramel::Checks::LSPClient.position(text, "puts", 1), 180.seconds) { |item| item.starts_with?(stdlib) }
        puts "PASS: crystalline definition into pinned Crystal 1.21.0 stdlib"
        hover = client.at("textDocument/hover", navigation, Caramel::Checks::LSPClient.position(text, "puts response", 6), 60.seconds)
        client.fail("hover lacks Response: #{hover.to_json}") unless hover.to_json.includes?("Response")
        puts "PASS: crystalline hover"
        completion = client.at("textDocument/completion", navigation, Caramel::Checks::LSPClient.position(text, "response.status", "response.".size), 60.seconds)
        items = if values = completion.try(&.as_a?)
                  values
                else
                  completion.try { |result| result["items"]?.try(&.as_a?) } || [] of JSON::Any
                end
        unless items.any? { |item| item["label"]?.try(&.as_s?).try(&.starts_with?("status")) == true }
          client.fail("completion lacks status: #{completion.to_json[0, 2000]}")
        end
        puts "PASS: crystalline completion"
        type_error = File.join(REPO, "spec/fixtures/editor/type_error.cr")
        client.open(type_error)
        client.save(type_error)
        unless client.wait_diagnostics(type_error, 180.seconds) { |item| item["severity"]?.try(&.as_i?) == 1 && item.to_json.includes?("double") }
          client.fail("no error diagnostic for type_error.cr: #{client.diagnostics[File.realpath(type_error)]?.to_json}")
        end
        puts "PASS: crystalline diagnostics on save"
      ensure
        client.close
      end
    ensure
      FileUtils.rm_rf(scratch)
    end
  end

  def self.application_phase : Nil
    parent = Caramel::Checks.private_temp("caramel-editor-app-")
    begin
      project = File.join(parent, "bookshelf")
      build_env = Hash(String, String?).new
      ENV.each { |key, value| build_env[key] = value }
      build_env["CARAMEL_TOOLCHAIN_ROOT"] = ROOT
      generate = Caramel::Checks.crystal(["run", "spec/fixtures/generate_project.cr", "--", project], env: build_env, timeout: 600.seconds)
      raise "Project generation failed: #{generate.stderr}" unless generate.success?
      install = Caramel::Checks.shards(["install", "--frozen"], chdir: project, env: build_env, timeout: 900.seconds)
      raise "Project dependency installation failed: #{install.stderr}" unless install.success?
      env = {"HOME" => HOME, "PATH" => "/usr/bin:/bin", "CARAMEL_TOOLCHAIN_ROOT" => ROOT} of String => String?
      show = File.join(project, "app/actions/home/show.cr")
      check_ameba(project, env, "CARAMEL_TOOLCHAIN_ROOT", show, "frappe lsp ameba-ls lint diagnostics in an application")
      client = Caramel::Checks::LSPClient.new("crystalline", project, env)
      begin
        expect_startup(client, "CARAMEL_TOOLCHAIN_ROOT")
        text = client.open(show)
        action = File.realpath(File.join(project, "app/actions/application_action.cr"))
        client.definition_until(show, Caramel::Checks::LSPClient.position(text, "ApplicationAction", 2), 300.seconds) { |item| item == action }
        puts "PASS: frappe lsp crystalline definition into application source"
        # An unreleased checkout is a path dependency: lib/caramel resolves to it.
        framework = File.join(REPO, "src/caramel/action.cr")
        client.definition_until(show, Caramel::Checks::LSPClient.position(text, "page \"Welcome\"", 1), 180.seconds) do |item|
          item.ends_with?("/bookshelf/lib/caramel/src/caramel/action.cr") || item == framework
        end
        puts "PASS: frappe lsp crystalline definition into the project's Caramel dependency"
      ensure
        client.close
      end
      lock = File.join(project, "shard.lock")
      File.write(lock, File.read(lock).sub(/(  caramel:\n    [^\n]+\n    version: )[^\n]+/) { |_, match| "#{match[1]}0.0.0" })
      refused = Caramel::Checks.run([FRAPPE, "lsp", "ameba-ls"], chdir: project, env: env.merge({"CARAMEL_HOME" => parent}), clear_env: true, timeout: 30.seconds)
      raise "Frappé accepted a mismatched version: #{refused.stderr}" unless refused.status.exit_code == 1 && refused.stderr.includes?("no Caramel installation is registered for it")
      puts "PASS: frappe lsp refuses a project pinned to another Caramel version"
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

EditorCheck.framework_phase
EditorCheck.application_phase
puts "PASS: both launchers pin the compiler and toolchain in both contexts"
