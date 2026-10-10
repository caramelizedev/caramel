# Projections, and the row storage projections and processes share.
module SweetTalk
  # A read model: a table with one row per key, kept by Cold Brew jobs.
  abstract class Projection < Model
    include Keyed

    # `key tea : Catalogue::Tea` names the attribute that picks a row.
    macro key(decl)
      SWEETTALK_KEY = {{ decl.var.stringify }}

      has {{ decl }}
    end

    # `whenever Order::Placed, each: :lines do |placed, line| … end` updates rows from an
    # event, as a job, or one job per element of the event's list.
    macro whenever(event, border = nil, each = nil, &block)
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, nil, "projection", nil,
        {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # Rows, loading and saving, from the attributes declared so far.
    macro __sweettalk_storage
      ::SweetTalk.__sweettalk_keyed({{ @type }})
    end
  end

  # The row storage of a projection: `Name[key]` inside a handler, `all`, and the save
  # its unit of work calls.
  macro __sweettalk_keyed(owner)
    {% type = owner.resolve %}
    {% attributes = type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
         .map { |constant| type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
    {% key = attributes.find { |attribute| attribute[0] == type.constant("SWEETTALK_KEY") } %}
    {% moves = type.has_constant?("SWEETTALK_MOVES") %}
    {% row = type.constant("SWEETTALK_ROW").id %}
    {% table = type.constant("SWEETTALK_TABLE") %}
    {% short = type.name.split("::").last %}
    {% key_type = key[2] == "reference" ? "#{key[3].id}::Id".id : key[3].id %}
    {% key_columns = [] of Nil %}
    {% key_values = [] of Nil %}
    {% if key[2] == "composite" %}
      {% for part in key[7] %}
        {% key_columns << part[1] %}
        {% key_values << "#{key[0].id}.#{part[0].id}" + (part[4] == "value" ? ".raw" : "") %}
      {% end %}
    {% else %}
      {% key_columns << key[4] %}
      {% key_values << (key[2] == "column" ? key[0] : "#{key[0].id}.raw") %}
    {% end %}
    {% loads = [] of Nil %}
    {% columns = [] of Nil %}
    {% for attribute in attributes %}
      {% name = attribute[0].id %}
      {% if attribute[2] == "value" %}
        {% loads << "@#{name} = #{attribute[3].id}.new(row.#{attribute[4].id})" %}
        {% columns << "#{attribute[4].id}: @#{name}.raw" unless attribute == key %}
      {% elsif attribute[2] == "composite" %}
        {% parts = attribute[7].map do |part|
             read = "row.#{part[1].id}"
             "#{part[0].id}: " + (part[4] == "value" ? "#{part[3].id}.new(#{read.id})" : read)
           end %}
        {% loads << "@#{name} = #{attribute[3].id}.new(#{parts.join(", ").id})" %}
        {% for part in attribute[7] %}
          {% raw = part[4] == "value" ? ".raw" : "" %}
          {% columns << "#{part[1].id}: @#{name}.#{part[0].id}#{raw.id}" unless attribute == key %}
        {% end %}
      {% else %}
        {% loads << "@#{attribute[4].id} = row.#{attribute[4].id}" %}
        {% columns << "#{attribute[4].id}: @#{attribute[4].id}" unless attribute == key %}
      {% end %}
    {% end %}
    {% columns << "state: @state.to_s.downcase" if moves %}
    {% arguments = (["@__sweettalk_row"] + columns).join(", ") %}
    {% outside = "#{short.id}[…] is for whenever blocks; read with #{short.id}.all" %}
    {% quoted = key_columns.map { |column| "\"#{column.id}\"" }.join(", ") %}
    {% binds = key_columns.map_with_index { |_, index| "$#{index + 1}" }.join(", ") %}
    {% matches = key_columns.map_with_index do |column, index|
         "\"#{column.id}\" = $#{index + 1}"
       end %}
    {% locals = key_values.map_with_index { |_, index| "key_#{index}" }.join(", ") %}
    {% wheres = key_columns.map_with_index { |column, index| "#{column.id}: key_#{index}" } %}
    {% insert = "INSERT INTO \"#{table.id}\" (#{quoted.id}) VALUES (#{binds.id}) " +
                "ON CONFLICT (#{quoted.id}) DO NOTHING" %}
    {% lock = "SELECT id FROM \"#{table.id}\" WHERE #{matches.join(" AND ").id} FOR UPDATE" %}
    @__sweettalk_row : {{ row }}

    def initialize(*, stored row : {{ row }})
      @__sweettalk_row = row
      {{ loads.join("\n").id }}
      {% if moves %}
        @state = State.parse(row.state)
      {% end %}
    end

    # The row for *{{ key[0].id }}*, inserted with its defaults when absent and locked
    # for the rest of the handler. Only a handler may ask for one.
    def self.[]({{ key[0].id }} : {{ key_type }}) : self
      unit = ::Fiber.current.__sweettalk_unit || raise ArgumentError.new({{ outside }})
      {% for value, index in key_values %}
        key_{{ index }} = {{ value.id }}
      {% end %}
      text = "{{ type }}:" + [{{ locals.id }}].join(":")
      (unit.rows[text] ||= begin
        ::SugarORM.sql_exec({{ insert }}, {{ locals.id }})
        ::SugarORM.sql({{ lock }}, {{ locals.id }}, as: {id: Int64})
        new(stored: {{ row }}.query.where({{ wheres.join(", ").id }}).first!)
      end).as(self)
    end

    def self.all : Array(self)
      {{ row }}.query.order_by(:id, :asc).to_a.map { |row| new(stored: row) }
    end

    # The key as JSON, for a deadline's job, and back.
    def __sweettalk_key_json : String
      JSON.build { |json| ::SweetTalk.pack(json, {{ key[0].id }}) }
    end

    def self.__sweettalk_key_from(json : String) : {{ key_type }}
      ::SweetTalk.unpack({{ key_type }}, JSON.parse(json))
    end

    def __sweettalk_save : Nil
      changeset = {{ row }}::Changeset.new({{ arguments.id }})
      ::SugarORM::Repo.update(changeset)
      raise ::SweetTalk::Refusal.new(changeset.error_messages.join("; ")) unless changeset.saved?
      @__sweettalk_row = changeset.record
    end

    ::SweetTalk.__sweettalk_schema({{ type }})
  end
end
