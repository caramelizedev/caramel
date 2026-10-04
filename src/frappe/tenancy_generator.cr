require "./project"
require "./publication"
require "./resource_generator"
require "./schema_diff"

module Caramel::Frappe
  # Makes an application multi-tenant (ADR 0025): the tenant model with its
  # sign-up and home pages, `require "caramel/tenancy"` and the routes'
  # tenant block.
  class TenancyGenerator
    CONFIG      = "config/application.cr"
    ROUTES      = "config/routes.cr"
    PATHS       = "config/paths.cr"
    SPEC_HELPER = "spec/spec_helper.cr"

    CARAMEL_REQUIRE = %(require "caramel")
    TENANCY_REQUIRE = %(require "caramel/tenancy")
    ROUTES_MARKER   = "    # Frappé resource routes"
    PATHS_MARKER    = "  # Frappé resource paths"
    CORRETTO        = "Corretto.configure(App)"

    # The line each edited file must hold exactly once.
    ANCHORS = {
      CONFIG      => CARAMEL_REQUIRE,
      ROUTES      => ROUTES_MARKER,
      PATHS       => PATHS_MARKER,
      SPEC_HELPER => CORRETTO,
    }

    ALREADY_TENANTED = "This application is already multi-tenant: " \
                       "config/application.cr requires caramel/tenancy"

    def initialize(@framework_root : String)
    end

    # Writes the tenant *model* and wires caramel/tenancy into the
    # application. Returns the written paths.
    def generate(project : Project, model : String, *, version : Int64? = nil) : Array(String)
      ResourceGenerator.validate_model(model)
      singular = model.underscore
      plural = ResourceGenerator.pluralize(singular)
      originals = originals(project.root)
      files = templates(model, singular, plural)
      files[CONFIG] = tenanted_config(originals[CONFIG])
      files[ROUTES] = tenanted_routes(originals[ROUTES], model, plural)
      files[PATHS] = originals[PATHS].sub(PATHS_MARKER, path_helpers(singular, plural))
      files[SPEC_HELPER] = originals[SPEC_HELPER] + spec_helpers(model, singular)
      migration = create_migration(project.root, plural, version)
      migration_path = "db/migrations/#{migration.version}_#{migration.name}.cr"
      files[migration_path] = SchemaDiff.source(migration)
      Publication.publish(project, files, originals)
      files.keys.sort!
    end

    # Reads each edited file, refusing an application that is already
    # multi-tenant or lacks an anchor.
    private def originals(root : String) : Hash(String, String)
      originals = {} of String => String
      ANCHORS.each do |relative, anchor|
        Publication.validate_path(root, relative)
        path = File.join(root, relative)
        raise unanchored(relative, anchor) unless File.file?(path)
        original = File.read(path)
        lines = original.lines
        raise Error.new(ALREADY_TENANTED) if relative == CONFIG && lines.includes?(TENANCY_REQUIRE)
        raise unanchored(relative, anchor) unless lines.count(anchor) == 1
        originals[relative] = original
      end
      originals
    end

    private def unanchored(relative : String, anchor : String) : Error
      Error.new("#{relative} needs exactly one #{anchor}; wire caramel/tenancy by hand (ADR 0025)")
    end

    private def tenanted_config(config : String) : String
      config.sub(/^#{Regex.escape(CARAMEL_REQUIRE)}$/m, "#{CARAMEL_REQUIRE}\n#{TENANCY_REQUIRE}")
    end

    # The sign-up routes before the resource marker, and the tenant block
    # with the tenant's home after it.
    private def tenanted_routes(routes : String, model : String, plural : String) : String
      collection = plural.camelcase
      block = <<-CRYSTAL
            get "/#{plural}/new", App::#{collection}::New
            post "/#{plural}", App::#{collection}::Create
        #{ROUTES_MARKER}

            tenant App::#{model}, by: :slug do
              get "/", App::#{collection}::Home
              # Frappé tenant routes
            end
        CRYSTAL
      routes.sub(ROUTES_MARKER, block)
    end

    private def path_helpers(singular : String, plural : String) : String
      "  Caramel.resource_paths :#{plural}, :#{singular}\n#{PATHS_MARKER}"
    end

    private def spec_helpers(model : String, singular : String) : String
      <<-CRYSTAL

        # A new #{model} whose pages live under /SLUG.
        def #{singular}(db, slug : String) : App::#{model}
          App::#{model}.create!(db, name: slug.capitalize, slug: slug)
        end

        # A request session in a new #{model} SLUG: the example's queries see
        # only its rows.
        def tenant_session(slug : String, &)
          Corretto.session do |client, db|
            Caramel::Tenancy.with(#{singular}(db, slug)) { yield client, db }
          end
        end

        CRYSTAL
    end

    # The tenant model's files from templates/tenancy.
    private def templates(model : String, singular : String, plural : String) : Hash(String, String)
      tokens = {
        "@@MODEL@@"      => model,
        "@@SINGULAR@@"   => singular,
        "@@PLURAL@@"     => plural,
        "@@COLLECTION@@" => plural.camelcase,
        "@@LABEL@@"      => singular.tr("_", " "),
      }
      root = File.join(@framework_root, "templates/tenancy")
      files = {} of String => String
      Dir.glob(File.join(root, "**/*")).sort.each do |path|
        next unless File.file?(path)
        relative = Path[path].relative_to(root).to_s
        content = File.read(path)
        tokens.each do |key, value|
          relative = relative.gsub(key, value)
          content = content.gsub(key, value)
        end
        files[relative] = content
      end
      raise Error.new("Tenancy templates are missing") if files.empty?
      files
    end

    private def create_migration(root : String,
                                 plural : String,
                                 version : Int64?) : SugarORM::Migration
      fields = ["name:string", "slug:string:unique"].map { |item| ResourceField.new(item) }
      statements = ResourceGenerator.create_table(plural, fields)
      chosen = ResourceGenerator.migration_version(root, version)
      SugarORM::Migration.new(chosen, "create_#{plural}", statements)
    end
  end
end
