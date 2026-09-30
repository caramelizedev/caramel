require "./support/lsp"

module EditorCheck
  alias LSPClient = Caramel::Checks::LSPClient

  REPO    = Caramel::Checks::REPO
  FRAPPE  = File.join(REPO, "bin/frappe")
  POINTER = File.join(REPO, ".caramel-toolchain")
  unless File.file?(FRAPPE) && File.file?(POINTER)
    Caramel::Checks.fail("run scripts/install-toolchain, scripts/build-frappe " \
                         "and bin/frappe lsp install first")
  end
  ROOT     = File.read(POINTER).lines.first.strip
  CRYSTAL  = File.join(ROOT, "data/installs/github-crystal-lang-crystal/1.21.1")
  MANIFEST = JSON.parse(File.read(File.join(REPO, "tools/editor-darwin-arm64.json")))
  VERSIONS = {"ameba-ls"    => MANIFEST["ameba-ls"]["version"].as_s,
              "crystalline" => MANIFEST["crystalline"]["reported_version"].as_s}
  HOME = ENV["HOME"]
  # shard.lock's caramel entry; the group ends where its version begins.
  CARAMEL_PIN = /(  caramel:\n    [^\n]+\n    version: )[^\n]+/

  def self.expect_startup(client : LSPClient, source : String) : Nil
    marker = "frappe lsp: #{client.name} #{VERSIONS[client.name]}"
    compiler_path = "PATH=#{CRYSTAL}/embedded/bin:#{ROOT}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    binary_path = File.join(ROOT, "editor", client.name) + "/"
    expected = [marker, "(from #{source})", compiler_path, binary_path]
    started = Caramel::Checks.wait_until(10.seconds, 100.milliseconds) do
      text = client.stderr_text
      expected.all? { |part| text.includes?(part) }
    end
    return if started

    client.fail("startup line missing #{marker.inspect}, (from #{source}), " \
                "or pinned binary/compiler paths")
  end

  def self.check_ameba(cwd : String,
                       env : Hash(String, String?),
                       source : String,
                       path : String,
                       label : String) : Nil
    client = LSPClient.new("ameba-ls", cwd, env)
    begin
      expect_startup(client, source)
      text = File.read(path) + "pp! 1\n"
      client.open(path, text)
      lint = ->(item : JSON::Any) { item["code"]?.try(&.as_s?) == "Lint/DebugCalls" }
      unless client.wait_diagnostics(path, 30.seconds, &lint)
        saved = {"textDocument" => {"uri" => LSPClient.uri(path)}, "text" => text}
        client.notify("textDocument/didSave", saved)
        unless client.wait_diagnostics(path, 30.seconds, &lint)
          found = client.diagnostics[File.realpath(path)]?
          client.fail("no Lint/DebugCalls diagnostic: #{found.inspect}")
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
      env = {
        "HOME"         => HOME,
        "PATH"         => "/usr/bin:/bin",
        "CRYSTAL_PATH" => "/wrong",
        "BASH_ENV"     => bash_env,
      } of String => String?
      navigation = File.join(REPO, "spec/fixtures/editor/navigation.cr")
      label = "ameba-ls #{VERSIONS["ameba-ls"]} lint diagnostics"
      check_ameba(REPO, env, ".caramel-toolchain", navigation, label)
      client = LSPClient.new("crystalline", REPO, env)
      begin
        expect_startup(client, ".caramel-toolchain")
        text = client.open(navigation)
        response = File.join(REPO, "src/caramel/response.cr")
        at_response = LSPClient.position(text, "Caramel::Response", 11)
        client.definition_until(navigation, at_response, 180.seconds) do |item|
          item == response
        end
        puts "PASS: crystalline definition into project source"
        stdlib = File.realpath(File.join(CRYSTAL, "src")) + "/"
        at_puts = LSPClient.position(text, "puts", 1)
        client.definition_until(navigation, at_puts, 180.seconds) do |item|
          item.starts_with?(stdlib)
        end
        puts "PASS: crystalline definition into pinned Crystal 1.21.1 stdlib"
        at_argument = LSPClient.position(text, "puts response", 6)
        hover = client.at("textDocument/hover", navigation, at_argument, 60.seconds)
        unless hover.to_json.includes?("Response")
          client.fail("hover lacks Response: #{hover.to_json}")
        end
        puts "PASS: crystalline hover"
        at_member = LSPClient.position(text, "response.status", "response.".size)
        completion = client.at("textDocument/completion", navigation, at_member, 60.seconds)
        items = if values = completion.try(&.as_a?)
                  values
                else
                  completion.try { |result| result["items"]?.try(&.as_a?) } || [] of JSON::Any
                end
        labels = items.compact_map { |item| item["label"]?.try(&.as_s?) }
        unless labels.any?(&.starts_with?("status"))
          client.fail("completion lacks status: #{completion.to_json[0, 2000]}")
        end
        puts "PASS: crystalline completion"
        type_error = File.join(REPO, "spec/fixtures/editor/type_error.cr")
        client.open(type_error)
        client.save(type_error)
        reported = client.wait_diagnostics(type_error, 180.seconds) do |item|
          item["severity"]?.try(&.as_i?) == 1 && item.to_json.includes?("double")
        end
        unless reported
          found = client.diagnostics[File.realpath(type_error)]?
          client.fail("no error diagnostic for type_error.cr: #{found.to_json}")
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
      generator = "spec/fixtures/generate_project.cr"
      generate = Caramel::Checks.crystal(["run", generator, "--", project],
        env: build_env, timeout: 600.seconds)
      raise "Project generation failed: #{generate.stderr}" unless generate.success?
      install = Caramel::Checks.shards(["install", "--frozen"],
        chdir: project, env: build_env, timeout: 900.seconds)
      raise "Project dependency installation failed: #{install.stderr}" unless install.success?
      env = {
        "HOME"                   => HOME,
        "PATH"                   => "/usr/bin:/bin",
        "CARAMEL_TOOLCHAIN_ROOT" => ROOT,
      } of String => String?
      show = File.join(project, "app/actions/home/show.cr")
      label = "frappe lsp ameba-ls lint diagnostics in an application"
      check_ameba(project, env, "CARAMEL_TOOLCHAIN_ROOT", show, label)
      client = LSPClient.new("crystalline", project, env)
      begin
        expect_startup(client, "CARAMEL_TOOLCHAIN_ROOT")
        text = client.open(show)
        action = File.realpath(File.join(project, "app/actions/application_action.cr"))
        at_parent = LSPClient.position(text, "ApplicationAction", 2)
        client.definition_until(show, at_parent, 300.seconds) { |item| item == action }
        puts "PASS: frappe lsp crystalline definition into application source"
        # An unreleased checkout is a path dependency: lib/caramel resolves to it.
        framework = File.join(REPO, "src/caramel/action.cr")
        at_page = LSPClient.position(text, "page \"Welcome\"", 1)
        client.definition_until(show, at_page, 180.seconds) do |item|
          item.ends_with?("/bookshelf/lib/caramel/src/caramel/action.cr") || item == framework
        end
        puts "PASS: frappe lsp crystalline definition into the project's Caramel dependency"
      ensure
        client.close
      end
      lock = File.join(project, "shard.lock")
      mismatched = File.read(lock).sub(CARAMEL_PIN) { |_, match| "#{match[1]}0.0.0" }
      File.write(lock, mismatched)
      isolated = env.merge({"CARAMEL_HOME" => parent})
      refused = Caramel::Checks.run([FRAPPE, "lsp", "ameba-ls"],
        chdir: project, env: isolated, clear_env: true, timeout: 30.seconds)
      refusal = "no Caramel installation is registered for it"
      unless refused.status.exit_code == 1 && refused.stderr.includes?(refusal)
        raise "Frappé accepted a mismatched version: #{refused.stderr}"
      end
      puts "PASS: frappe lsp refuses a project pinned to another Caramel version"
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

EditorCheck.framework_phase
EditorCheck.application_phase
puts "PASS: both launchers pin the compiler and toolchain in both contexts"
