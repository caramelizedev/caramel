require "./project"
require "./schema_diff"
require "../sugar_orm/catalog"
require "../sugar_orm/differ"
require "../sugar_orm/ddl"
require "../sugar_orm/migration"
require "file_utils"

module Caramel::Frappe
  struct ResourceField
    TYPES = {
      "string"  => {"String", "text"},
      "int32"   => {"Int32", "integer"},
      "int64"   => {"Int64", "bigint"},
      "bool"    => {"Bool", "boolean"},
      "float64" => {"Float64", "double precision"},
      "time"    => {"Time", "timestamp with time zone"},
    }
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
      initialize class self nil true false end def module require
      property getter setter abstract private protected macro
      new to_s inspect hash clone dup object_id
      if else elsif unless until while for do then case when in begin rescue ensure
      return break next yield include extend enum struct alias lib fun out
      as is_a responds_to sizeof typeof instance_sizeof
      union uninitialized super previous_def annotation asm of select pointerof offsetof and or not
    ]
    MODIFIERS = %w[server unique url]
    USAGE     = "Use field:type, optionally followed by :server, :unique or :url, " \
                "such as title:string, rating:float64?, " \
                "short_code:string:server:unique or original_url:string:url"
    getter name : String
    getter kind : String
    getter? nullable : Bool
    # Set by the server, not a form: kept out of contracts, forms and request-spec inputs.
    getter? server : Bool
    # Backed by a unique index; the changeset reports a duplicate as an error on the field.
    getter? unique : Bool
    # Holds an http or https URL: the changeset validates it, the form asks for one.
    getter? url : Bool

    def initialize(declaration : String)
      pieces = declaration.split(':')
      modifiers = pieces[2..]? || [] of String
      unless pieces.size >= 2 && (modifiers - MODIFIERS).empty? &&
             modifiers.uniq.size == modifiers.size
        raise Error.new(USAGE)
      end
      @server = modifiers.includes?("server")
      @unique = modifiers.includes?("unique")
      @url = modifiers.includes?("url")
      @name = pieces[0]
      @nullable = pieces[1].ends_with?('?')
      @kind = pieces[1].rchop('?')
      unless @name.matches?(/\A[a-z][a-z0-9_]*\z/) && @name.bytesize <= 50 &&
             RESERVED.none?(@name) && TYPES.has_key?(@kind)
        raise Error.new("Invalid or reserved resource field: #{declaration}")
      end
      check_modifiers(declaration)
    end

    private def check_modifiers(declaration : String) : Nil
      if @unique && @kind == "bool"
        raise Error.new("A bool field holds only two values, " \
                        "so it cannot be :unique: #{declaration}")
      end
      if @url && @kind != "string"
        raise Error.new("Only a string field holds a URL: #{declaration}")
      end
      if @url && @server
        raise Error.new("A :server field starts with a random token, not a URL, " \
                        "so it cannot be :url: #{declaration}")
      end
    end

    def type : String
      TYPES[@kind][0] + (@nullable ? "?" : "")
    end

    # The changeset rules this field needs, as the generated `validate` writes them.
    def presence_rule : String
      "cs.validate_presence(:#{@name})"
    end

    # A blank required URL reports only that it is blank.
    def url_rule : String
      rule = "cs.validate_url(:#{@name})"
      @nullable ? rule : "#{rule} unless cs.errors.has_key?(#{@name.to_json})"
    end

    def unique_rule : String
      "cs.unique_constraint(:#{@name})"
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
    ACTIONS = %w[index show new create edit update destroy]
    # Template files that belong to one action; every other file is always written.
    ACTION_FILES = {
      "app/actions/@@PLURAL@@.cr"         => "new",
      "app/actions/@@PLURAL@@/index.cr"   => "index",
      "app/actions/@@PLURAL@@/new.cr"     => "new",
      "app/actions/@@PLURAL@@/edit.cr"    => "edit",
      "app/actions/@@PLURAL@@/update.cr"  => "update",
      "app/actions/@@PLURAL@@/destroy.cr" => "destroy",
      "app/views/@@PLURAL@@/index.cr"     => "index",
      "app/views/@@PLURAL@@/new.cr"       => "new",
      "app/views/@@PLURAL@@/form.cr"      => "new",
      "app/views/@@PLURAL@@/edit.cr"      => "edit",
    }
    # Template lines between `# frappe:only a,b` and `# frappe:end` are kept
    # when any of those actions is generated, and between
    # `# frappe:unless a,b` and `# frappe:end` when none is; `# frappe:else`
    # turns a block over. Blocks nest, and the marker lines are dropped.
    MARKER = /\A\s*# frappe:(only|unless|else|end)(?: ([a-z,]+))?\z/
    # Class names the application and the framework already use.
    RESERVED_NAMES = %w[
      App ApplicationAction ApplicationView Home Health Caramel SugarORM
      Object String Time Int32 Int64 Bool Float64
    ]
    # Plurals that would take a path or directory the application already has.
    RESERVED_PLURALS = %w[assets health home new edit views]

    def initialize(@framework_root : String)
    end

    # ameba:disable Metrics/CyclomaticComplexity -- validates every name and field before writing
    def generate(project : Project, name : String, declarations : Array(String), *,
                 plural : String? = nil,
                 version : Int64? = nil,
                 only : String? = nil) : Array(String)
      unless name.matches?(/\A[A-Z][A-Za-z0-9]*\z/) && name.size <= 40 &&
             RESERVED_NAMES.none?(name)
        raise Error.new("Use a singular class name such as Book; " \
                        "application and framework names are reserved")
      end
      singular = name.underscore
      collection = plural || pluralize(singular)
      unless collection.matches?(/\A[a-z][a-z0-9_]*\z/) && collection.size <= 50 &&
             collection != singular && RESERVED_PLURALS.none?(collection)
        raise Error.new("Resource plural must be a distinct lowercase identifier")
      end
      actions = selected_actions(only)
      fields = declarations.map { |item| ResourceField.new(item) }
      if fields.empty? || fields.map(&.name).uniq!.size != fields.size
        raise Error.new("Declare at least one field and use each name only once")
      end
      inputs = fields.reject(&.server?)
      if inputs.empty?
        raise Error.new("Leave at least one field without :server; the form needs one")
      end
      uniques = fields.select(&.unique?)
      if long = uniques.find { |field| index_name(collection, field).bytesize > 63 }
        raise Error.new("The unique index #{index_name(collection, long)} " \
                        "would exceed PostgreSQL's 63-byte names; " \
                        "shorten the field or the plural")
      end
      used_versions = migration_versions(project.root)
      migration_version = version || Time.utc.to_s("%Y%m%d%H%M%S").to_i64
      if migration_version <= 0 || (version && used_versions.includes?(migration_version))
        raise Error.new("Migration version must be positive and unused")
      end
      while used_versions.includes?(migration_version)
        migration_version += 1
      end
      required_text = fields.select { |field| field.kind == "string" && !field.nullable? }
      required_inputs = required_text.reject(&.server?)
      changeset_checks = assert_changeset(name, fields, required_inputs, actions)
      tokens = {
        "@@MODEL@@"             => name,
        "@@SINGULAR@@"          => singular,
        "@@PLURAL@@"            => collection,
        "@@COLLECTION@@"        => collection.camelcase,
        "@@LABEL@@"             => name.underscore.tr("_", " "),
        "@@COLLECTION_LABEL@@"  => collection.tr("_", " ").capitalize,
        "@@MODEL_FIELDS@@"      => field_declarations(fields, "      field"),
        "@@CONTRACT_FIELDS@@"   => field_declarations(inputs, "      field"),
        "@@PARAMS@@"            => field_declarations(fields, "    param"),
        "@@VALIDATIONS@@"       => validations(required_text, fields),
        "@@INDEXES@@"           => unique_indexes(uniques),
        "@@CREATE_ATTRIBUTES@@" => create_attributes(fields),
        "@@UPDATE_ATTRIBUTES@@" => update_attributes(inputs),
        "@@VALUES@@"            => form_values(inputs),
        "@@FORM_FIELDS@@"       => inputs.map { |field| form_field(field) }.join('\n'),
        "@@TABLE_HEADERS@@"     => table_headers(fields),
        "@@TABLE_CELLS@@"       => table_cells(fields),
        "@@SHOW_FIELDS@@"       => show_fields(fields),
        "@@SAMPLE_FIELDS@@"     => sample_fields(inputs),
        "@@SAMPLE_CONDITIONS@@" => sample_conditions(inputs),
        "@@UPDATED_FIELDS@@"    => updated_fields(inputs),
        "@@ASSERT_FIELDS@@"     => assert_fields(inputs),
        "@@ASSERT_CHANGESET@@"  => changeset_checks,
        "@@SPEC_TITLE@@"        => spec_title(actions),
        "@@ASSERT_ESCAPING@@"   => assert_escaping(inputs),
      }
      files = {} of String => String
      template_root = File.join(@framework_root, "templates/resource")
      Dir.glob(File.join(template_root, "**/*")).sort.each do |path|
        next unless File.file?(path)
        relative = Path[path].relative_to(template_root).to_s
        next if (action = ACTION_FILES[relative]?) && !actions.includes?(action)
        content = select_lines(File.read(path), actions)
        tokens.each do |key, value|
          relative = relative.gsub(key, value)
          content = content.gsub(key, value)
        end
        content = without_unread_row(content) if relative.starts_with?("spec/requests/")
        files[relative] = content
      end
      raise Error.new("Resource templates are missing") if files.empty?
      ddl = create_table(collection, fields)
      migration = SugarORM::Migration.new(migration_version, "create_#{collection}", ddl)
      migration_path = "db/migrations/#{migration.version}_#{migration.name}.cr"
      files[migration_path] = SchemaDiff.source(migration)
      originals = {} of String => String
      namespace = "App::#{collection.camelcase}"
      routes = {
        "index"   => %(    get "/#{collection}", #{namespace}::Index),
        "new"     => %(    get "/#{collection}/new", #{namespace}::New),
        "create"  => %(    post "/#{collection}", #{namespace}::Create),
        "show"    => %(    get "/#{collection}/:id", #{namespace}::Show),
        "edit"    => %(    get "/#{collection}/:id/edit", #{namespace}::Edit),
        "update"  => %(    patch "/#{collection}/:id", #{namespace}::Update),
        "destroy" => %(    delete "/#{collection}/:id", #{namespace}::Destroy),
      }.select { |action, _| actions.includes?(action) }.values
      path_helpers = ["  Caramel.resource_paths :#{collection}, :#{singular}"]
      insertions = {
        "config/routes.cr" => {"    # Frappé resource routes", routes},
        "config/paths.cr"  => {"  # Frappé resource paths", path_helpers},
      }
      insertions.each do |relative, insertion|
        validate_path(project.root, relative)
        original = File.read(File.join(project.root, relative))
        marker, lines = insertion
        unless original.lines.count(marker) == 1
          raise Error.new("Expected exactly one generation marker in #{relative}; " \
                          "source was preserved")
        end
        if lines.any? { |line| original.includes?(line) }
          raise Error.new("Resource route or helper already exists")
        end
        originals[relative] = original
        files[relative] = original.sub(marker, "#{lines.join('\n')}\n#{marker}")
      end
      publish(project, files, originals)
      files.keys.sort!
    end

    # Every action, or those `--only` names. Create and show are required:
    # the spec creates a record and reads it back, and edit reuses the new
    # form and saves through update.
    private def selected_actions(only : String?) : Array(String)
      return ACTIONS if only.nil?

      chosen = only.split(',').map(&.strip)
      unknown = chosen - ACTIONS
      unless unknown.empty?
        raise Error.new("Unknown resource action: #{unknown.join(", ")}; " \
                        "choose from #{ACTIONS.join(",")}")
      end
      unless (%w[create show] - chosen).empty?
        raise Error.new("A resource always has create and show; add them to --only")
      end
      if chosen.includes?("edit") && !(%w[new update] - chosen).empty?
        raise Error.new("edit reuses the new form and saves through update; " \
                        "add new and update to --only")
      end
      ACTIONS & chosen
    end

    # The versions of the project's existing migrations.
    private def migration_versions(root : String) : Array(Int64)
      paths = Dir.glob(File.join(root, "db/migrations/*.cr"))
      paths.compact_map { |path| File.basename(path).split('_', 2).first.to_i64? }
    end

    # One line per field, such as `      field title : String` for a *keyword* of
    # `      field`.
    private def field_declarations(fields : Array(ResourceField),
                                   keyword : String) : String
      fields.map { |field| "#{keyword} #{field.name} : #{field.type}" }.join('\n')
    end

    private def unique_indexes(uniques : Array(ResourceField)) : String
      uniques.join { |field| "\n      index :#{field.name}, unique: true" }
    end

    # Each input from the contract, and each required :server field's
    # starting value.
    private def create_attributes(fields : Array(ResourceField)) : String
      attributes = fields.compact_map do |field|
        next "#{field.name}: contract.#{field.name}" unless field.server?
        "#{field.name}: #{field.starting_value}" unless field.nullable?
      end
      attributes.join(", ")
    end

    private def update_attributes(inputs : Array(ResourceField)) : String
      inputs.map { |field| "#{field.name}: contract.#{field.name}" }.join(", ")
    end

    # The form view's values: each input as the text its control shows.
    private def form_values(inputs : Array(ResourceField)) : String
      values = inputs.map do |field|
        text = field.kind == "time" ? "to_rfc3339" : "to_s"
        "#{field.name.to_json} => record.#{field.name}.try(&.#{text}) || \"\""
      end
      values.join(", ")
    end

    private def table_headers(fields : Array(ResourceField)) : String
      headers = fields.map do |field|
        "              th(scope: \"col\") { #{field.label.to_json} }"
      end
      headers.join('\n')
    end

    private def table_cells(fields : Array(ResourceField)) : String
      fields.map { |field| "                td { record.#{field.name} }" }.join('\n')
    end

    private def show_fields(fields : Array(ResourceField)) : String
      terms = fields.map do |field|
        "          dt { #{field.label.to_json} }\n          dd { @record.#{field.name} }"
      end
      terms.join('\n')
    end

    private def sample_fields(inputs : Array(ResourceField)) : String
      inputs.map { |field| "#{field.name.to_json} => #{field.sample.to_json}" }.join(", ")
    end

    private def sample_conditions(inputs : Array(ResourceField)) : String
      inputs.map { |field| "#{field.name}: #{field.literal(field.sample)}" }.join(", ")
    end

    private def updated_fields(inputs : Array(ResourceField)) : String
      updated = inputs.map do |field|
        "#{field.name.to_json} => #{field.updated_sample.to_json}"
      end
      updated.join(", ")
    end

    # The request spec's checks that each input saved its updated sample.
    private def assert_fields(inputs : Array(ResourceField)) : String
      checks = inputs.map do |field|
        sample = field.updated_sample.to_json
        type = ResourceField::TYPES[field.kind][0]
        "      persisted.#{field.name}.should eq(" \
        "Caramel::RequestContract.convert(#{sample}, #{type}))"
      end
      checks.join('\n')
    end

    # The request spec's checks that each text input's sample shows escaped.
    private def assert_escaping(inputs : Array(ResourceField)) : String
      checks = inputs.select { |field| field.kind == "string" }.map do |field|
        sample = field.sample.to_json
        "      shown.body.should contain(Caramel::HTML.escape(#{sample}))\n" \
        "      shown.body.should_not contain(#{sample})"
      end
      checks.join('\n')
    end

    # Keeps the template lines the generated actions need.
    private def select_lines(content : String, actions : Array(String)) : String
      kept = [] of Bool
      String.build do |io|
        content.each_line(chomp: false) do |line|
          if marker = line.chomp.match(MARKER)
            case marker[1]
            when "else" then kept.push(!kept.pop)
            when "end"  then kept.pop
            else             kept.push(keep?(marker[1], marker[2], actions))
            end
          elsif kept.all?
            io << line
          end
        end
      end
    end

    # `only` keeps a block when any action it names is generated; `unless`
    # keeps it when none is.
    private def keep?(kind : String, names : String, actions : Array(String)) : Bool
      named = names.split(',').any? { |action| actions.includes?(action) }
      kind == "only" ? named : !named
    end

    # The request spec loads the saved row for its update and changeset
    # checks. A resource that has neither must not load it: lint refuses a
    # variable nothing reads.
    private def without_unread_row(spec : String) : String
      return spec if spec.includes?("persisted.")

      spec.sub(/(?m)^ *persisted = .*\n/, "")
    end

    # The generated request spec's description of what it exercises.
    private def spec_title(actions : Array(String)) : String
      verbs = ["creates", "reads"]
      verbs << "updates" if actions.includes?("update")
      verbs << "deletes" if actions.includes?("destroy")
      through = actions.includes?("new") ? "browser forms" : "requests"
      "#{verbs[0...-1].join(", ")} and #{verbs.last} through CSRF-protected #{through}"
    end

    # Presence first, so a blank URL reports only that it is blank, then
    # URLs, then unique constraints.
    private def validations(required : Array(ResourceField),
                            fields : Array(ResourceField)) : String
      rules = required.map(&.presence_rule)
      rules += fields.select(&.url?).map(&.url_rule)
      rules += fields.select(&.unique?).map(&.unique_rule)
      rules.join('\n') { |rule| "      #{rule}" }
    end

    # Blank required text and repeated unique values must fail through the
    # generated changeset.
    private def assert_changeset(model : String,
                                 fields : Array(ResourceField),
                                 required : Array(ResourceField),
                                 actions : Array(String)) : String
      updated = actions.includes?("update")
      probes = fields.select(&.unique?).map do |unique|
        duplicate_probe(model, fields, unique, updated)
      end
      ([assert_presence(model, required)] + probes).reject(&.empty?).join('\n')
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
      id = SugarORM::Catalog::Column.new(
        name: "id",
        sql_type: "bigint",
        nullable: false,
        default: nil,
        primary: true,
        identity: true)
      columns = [id]
      columns.concat(fields.map(&.column))
      %w[created_at updated_at].each do |stamp|
        columns << SugarORM::Catalog::Column.new(
          name: stamp,
          sql_type: "timestamp with time zone",
          nullable: false,
          default: "CURRENT_TIMESTAMP")
      end
      indexes = fields.select(&.unique?).map do |field|
        SugarORM::Catalog::Index.new(index_name(table, field), [field.name], unique: true)
      end
      schema = [SugarORM::Catalog::Table.new(table, columns, indexes)]
      plan = SugarORM::Differ.diff(schema, [] of SugarORM::Catalog::Table)
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
        io << "      [App::" << model << ".create(" << blanks << "), "
        io << "persisted.update(" << blanks << ")].each do |blank|\n"
        io << "        blank.saved?.should be_false\n"
        fields.each do |field|
          io << "        blank.errors[" << field.name.to_json
          io << "]?.should eq([\"can't be blank\"])\n"
        end
        io << "      end"
      end
    end

    # A second row repeating a unique field must fail through the changeset's
    # unique_constraint, not a database error. Every other field takes a value
    # no row holds: an input its first sample, which the row replaced when it
    # was updated (its updated sample when the resource has no update), and
    # a server field its starting value.
    private def duplicate_probe(model : String, fields : Array(ResourceField),
                                unique : ResourceField, updated : Bool) : String
      values = fields.join(", ") do |field|
        value = if field.name == unique.name
                  "persisted.#{field.name}"
                elsif field.server?
                  field.starting_value
                else
                  field.literal(updated ? field.sample : field.updated_sample)
                end
        "#{field.name}: #{value}"
      end
      errors = "App::#{model}.create(#{values}).errors[#{unique.name.to_json}]?"
      %(      #{errors}.should eq(["has already been taken"]))
    end

    # The field's control, inside the generated form view's `labelled` helper.
    private def form_field(field : ResourceField) : String
      name = field.name.to_json
      required = field.nullable? ? "" : ", required: true"
      attributes = "id: id, name: #{name}#{required}, " \
                   "aria_describedby: \"\#{id}_errors\", " \
                   "aria_invalid: @errors.has_key?(#{name}).to_s"
      control = if field.kind == "bool"
                  select_control(field, name, attributes)
                else
                  input_control(field, name, attributes)
                end
      "        labelled #{name}, #{field.label.to_json} do |id|\n#{control}\n        end"
    end

    # A bool field's select, with an empty choice when it is nilable.
    private def select_control(field : ResourceField,
                               name : String,
                               attributes : String) : String
      options = field.nullable? ? ["", "true", "false"] : ["true", "false"]
      choices = options.map { |value| option_tag(name, value) }
      "          select_tag #{attributes} do\n#{choices.join('\n')}\n          end"
    end

    private def option_tag(name : String, value : String) : String
      label = (value.empty? ? "Unspecified" : value.capitalize).to_json
      "            option(value: #{value.to_json}, " \
      "selected: @values[#{name}]? == #{value.to_json}) { #{label} }"
    end

    private def input_control(field : ResourceField,
                              name : String,
                              attributes : String) : String
      type = input_type(field)
      extra = field.kind == "float64" ? ", step: \"any\"" : ""
      extra += ", placeholder: \"2026-09-19T12:00:00Z\"" if field.kind == "time"
      "          input type: \"#{type}\", #{attributes}#{extra}, " \
      "value: @values[#{name}]? || \"\""
    end

    private def input_type(field : ResourceField) : String
      return "number" if %w[int32 int64 float64].includes?(field.kind)

      field.url? ? "url" : "text"
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

    private def preflight(root : String,
                          files : Hash(String, String),
                          originals : Hash(String, String)) : Nil
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
          unless File.file?(path) && File.read(path) == original
            raise Error.new("Source changed while planning generation: #{relative}")
          end
        elsif File.info?(path, follow_symlinks: false)
          raise Error.new("File already exists: #{relative}; source was preserved")
        end
      end
    end

    private def publish(project : Project,
                        files : Hash(String, String),
                        originals : Hash(String, String)) : Nil
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
                unless File.read(path) == originals[relative]
                  raise Error.new("Source changed while generating: #{relative}")
                end
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
