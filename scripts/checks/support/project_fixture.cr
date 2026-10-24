require "./latte_fixture"
require "../../../src/frappe/commands"
require "../../../src/caramel"
require "../../../src/caramel/corretto/matchers"
require "uri"
require "http/params"

module Caramel::Checks
  # A check that creates a `bookshelf` application under its own Latte: the
  # frappe-project, frappe-project-dev and frappe-project-build checks, which
  # each make their own application so they can run on different lanes.
  abstract class ProjectFixture < LatteFixture
    include Corretto::Matchers
    getter project : String

    MATCHED         = "The database matches the declared schema."
    RESOURCE_ROUTES = "    # Frappé resource routes"

    def initialize(prefix : String)
      toolchain = Checks.toolchain_root
      super(prefix)
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @project = File.join(@projects, "bookshelf")
    end

    def sql(url : String, statement : String) : String
      uri = URI.parse(url)
      query = HTTP::Params.parse(uri.query || "")
      pg_env = environment({"PGPASSWORD" => URI.decode(uri.password || "")})
      psql = [@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1",
              "-h", query["host"], "-p", query["port"]? || "5432",
              "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')]
      result = command(psql,
        environment: pg_env, input: statement, echo: false, timeout: 15.seconds)
      result.stdout.strip
    end

    # A copy of the project as its own site *name*: everything but its
    # dependencies, build and secrets, renamed in its manifest and set up.
    def clone_project(name : String) : String
      clone = File.join(@projects, name)
      Dir.mkdir(clone, 0o700)
      Dir.children(@project).each do |entry|
        next if %w[lib .caramel .env].includes?(entry)
        copy = ["/bin/cp", "-R", File.join(@project, entry), File.join(clone, entry)]
        command(copy, echo: false)
      end
      manifest = File.join(clone, "config/environment.yml")
      File.write(manifest, File.read(manifest).sub("name: bookshelf", "name: #{name}"))
      clone
    end

    # Adds the probe job and the action that enqueues it, on POST /probe/jobs.
    def write_probe : Nil
      File.write(File.join(@project, "app/jobs/probe_job.cr"), PROBE_JOB)
      Dir.mkdir_p(File.join(@project, "app/actions/probe"))
      File.write(File.join(@project, "app/actions/probe/enqueue.cr"), PROBE_ACTION)
      routes = File.join(@project, "config/routes.cr")
      probe_route = %(    post "/probe/jobs", App::Probe::Enqueue\n) \
                    %(    # Frappé resource routes)
      File.write(routes, File.read(routes).sub(RESOURCE_ROUTES, probe_route))
    end

    # A Cold Brew job, and the action that enqueues it, which the probe spec
    # drains and the release artifact lists.
    PROBE_JOB = <<-CRYSTAL
      module App
        struct ProbeJob < Caramel::ColdBrew::Job
          param title : String

          def perform
            App::Book.create!(title: title, author: "Cold Brew")
          end
        end
      end
      CRYSTAL

    PROBE_ACTION = <<-'CRYSTAL'
      require "big"

      module App::Probe
        struct Enqueue < App::ApplicationAction
          contract do
            field title : String
          end

          def handle(contract : Contract)
            App::ProbeJob.enqueue(title: contract.title)
            total = BigDecimal.new("0.1") + BigDecimal.new("0.2")
            morph("#jobs", "Queued #{Caramel::HTML.escape(contract.title)} at #{total}")
          end
        end
      end
      CRYSTAL
  end
end
