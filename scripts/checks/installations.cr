require "./support/harness"
require "../../src/caramel/version"

# ADR 0016: `frappe installations install VERSION` clones a release tag,
# installs its toolchain (reusing this one when it pins the same), builds it
# and registers it, and a project pinned to that release runs its Frappé. A
# repository of this working tree tagged v9.9.9 stands in for
# github.com/caramelizedev/caramel; HOME and CARAMEL_HOME are private, so this
# Mac's launchers and registry stay as they are.
module Caramel::Checks::Installations
  extend self

  RELEASE = "9.9.9"
  FRAPPE  = File.join(Checks::REPO, "bin/frappe")

  def main : Int32
    root = Checks.private_temp("caramel-installations-")
    begin
      repository = Checks.tagged_repository(File.join(root, "caramel.git"), RELEASE)
      home = File.join(root, "home")
      Dir.mkdir(home, 0o700)
      state = File.join(root, "state")
      env = {"HOME" => home, "CARAMEL_HOME" => state, "CARAMEL_REPOSITORY" => "file://#{repository}", "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin"} of String => String?
      frappe = ->(arguments : Array(String), directory : String) { Checks.run([FRAPPE] + arguments, chdir: directory, env: env, clear_env: true, timeout: 1800.seconds) }

      installed = frappe.call(["installations", "install", RELEASE], root)
      Checks.fail("frappe installations install failed:\n#{installed.stdout}#{installed.stderr}") unless installed.success?
      release = File.join(state, "releases", RELEASE)
      version = Checks.run([File.join(release, "bin/frappe"), "version"], env: env, clear_env: true)
      Checks.fail("the installed release reports #{version.stdout.inspect}") unless version.stdout == "Frappé #{RELEASE}\n"
      Checks.fail("the installed release lacks its linter: #{File.join(release, "bin/frappe-lint")}") unless File.file?(File.join(release, "bin/frappe-lint"))
      recorded = File.read(File.join(release, ".caramel-toolchain")).strip
      selection = ->(toolchain : String) { JSON.parse(File.read(File.join(toolchain, ".caramel-toolchain.json")))["selection"] }
      if selection.call(recorded) == selection.call(Checks.toolchain_root) && recorded != Checks.toolchain_root
        Checks.fail("the release installed #{recorded} instead of reusing this toolchain, which pins the same selection")
      end
      listed = frappe.call(["installations"], root).stdout
      Checks.fail("frappe installations lists #{listed.inspect}") unless listed.includes?("#{RELEASE.ljust(12)} #{release}")
      launcher = File.read(File.join(home, ".local/bin/frappe"))
      Checks.fail("the launcher does not run the newest release: #{launcher}") unless launcher.includes?(File.join(release, "bin/frappe"))
      again = frappe.call(["installations", "install", RELEASE], root)
      Checks.fail(again.stdout + again.stderr) unless again.success? && again.stdout.includes?("Caramel #{RELEASE} is already installed")
      puts "PASS: frappe installations install #{RELEASE} clones the tag, reuses this toolchain, builds it and its linter, registers and points the launchers at it"

      pinned = project(root, "pinned", RELEASE)
      doctor = frappe.call(["doctor"], pinned)
      Checks.fail("the pinned project did not run Frappé #{RELEASE}:\n#{doctor.stdout}#{doctor.stderr}") unless doctor.stdout.starts_with?("OK    Project configuration\n")
      missing = frappe.call(["doctor"], project(root, "missing", "9.9.8"))
      unless missing.status.exit_code == 1 && missing.stderr.includes?("Install it: frappe installations install 9.9.8")
        Checks.fail("an uninstalled pin did not name its install command:\n#{missing.stderr}")
      end
      puts "PASS: a project pinned to #{RELEASE} runs that release's Frappé, and one pinned to an uninstalled release is told how to install it"
      0
    ensure
      FileUtils.rm_rf(root)
    end
  end

  private def project(root : String, name : String, release : String) : String
    directory = File.join(root, name)
    Dir.mkdir_p(File.join(directory, "config"))
    File.write(File.join(directory, "config/environment.yml"), "version: 1\nname: #{name}\npostgresql_major: 18\nextensions: []\ndomain_suffix: test\n")
    File.write(File.join(directory, "shard.lock"), "version: 2.0\nshards:\n  caramel:\n    git: https://github.com/caramelizedev/caramel.git\n    version: #{release}\n")
    directory
  end
end

exit Caramel::Checks::Installations.main
