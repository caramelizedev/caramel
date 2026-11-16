require "file_utils"
require "../../../src/frappe/published"

# A git repository that stands in for Caramel's: one commit of a framework that
# publishes two shards, `caramel` from selected paths and `extra` from a directory.
module ReleaseCheckout
  # The commit's date, which its published commits take.
  SECONDS = 1_790_000_000

  # Git here is untouched by the configuration of the machine that runs the specs.
  ENVIRONMENT = {
    "GIT_CONFIG_GLOBAL"   => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_AUTHOR_NAME"     => "Caramel specs",
    "GIT_AUTHOR_EMAIL"    => "specs@caramel.invalid",
    "GIT_COMMITTER_NAME"  => "Caramel specs",
    "GIT_COMMITTER_EMAIL" => "specs@caramel.invalid",
    "GIT_AUTHOR_DATE"     => "@#{SECONDS} +0200",
    "GIT_COMMITTER_DATE"  => "@#{SECONDS} +0200",
  } of String => String?

  DECLARATION = <<-YAML
    caramel:
      repository: example/caramel-published
      paths:
        - LICENSE
        - shard.yml
        - src/caramel/
      readme: |
        # Caramel, as published
    extra:
      repository: example/extra
      root: extra

    YAML

  # Bytes git would convert were it asked to: a carriage return, and no valid UTF-8.
  SCRIPT = "htmx.on('load', run)\r\n\xFF\xFE\n"

  # The files of the commit, for a framework at *version*.
  def self.files(version : String) : Hash(String, String)
    {
      "published.yml"          => DECLARATION,
      "LICENSE"                => "MIT License\n",
      "shard.yml"              => "name: caramel\nversion: #{version}\n",
      "src/caramel/view.cr"    => "module Caramel\nend\n",
      "src/caramel/islands.js" => SCRIPT,
      "src/caramel/tool"       => "#!/bin/sh\n",
      "docs/notes.txt"         => "not published\n",
      "extra/LICENSE"          => "MIT License\n",
      "extra/shard.yml"        => <<-YAML,
        name: extra
        version: #{version}
        dependencies:
          caramel:
            github: example/caramel-published
            version: #{version}

        YAML
    }
  end

  # Yields a repository whose one commit holds `files(version)`. It carries no tag.
  def self.create(version : String, & : String ->) : Nil
    repository = File.tempname("caramel-release-checkout-", dir: "/private/tmp")
    Dir.mkdir(repository, 0o700)
    begin
      files(version).each { |path, content| write(repository, path, content) }
      File.chmod(File.join(repository, "src/caramel/tool"), 0o755)
      git(repository, "init", "--quiet", "--initial-branch=main")
      git(repository, "add", "--all")
      git(repository, "commit", "--quiet", "--message", "release")
      yield File.realpath(repository)
    ensure
      FileUtils.rm_rf(repository)
    end
  end

  def self.write(repository : String, path : String, content : String) : Nil
    file = File.join(repository, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, content)
  end

  def self.git(repository : String, *arguments : String) : String
    command = ["/usr/bin/git", "-C", repository] + arguments.to_a
    result = Caramel::Latte::ProcessRunner.run(command, env: ENVIRONMENT, timeout: 30.seconds)
    raise "git #{arguments.join(' ')}: #{result.stderr}" unless result.success?
    result.stdout
  end

  # Every file under *directory* but git's own, by path: its bytes and whether it is
  # executable.
  def self.tree(directory : String) : Hash(String, {Bytes, Bool})
    paths = Dir.glob(File.join(directory, "**/*"), match: :dot_files).select do |path|
      File.file?(path) && !path.starts_with?(File.join(directory, ".git", ""))
    end
    paths.sort.to_h do |path|
      executable = File.info(path).permissions.owner_execute?
      {Path[path].relative_to(directory).to_s, {File.open(path, &.getb_to_end), executable}}
    end
  end
end
