require "./project"
require "./schema_diff"
require "../sugar_orm/catalog"
require "../sugar_orm/differ"
require "../sugar_orm/ddl"
require "../sugar_orm/migration"
require "file_utils"

module Caramel::Frappe
  struct ResourceField
    TYPES = {"string" => {"String", "text"}, "int32" => {"Int32", "integer"}, "int64" => {"Int64", "bigint"}, "bool" => {"Bool", "boolean"}, "float64" => {"Float64", "double precision"}, "time" => {"Time", "timestamp with time zone"}}
    # A field becomes a schema getter, a changeset param, a facade keyword and
    # a request contract getter, so it must not collide with system columns,
    # the SugarORM schema DSL, facade or changeset API, the request contract
    # API, or Crystal keywords and core methods.
    RESERVED = %w[
      id created_at updated_at
      schema field timestamps belongs_to has_many has_one index drop_column scope
      query with create update delete db from_row to_json record
      param changes errors valid saved insert validate add_error error_messages unique_constraint
      values contract route_error to_mrdp parse
      initialize class self nil true false end def module require property getter setter abstract private protected macro
      new to_s inspect hash clone dup object_id if else elsif unless until while for do then case when in begin rescue ensure
      return break next yield include extend enum struct alias lib fun out as is_a responds_to sizeof typeof instance_sizeof
      union uninitialized super previous_def annotation asm of select pointerof offsetof and or not
    ]
    MODIFIERS = %w[server unique url]
    getter name : String
    getter kind : String
    getter? nullable : Bool
    # Set by the server, not a form: kept out of contracts, forms and request-spec inputs.
    getter? server : Bool
    # Backed by a unique index; the changeset reports a duplicate as an error on the field.
    getter? unique : Bool
    # An absolute http or https URL: validated with cs.validate_url and entered in a URL input.
    getter? url : Bool

    def initialize(declaration : String)
      pieces = declaration.split(':')
      modifiers = pieces[2..]? || [] of String
      unless pieces.size >= 2 && (modifiers - MODIFIERS).empty? && modifiers.uniq.size == modifiers.size
        raise Error.new("Use field:type, optionally followed by :server, :unique or :url, such as title:string, rating:float64?, short_code:string:server:unique or original_url:string:url")
      end
      @server = modifiers.includes?("server")
      @unique = modifiers.includes?("unique")
      @url = modifiers.includes?("url")
      @name = pieces[0]
      @nullable = pieces[1].ends_with?('?')
      @kind = pieces[1].rchop('?')
      unless @name.matches?(/\A[a-z][a-z0-9_]*\z/) && @name.bytesize <= 50 && RESERVED.none?(@name) && TYPES.has_key?(@kind)
        raise Error.new("Invalid or reserved resource field: #{declaration}")
      end
      check_modifiers(declaration)
    end

    private def check_modifiers(declaration : String) : Nil
      raise Error.new("A bool field holds only two values, so it cannot be :unique: #{declaration}") if @unique && @kind == "bool"
      raise Error.new("Only a string field holds a URL: #{declaration}") if @url && @kind != "string"
      raise Error.new("A :server field starts with a random token, not a URL, so it cannot be :url: #{declaration}") if @url && @server
    end

    def type : String
      TYPES[@kind][0] + (@nullable ? "?" : "")
    end

    def column : SugarORM::Catalog::Column
      SugarORM::Catalog::Column.new(@name, TYPES[@kind][1], @nullable, nil)
    end

    def label : String
      @name.tr("_", " ").capitalize
    end

    def sample : String
      # `&` must be escaped in HTML, so the request spec still proves escaping.
      return "https://example.com/#{@name}?first=1&second=2" if @url
      case @kind
      when "string"  then "Example <#{@name}>"
      when "int32"   then "12"
      when "int64"   then "5000000000"
      when "bool"    then "false"
      when "float64" then "2.5"
      else                "2026-09-19T12:00:00Z"
      end
    end

    def updated_sample : String
      return "https://example.org/#{@name}?first=2&second=3" if @url
      case @kind
      when "string"  then "Updated <#{@name}>"
      when "int32"   then "24"
      when "int64"   then "6000000000"
      when "bool"    then "true"
      when "float64" then "3.5"
      else                "2026-09-20T13:00:00Z"
      end
    end

    # `value` (a sample) as a Crystal literal of this field's type.
    def literal(value : String) : String
      case @kind
      when "string"                   then value.to_json
      when "int64"                    then "#{value}_i64"
      when "int32", "bool", "float64" then value
      else                                 "Time.parse_rfc3339(#{value.to_json})"
      end
    end

    # The value a generated create action gives a required :server field; the
    # developer replaces it with the real one. A unique number is random, so
    # the next record does not repeat it.
    def starting_value : String
      case @kind
      when "string"  then "Random::Secure.urlsafe_base64(8)"
      when "int32"   then @unique ? "Random::Secure.rand(Int32::MAX)" : "0"
      when "int64"   then @unique ? "Random::Secure.rand(Int64::MAX)" : "0_i64"
      when "bool"    then "false"
      when "float64" then @unique ? "Random::Secure.rand" : "0.0"
      else                "Time.utc"
      end
    end
  end

  class ResourceGenerator
    def initialize(@framework_root : String)
    end

    # ameba:disable Metrics/CyclomaticComplexity -- validates every name and field before writing anything
    def generate(project : Project, name : String, declarations : Array(String), *, plural : String? = nil, version : Int64? = nil) : Array(String)
      unless name.matches?(/\A[A-Z][A-Za-z0-9]*\z/) && name.size <= 40 && %w[App ApplicationAction ApplicationView Home Health Caramel SugarORM Object String Time Int32 Int64 Bool Float64].none?(name)
        raise Error.new("Use a singular class name such as Book; application and framework names are reserved")
      end
      singular = name.underscore
      collection = plural || pluralize(singular)
      unless collection.matches?(/\A[a-z][a-z0-9_]*\z/) && collection.size <= 50 && collection != singular && %w[assets health home new edit views].none?(collection)
        raise Error.new("Resource plural must be a distinct lowercase identifier")
      end
      fields = declarations.map { |item| ResourceField.new(item) }
      raise Error.new("Declare at least one field and use each name only once") if fields.empty? || fields.map(&.name).uniq!.size != fields.size
      inputs = fields.reject(&.server?)
      raise Error.new("Leave at least one field without :server; the form needs one") if inputs.empty?
      uniques = fields.select(&.unique?)
      if long = uniques.find { |field| index_name(collection, field).bytesize > 63 }
        raise Error.new("The unique index #{index_name(collection, long)} would exceed PostgreSQL's 63-byte names; shorten the field or the plural")
      end
      used_versions = Dir.glob(File.join(project.root, "db/migrations/*.cr")).compact_map { |path| File.basename(path).split('_', 2).first.to_i64? }
      migration_version = version || Time.utc.to_s("%Y%m%d%H%M%S").to_i64
      raise Error.new("Migration version must be positive and unused") if migration_version <= 0 || (version && used_versions.includes?(migration_version))
      while used_versions.includes?(migration_version)
        migration_version += 1
      end
      required_text = fields.select { |field| field.kind == "string" && !field.nullable? }
      required_inputs = required_text.reject(&.server?)
      tokens = {
        "@@MODEL@@" => name, "@@SINGULAR@@" => singular, "@@PLURAL@@" => collection,
        "@@COLLECTION@@" => collection.camelcase, "@@LABEL@@" => name.underscore.tr("_", " "),
        "@@COLLECTION_LABEL@@" => collection.tr("_", " ").capitalize,
        "@@MODEL_FIELDS@@" => fields.map { |field| "      field #{field.name} : #{field.type}" }.join('\n'),
        "@@CONTRACT_FIELDS@@" => inputs.map { |field| "      field #{field.name} : #{field.type}" }.join('\n'),
        "@@PARAMS@@" => fields.map { |field| "    param #{field.name} : #{field.type}" }.join('\n'),
        "@@VALIDATIONS@@" => (required_text.map { |field| "      cs.validate_presence(:#{field.name})" } + fields.select(&.url?).map { |field| validate_url(field) } + uniques.map { |field| "      cs.unique_constraint(:#{field.name})" }).join('\n'),
        "@@INDEXES@@" => uniques.join { |field| "\n      index :#{field.name}, unique: true" },
        "@@CREATE_ATTRIBUTES@@" => fields.compact_map { |field| field.server? ? (field.nullable? ? nil : "#{field.name}: #{field.starting_value}") : "#{field.name}: contract.#{field.name}" }.join(", "),
        "@@UPDATE_ATTRIBUTES@@" => inputs.map { |field| "#{field.name}: contract.#{field.name}" }.join(", "),
        "@@VALUES@@" => inputs.map { |field| "#{field.name.to_json} => record.#{field.name}.try(&.#{field.kind == "time" ? "to_rfc3339" : "to_s"}) || \"\"" }.join(", "),
        "@@FORM_FIELDS@@" => inputs.map { |field| form_field(field) }.join('\n'),
        "@@TABLE_HEADERS@@" => fields.map { |field| "              th(scope: \"col\") { #{field.label.to_json} }" }.join('\n'),
        "@@TABLE_CELLS@@" => fields.map { |field| "                td { record.#{field.name} }" }.join('\n'),
        "@@SHOW_FIELDS@@" => fields.map { |field| "          dt { #{field.label.to_json} }\n          dd { @record.#{field.name} }" }.join('\n'),
        "@@SAMPLE_FIELDS@@" => inputs.map { |field| "#{field.name.to_json} => #{field.sample.to_json}" }.join(", "),
        "@@SAMPLE_CONDITIONS@@" => inputs.map { |field| "#{field.name}: #{field.literal(field.sample)}" }.join(", "),
        "@@UPDATED_FIELDS@@" => inputs.map { |field| "#{field.name.to_json} => #{field.updated_sample.to_json}" }.join(", "),
        "@@ASSERT_FIELDS@@" => inputs.map { |field| "      persisted.#{field.name}.should eq(Caramel::RequestContract.convert(#{field.updated_sample.to_json}, #{ResourceField::TYPES[field.kind][0]}))" }.join('\n'),
        "@@ASSERT_CHANGESET@@" => ([assert_presence(name, required_inputs)] + uniques.map { |field| duplicate_probe(name, fields, field) }).reject(&.empty?).join('\n'),
        "@@ASSERT_ESCAPING@@" => inputs.select { |field| field.kind == "string" }.map { |field| "      shown.body.should contain(Caramel::HTML.escape(#{field.sample.to_json}))\n      shown.body.should_not contain(#{field.sample.to_json})" }.join('\n'),
      }
      files = {} of String => String
      template_root = File.join(@framework_root, "templates/resource")
      Dir.glob(File.join(template_root, "**/*")).sort.each do |path|
        next unless File.file?(path)
        relative = Path[path].relative_to(template_root).to_s
        content = File.read(path)
        tokens.each { |key, value| relative = relative.gsub(key, value); content = content.gsub(key, value) }
        files[relative] = content
      end
      raise Error.new("Resource templates are missing") if files.empty?
      migration = SugarORM::Migration.new(migration_version, "create_#{collection}", create_table(collection, fields))
      files["db/migrations/#{migration.version}_#{migration.name}.cr"] = SchemaDiff.source(migration)
      originals = {} of String => String
      actions = "App::#{collection.camelcase}"
      routes = [
        %(    get "/#{collection}", #{actions}::Index),
        %(    get "/#{collection}/new", #{actions}::New),
        %(    post "/#{collection}", #{actions}::Create),
        %(    get "/#{collection}/:id", #{actions}::Show),
        %(    get "/#{collection}/:id/edit", #{actions}::Edit),
        %(    patch "/#{collection}/:id", #{actions}::Update),
        %(    delete "/#{collection}/:id", #{actions}::Destroy),
      ]
      {"config/routes.cr" => {"    # Frappé resource routes", routes},
       "config/paths.cr"  => {"  # Frappé resource paths", ["  Caramel.resource_paths :#{collection}, :#{singular}"]}}.each do |relative, insertion|
        validate_path(project.root, relative)
        original = File.read(File.join(project.root, relative))
        marker, lines = insertion
        raise Error.new("Expected exactly one generation marker in #{relative}; source was preserved") unless original.lines.count(marker) == 1
        raise Error.new("Resource route or helper already exists") if lines.any? { |line| original.includes?(line) }
        originals[relative] = original
        files[relative] = original.sub(marker, "#{lines.join('\n')}\n#{marker}")
      end
      publish(project, files, originals)
      files.keys.sort!
    end

    private def pluralize(name : String) : String
      return name[0...-1] + "ies" if name.matches?(/[^aeiou]y\z/)
      return name + "es" if name.matches?(/(?:s|x|z|ch|sh)\z/)
      name + "s"
    end

    # Diffs the generated schema's table against an empty database, exactly as
    # `frappe db diff --name create_<plural>` would: id identity key, the
    # fields in order, the timestamps, then the unique indexes.
    private def create_table(table : String, fields : Array(ResourceField)) : Array(String)
      columns = [SugarORM::Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)]
      columns.concat(fields.map(&.column))
      %w[created_at updated_at].each { |stamp| columns << SugarORM::Catalog::Column.new(stamp, "timestamp with time zone", false, "CURRENT_TIMESTAMP") }
      indexes = fields.select(&.unique?).map { |field| SugarORM::Catalog::Index.new(index_name(table, field), [field.name], unique: true) }
      plan = SugarORM::Differ.diff([SugarORM::Catalog::Table.new(table, columns, indexes)], [] of SugarORM::Catalog::Table)
      SugarORM::DDL.statements(plan.transactional)
    end

    # The name SugarORM gives `index :field` in the schema.
    private def index_name(table : String, field : ResourceField) : String
      "index_#{table}_on_#{field.name}"
    end

    # Blank required text must fail through the generated changeset on both
    # facade writes.
    private def assert_presence(model : String, fields : Array(ResourceField)) : String
      return "" if fields.empty?
      blanks = fields.join(", ") { |field| "#{field.name}: \" \"" }
      String.build do |io|
        io << "      [App::" << model << ".create(" << blanks << "), persisted.update(" << blanks << ")].each do |blank|\n"
        io << "        blank.saved?.should be_false\n"
        fields.each { |field| io << "        blank.errors[" << field.name.to_json << "]?.should eq([\"can't be blank\"])\n" }
        io << "      end"
      end
    end

    # A second row repeating a unique field must fail through the changeset's
    # unique_constraint, not a database error. Every other field takes a value
    # no row holds: an input its first sample, which the row replaced when it
    # was updated, and a server field its starting value.
    private def duplicate_probe(model : String, fields : Array(ResourceField), unique : ResourceField) : String
      values = fields.join(", ") do |field|
        value = if field.name == unique.name
                  "persisted.#{field.name}"
                elsif field.server?
                  field.starting_value
                else
                  field.literal(field.sample)
                end
        "#{field.name}: #{value}"
      end
      %(      App::#{model}.create(#{values}).errors[#{unique.name.to_json}]?.should eq(["has already been taken"]))
    end

    # A blank required URL reports only that it is blank.
    private def validate_url(field : ResourceField) : String
      line = "      cs.validate_url(:#{field.name})"
      field.nullable? ? line : "#{line} unless cs.errors.has_key?(#{field.name.to_json})"
    end

    # The field's control, inside the generated form view's `labelled` helper.
    private def form_field(field : ResourceField) : String
      name = field.name.to_json
      attributes = "id: id, name: #{name}#{field.nullable? ? "" : ", required: true"}, aria_describedby: \"\#{id}_errors\", aria_invalid: @errors.has_key?(#{name}).to_s"
      control = if field.kind == "bool"
                  options = field.nullable? ? ["", "true", "false"] : ["true", "false"]
                  choices = options.map { |value| "            option(value: #{value.to_json}, selected: @values[#{name}]? == #{value.to_json}) { #{(value.empty? ? "Unspecified" : value.capitalize).to_json} }" }
                  "          select_tag #{attributes} do\n#{choices.join('\n')}\n          end"
                else
                  type = %w[int32 int64 float64].includes?(field.kind) ? "number" : (field.url? ? "url" : "text")
                  extra = field.kind == "float64" ? ", step: \"any\"" : ""
                  extra += ", placeholder: \"2026-09-19T12:00:00Z\"" if field.kind == "time"
                  "          input type: \"#{type}\", #{attributes}#{extra}, value: @values[#{name}]? || \"\""
                end
      "        labelled #{name}, #{field.label.to_json} do |id|\n#{control}\n        end"
    end

    private def validate_path(root : String, relative : String) : Nil
      current = root
      relative.split('/').each do |part|
        current = File.join(current, part)
        if info = File.info?(current, follow_symlinks: false)
          raise Error.new("Generator refuses symlinked paths: #{relative}") if info.symlink?
        end
      end
    end

    private def preflight(root : String, files : Hash(String, String), originals : Hash(String, String)) : Nil
      # Repeat the version check while holding the publication lock: another
      # generator may have planned a different resource in the same second.
      files.each_key do |relative|
        next unless relative.starts_with?("db/migrations/")
        version = File.basename(relative).split('_', 2).first
        unless Dir.glob(File.join(root, "db/migrations/#{version}_*.cr")).empty?
          raise Error.new("Migration version already exists; retry generation")
        end
      end
      files.each_key do |relative|
        validate_path(root, relative)
        path = File.join(root, relative)
        if original = originals[relative]?
          raise Error.new("Source changed while planning generation: #{relative}") unless File.file?(path) && File.read(path) == original
        elsif File.info?(path, follow_symlinks: false)
          raise Error.new("File already exists: #{relative}; source was preserved")
        end
      end
    end

    private def publish(project : Project, files : Hash(String, String), originals : Hash(String, String)) : Nil
      preflight(project.root, files, originals)
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(project.root, ".caramel"))
      lock_path = File.join(directory, "generation.lock")
      raise Error.new("Generator lock must be a regular file") if File.symlink?(lock_path)
      File.open(lock_path, "a", perm: 0o600) do |lock|
        lock.flock_exclusive do
          preflight(project.root, files, originals)
          stage = File.join(directory, "generate-#{Random::Secure.hex(8)}")
          Dir.mkdir(stage, 0o700)
          published = [] of String
          begin
            files.each do |relative, content|
              path = File.join(stage, relative)
              FileUtils.mkdir_p(File.dirname(path))
              File.write(path, content)
            end
            files.each_key do |relative|
              path = File.join(project.root, relative)
              FileUtils.mkdir_p(File.dirname(path))
              if originals.has_key?(relative)
                raise Error.new("Source changed while generating: #{relative}") unless File.read(path) == originals[relative]
                File.rename(File.join(stage, relative), path)
              else
                File.link(File.join(stage, relative), path)
              end
              published << relative
            end
          rescue ex
            published.reverse_each do |relative|
              path = File.join(project.root, relative)
              next unless File.file?(path) && File.read(path) == files[relative]
              if original = originals[relative]?
                File.write(path, original)
              else
                File.delete(path)
              end
            end
            raise ex
          ensure
            FileUtils.rm_rf(stage)
          end
        end
      end
    end
  end
end
