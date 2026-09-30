require "./support/harness"
require "../../src/caramel/version"

# ADR 0016: `frappe installations install VERSION` clones a release tag,
# installs its toolchain (reusing this one when it pins the same), builds it
# with its own scripts/build-release and registers it, and a project pinned to
# that release runs its Frappé. Installing it again builds a linter it lacks.
# A repository of this working tree tagged v9.9.9 stands in for
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
      env = {
        "HOME"               => home,
        "CARAMEL_HOME"       => state,
        "CARAMEL_REPOSITORY" => "file://#{repository}",
        "PATH"               => "/usr/bin:/bin:/usr/sbin:/sbin",
      } of String => String?
      frappe = ->(arguments : Array(String), directory : String) do
        Checks.run([FRAPPE] + arguments,
          chdir: directory, env: env, clear_env: true, timeout: 1800.seconds)
      end

      installed = frappe.call(["installations", "install", RELEASE], root)
      unless installed.success?
        Checks.fail("frappe installations install failed:\n" \
                    "#{installed.stdout}#{installed.stderr}")
      end
      release = File.join(state, "releases", RELEASE)
      installed_frappe = File.join(release, "bin/frappe")
      version = Checks.run([installed_frappe, "version"], env: env, clear_env: true)
      unless version.stdout == "Frappé #{RELEASE}\n"
        Checks.fail("the installed release reports #{version.stdout.inspect}")
      end
      linter = File.join(release, "bin/frappe-lint")
      unless File.file?(linter)
        Checks.fail("the installed release lacks its linter: #{linter}")
      end
      recorded = File.read(File.join(release, ".caramel-toolchain")).strip
      selection = ->(toolchain : String) do
        manifest = File.join(toolchain, ".caramel-toolchain.json")
        JSON.parse(File.read(manifest))["selection"]
      end
      current = Checks.toolchain_root
      if selection.call(recorded) == selection.call(current) && recorded != current
        Checks.fail("the release installed #{recorded} " \
                    "instead of reusing this toolchain, which pins the same selection")
      end
      listed = frappe.call(["installations"], root).stdout
      unless listed.includes?("#{RELEASE.ljust(12)} #{release}")
        Checks.fail("frappe installations lists #{listed.inspect}")
      end
      launcher = File.read(File.join(home, ".local/bin/frappe"))
      unless launcher.includes?(File.join(release, "bin/frappe"))
        Checks.fail("the launcher does not run the newest release: #{launcher}")
      end
      again = frappe.call(["installations", "install", RELEASE], root)
      already = again.stdout.includes?("Caramel #{RELEASE} is already installed")
      Checks.fail(again.stdout + again.stderr) unless again.success? && already
      puts "PASS: frappe installations install #{RELEASE} clones the tag, " \
           "reuses this toolchain, builds it and its linter, " \
           "registers and points the launchers at it"

      pinned = project(root, "pinned", RELEASE)
      doctor = frappe.call(["doctor"], pinned)
      unless doctor.stdout.starts_with?("OK    Project configuration\n")
        Checks.fail("the pinned project did not run Frappé #{RELEASE}:\n" \
                    "#{doctor.stdout}#{doctor.stderr}")
      end
      unless doctor.stdout.includes?("OK    Caramel installation\n")
        Checks.fail("frappe doctor did not accept the installed release:\n" \
                    "#{doctor.stdout}")
      end
      missing = frappe.call(["doctor"], project(root, "missing", "9.9.8"))
      hint = "Install it: frappe installations install 9.9.8"
      unless missing.status.exit_code == 1 && missing.stderr.includes?(hint)
        Checks.fail("an uninstalled pin did not name its install command:\n#{missing.stderr}")
      end
      puts "PASS: a project pinned to #{RELEASE} runs that release's Frappé, " \
           "and one pinned to an uninstalled release is told how to install it"

      File.delete(linter)
      unfinished = frappe.call(["doctor"], pinned).stdout
      expected = "CHECK Caramel installation: Caramel #{RELEASE} " \
                 "was installed without its linter; " \
                 "finish it: frappe installations install #{RELEASE}\n"
      unless unfinished.includes?(expected)
        Checks.fail("frappe doctor did not name the install " \
                    "that builds a missing linter:\n#{unfinished}")
      end
      finished = frappe.call(["installations", "install", RELEASE], root)
      done = "Finished installing Caramel #{RELEASE}: #{release}"
      unless finished.success? && finished.stdout.includes?(done) && File.file?(linter)
        Checks.fail("installing #{RELEASE} again did not build its missing linter:\n" \
                    "#{finished.stdout}#{finished.stderr}")
      end
      healed = frappe.call(["doctor"], pinned).stdout
      unless healed.includes?("OK    Caramel installation\n")
        Checks.fail("frappe doctor still reports the linter missing:\n#{healed}")
      end
      puts "PASS: a release installed without its linter makes frappe doctor " \
           "name frappe installations install #{RELEASE}, which builds it"
      0
    ensure
      FileUtils.rm_rf(root)
    end
  end

  private def project(root : String, name : String, release : String) : String
    directory = File.join(root, name)
    Dir.mkdir_p(File.join(directory, "config"))
    # Each file ends with a newline: the blank line before its terminator.
    File.write(File.join(directory, "config/environment.yml"), <<-YAML)
      version: 1
      name: #{name}
      postgresql_major: 18
      extensions: []
      domain_suffix: test

      YAML
    File.write(File.join(directory, "shard.lock"), <<-YAML)
      version: 2.0
      shards:
        caramel:
          git: https://github.com/caramelizedev/caramel.git
          version: #{release}

      YAML
    directory
  end
end

exit Caramel::Checks::Installations.main
