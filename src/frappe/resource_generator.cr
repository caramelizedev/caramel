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
    getter name : String
    getter kind : String
    getter? nullable : Bool

    def initialize(declaration : String)
      pieces = declaration.split(':')
      raise Error.new("Use field:type, such as title:string or rating:float64?") unless pieces.size == 2
      @name = pieces[0]
      @nullable = pieces[1].ends_with?('?')
      @kind = pieces[1].rchop('?')
      unless @name.matches?(/\A[a-z][a-z0-9_]*\z/) && @name.bytesize <= 50 && RESERVED.none?(@name) && TYPES.has_key?(@kind)
        raise Error.new("Invalid or reserved resource field: #{declaration}")
      end
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
  end

  class ResourceGenerator
    def initialize(@framework_root : String)
    end

    # ameba:disable Metrics/CyclomaticComplexity -- validates every name and field before writing anything
    def generate(project : Project, name : String, declarations : Array(String), *, plural : String? = nil, version : Int64? = nil) : Array(String)
      unless name.matches?(/\A[A-Z][A-Za-z0-9]*\z/) && name.size <= 40 && %w[App ApplicationAction Home Health Caramel SugarORM Object String Time Int32 Int64 Bool Float64].none?(name)
        raise Error.new("Use a singular class name such as Book; application and framework names are reserved")
      end
      singular = name.underscore
      collection = plural || pluralize(singular)
      unless collection.matches?(/\A[a-z][a-z0-9_]*\z/) && collection.size <= 50 && collection != singular && %w[assets health home new edit].none?(collection)
        raise Error.new("Resource plural must be a distinct lowercase identifier")
      end
      fields = declarations.map { |item| ResourceField.new(item) }
      raise Error.new("Declare at least one field and use each name only once") if fields.empty? || fields.map(&.name).uniq!.size != fields.size
      used_versions = Dir.glob(File.join(project.root, "db/migrations/*.cr")).compact_map { |path| File.basename(path).split('_', 2).first.to_i64? }
      migration_version = version || Time.utc.to_s("%Y%m%d%H%M%S").to_i64
      raise Error.new("Migration version must be positive and unused") if migration_version <= 0 || (version && used_versions.includes?(migration_version))
      while used_versions.includes?(migration_version)
        migration_version += 1
      end
      required_text = fields.select { |field| field.kind == "string" && !field.nullable? }
      tokens = {
        "@@MODEL@@" => name, "@@SINGULAR@@" => singular, "@@PLURAL@@" => collection,
        "@@COLLECTION@@" => collection.camelcase, "@@LABEL@@" => name.underscore.tr("_", " "),
        "@@COLLECTION_LABEL@@" => collection.tr("_", " ").capitalize,
        "@@MODEL_FIELDS@@" => fields.map { |field| "      field #{field.name} : #{field.type}" }.join('\n'),
        "@@CONTRACT_FIELDS@@" => fields.map { |field| "      field #{field.name} : #{field.type}" }.join('\n'),
        "@@PARAMS@@" => fields.map { |field| "    param #{field.name} : #{field.type}" }.join('\n'),
        "@@VALIDATIONS@@" => required_text.map { |field| "      cs.validate_presence(:#{field.name})" }.join('\n'),
        "@@ATTRIBUTES@@" => fields.map { |field| "#{field.name}: contract.#{field.name}" }.join(", "),
        "@@VALUES@@" => fields.map { |field| "#{field.name.to_json} => record.#{field.name}.try(&.#{field.kind == "time" ? "to_rfc3339" : "to_s"}) || \"\"" }.join(", "),
        "@@FORM_FIELDS@@" => fields.map { |field| form_field(field, singular) }.join('\n'),
        "@@TABLE_HEADERS@@" => fields.map { |field| "<th scope=\"col\">#{field.label}</th>" }.join,
        "@@TABLE_CELLS@@" => fields.map { |field| "<td><%= record.#{field.name} %></td>" }.join,
        "@@SHOW_FIELDS@@" => fields.map { |field| "  <dt>#{field.label}</dt><dd><%= record.#{field.name} %></dd>" }.join('\n'),
        "@@SAMPLE_FIELDS@@" => fields.map { |field| "#{field.name.to_json} => #{field.sample.to_json}" }.join(", "),
        "@@SAMPLE_CONDITIONS@@" => fields.map { |field| "#{field.name}: #{field.literal(field.sample)}" }.join(", "),
        "@@UPDATED_FIELDS@@" => fields.map { |field| "#{field.name.to_json} => #{field.updated_sample.to_json}" }.join(", "),
        "@@ASSERT_FIELDS@@" => fields.map { |field| "      persisted.#{field.name}.should eq(Caramel::RequestContract.convert(#{field.updated_sample.to_json}, #{ResourceField::TYPES[field.kind][0]}))" }.join('\n'),
        "@@ASSERT_PRESENCE@@" => assert_presence(name, required_text),
        "@@ASSERT_ESCAPING@@" => fields.select { |field| field.kind == "string" }.map { |field| "      shown.body.should contain(Caramel::HTML.escape(#{field.sample.to_json}))\n      shown.body.should_not contain(#{field.sample.to_json})" }.join('\n'),
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
    # fields in order, then the timestamps.
    private def create_table(table : String, fields : Array(ResourceField)) : Array(String)
      columns = [SugarORM::Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)]
      columns.concat(fields.map(&.column))
      %w[created_at updated_at].each { |stamp| columns << SugarORM::Catalog::Column.new(stamp, "timestamp with time zone", false, "CURRENT_TIMESTAMP") }
      plan = SugarORM::Differ.diff([SugarORM::Catalog::Table.new(table, columns)], [] of SugarORM::Catalog::Table)
      SugarORM::DDL.statements(plan.transactional)
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

    private def form_field(field : ResourceField, singular : String) : String
      id = "#{singular}_#{field.name}"
      attributes = "id=\"#{id}\" name=\"#{field.name}\"#{field.nullable? ? "" : " required"} aria-describedby=\"#{id}_errors\" aria-invalid=\"<%= errors.has_key?(#{field.name.to_json}) ? \"true\" : \"false\" %>\""
      control = if field.kind == "bool"
                  options = field.nullable? ? ["", "true", "false"] : ["true", "false"]
                  "<select #{attributes}>" + options.map { |value| "<option value=\"#{value}\"<% if values[#{field.name.to_json}]? == #{value.to_json} %> selected<% end %>>#{value.empty? ? "Unspecified" : value.capitalize}</option>" }.join + "</select>"
                else
                  type = %w[int32 int64 float64].includes?(field.kind) ? "number" : "text"
                  extra = field.kind == "float64" ? " step=\"any\"" : ""
                  extra += " placeholder=\"2026-09-19T12:00:00Z\"" if field.kind == "time"
                  "<input type=\"#{type}\" #{attributes}#{extra} value=\"<%= values[#{field.name.to_json}]? || \"\" %>\">"
                end
      "  <label for=\"#{id}\">#{field.label}</label>#{control}\n  <div id=\"#{id}_errors\"><% (errors[#{field.name.to_json}]? || [] of String).each do |error| %><p class=\"field-error\"><%= error %></p><% end %></div>"
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
