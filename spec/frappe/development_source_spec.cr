require "spec"
require "./support/release_checkout"
require "../../src/frappe/development_source"

private VERSION = Caramel::VERSION

# Yields a project whose shard.yml takes caramel from *manifest* and whose shard.lock
# takes it from *lock*, each a source line as the file states it.
private def project(manifest : String, lock : String, & : String ->) : Nil
  root = File.tempname("caramel-development-source-", dir: "/private/tmp")
  Dir.mkdir(root, 0o700)
  begin
    File.write(File.join(root, "shard.yml"), <<-YAML)
      name: shelf
      version: 0.1.0
      dependencies:
        caramel:
          #{manifest}
          version: "~> #{VERSION}"

      YAML
    File.write(File.join(root, "shard.lock"), <<-YAML)
      version: 2.0
      shards:
        caramel:
          #{lock}
          version: #{VERSION}+git.commit.#{"0" * 40}

        pg:
          git: https://github.com/will/crystal-pg.git
          version: 0.31.0

      YAML
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

# Yields a Caramel installation that is its clean release tag, and the commit its
# caramel shard is published at.
private def release(& : String, String ->) : Nil
  ReleaseCheckout.create(VERSION) do |framework|
    ReleaseCheckout.git(framework, "tag", "v#{VERSION}")
    yield framework, Caramel::Frappe::Published.assembled(framework, "HEAD", &.["caramel"].commit)
  end
end

private DEVELOPMENT      = "github: caramelizedev/caramel"
private DEVELOPMENT_LOCK = "git: https://github.com/caramelizedev/caramel.git"
private PUBLISHED        = "github: example/caramel-published"
private PUBLISHED_LOCK   = "git: https://github.com/example/caramel-published.git"

describe Caramel::Frappe::DevelopmentSource do
  it "tells a project on the development repository the two entries to write, " \
     "with the release's published commit, and changes neither file" do
    release do |framework, commit|
      project(DEVELOPMENT, DEVELOPMENT_LOCK) do |root|
        files = %w[shard.yml shard.lock].map { |file| File.join(root, file) }
        before = files.map { |file| File.read(file) }
        failure = expect_raises(Caramel::Frappe::Error) do
          Caramel::Frappe::DevelopmentSource.check(root, framework)
        end
        failure.message.should eq(<<-TEXT)
          shard.yml and shard.lock take the caramel shard from caramelizedev/caramel, \
          where Caramel is developed, so Shards copies that whole repository into lib/. \
          Replace both entries. Under dependencies: in shard.yml, write
            caramel:
              github: example/caramel-published
              version: "~> #{VERSION}"
          and under shards: in shard.lock, write
            caramel:
              git: "https://github.com/example/caramel-published.git"
              version: #{VERSION}+git.commit.#{commit}
          Then run frappe setup.
          TEXT
        files.map { |file| File.read(file) }.should eq(before)
      end
    end
  end

  it "names the one file that still states the development repository" do
    release do |framework, _|
      project(PUBLISHED, DEVELOPMENT_LOCK) do |root|
        expect_raises(Caramel::Frappe::Error, "shard.lock takes the caramel shard from") do
          Caramel::Frappe::DevelopmentSource.check(root, framework)
        end
      end
      project(%(git: "git@github.com:caramelizedev/caramel.git"), PUBLISHED_LOCK) do |root|
        expect_raises(Caramel::Frappe::Error, "shard.yml takes the caramel shard from") do
          Caramel::Frappe::DevelopmentSource.check(root, framework)
        end
      end
    end
  end

  it "writes the checkout's path from an installation that is not a release" do
    ReleaseCheckout.create(VERSION) do |framework|
      project(DEVELOPMENT, DEVELOPMENT_LOCK) do |root|
        path = "    path: #{framework.to_json}\n"
        expect_raises(Caramel::Frappe::Error, "  caramel:\n#{path}and under shards:") do
          Caramel::Frappe::DevelopmentSource.check(root, framework)
        end
      end
    end
  end

  it "accepts the published shard, a path, another repository and a project without a lock" do
    framework = "/missing-framework"
    project(PUBLISHED, PUBLISHED_LOCK) do |root|
      Caramel::Frappe::DevelopmentSource.check(root, framework)
    end
    project(%(path: "../caramel"), %(path: "../caramel")) do |root|
      Caramel::Frappe::DevelopmentSource.check(root, framework)
    end
    fork = "git: https://github.com/example/caramel.git"
    project(fork, fork) do |root|
      File.delete(File.join(root, "shard.lock"))
      Caramel::Frappe::DevelopmentSource.check(root, framework)
    end
  end
end
