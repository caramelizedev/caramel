require "json"
require "./project"
require "./tools"
require "./mrdp"

module Caramel::Frappe
  # `frappe lint` (ADR 0017): checks the application against the RFC-0008
  # rule set in its .ameba.yml. The linter, Ameba plus Caramel's own rules,
  # is built in the installation on first use and again after its sources
  # change. It reports and never rewrites: some of Ameba's corrections
  # change behaviour.
  class Lint
    def initialize(@project : Project, @tools : Tools, @output : IO, @error : IO)
    end

    def run(agent : Bool, color : Bool) : Int32
      linter = build
      unless agent
        options = color ? [] of String : ["--no-color"]
        status = Process.run(linter, options, chdir: @project.root, env: @tools.environment, clear_env: true,
          input: Process::Redirect::Close, output: @output, error: @error)
        return status.success? ? 0 : 1
      end
      report = IO::Memory.new
      failure = IO::Memory.new
      Process.run(linter, ["--format", "json", "--no-color"], chdir: @project.root, env: @tools.environment, clear_env: true,
        input: Process::Redirect::Close, output: report, error: failure)
      document = begin
        JSON.parse(report.to_s)
      rescue JSON::ParseException
        raise Error.new("frappe lint: the linter failed. #{failure.to_s.strip}")
      end
      issues = 0
      document["sources"].as_a.each do |source|
        source["issues"].as_a.each do |issue|
          mrdp(source["path"].as_s, issue)
          issues += 1
        end
      end
      @output.puts("OK lint #{document["summary"]["target_sources_count"]} files") if issues.zero?
      issues.zero? ? 0 : 1
    end

    # `LINT_<RULE>`: the rule's group and name in upper snake case, so
    # `Caramel/ServiceNoun` is `LINT_CARAMEL_SERVICE_NOUN`. MSG ends with the
    # rule's own name for `# ameba:disable` directives.
    private def mrdp(path : String, issue : JSON::Any) : Nil
      rule = issue["rule_name"].as_s
      code = "LINT_" + rule.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").tr("/", "_").upcase
      fields = [{"MSG", "#{issue["message"].as_s} (#{rule})"}]
      fields << {"FIX", "frappe format"} if rule == "Lint/Formatting"
      MRDP.write(@output, code, "#{path}:#{issue["location"]["line"]}:#{issue["location"]["column"]}", fields)
    end

    private def build : String
      root = @tools.framework_root
      linter = File.join(root, "bin/frappe-lint")
      built = File.info?(linter).try(&.modification_time)
      sources = Dir.glob(File.join(root, "src/frappe/lint/*.cr")) + [File.join(root, "src/frappe_lint.cr"), File.join(root, "shard.lock")]
      return linter if built && sources.all? { |path| File.info(path).modification_time <= built }
      @error.puts("Building the linter; the first build takes about a minute.")
      status = Process.run(File.join(root, "scripts/build-lint"), chdir: root, env: @tools.environment, clear_env: true,
        input: Process::Redirect::Close, output: @error, error: @error)
      raise Error.new("frappe lint: the linter did not build; see the output above") unless status.success?
      linter
    end
  end
end
