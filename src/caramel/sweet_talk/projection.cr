# Projections, and the row storage projections and processes share.
module SweetTalk
  # A read model: a table with one row per key, kept by Cold Brew jobs.
  abstract class Projection < Model
    include Keyed
    include Queried

    # `key tea : Catalogue::Tea` names the attribute that picks a row.
    macro key(decl)
      SWEETTALK_KEY = {{ decl.var.stringify }}

      has {{ decl }}
    end

    # `whenever Order::Placed, each: :lines do |placed, line| … end` updates rows from an
    # event, as a job, or one job per element of the event's list; `attempts:`,
    # `backoff:` and `base:` set the job's retry rule.
    macro whenever(event, border = nil, each = nil, attempts = nil, backoff = nil, base = nil,
                   &block)
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, nil, "projection", nil,
        {{ attempts }}, {{ backoff }}, {{ base }}, {{ block.args.splat }}) do
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
      {% base = attribute[10].id %}
      {% nilable = attribute[9] %}
      {% if attribute[2] == "value" %}
        {% if nilable %}
          {% loads << "@#{name} = row.#{attribute[4].id}.try { |raw| #{base}.new(raw) }" %}
          {% columns << "#{attribute[4].id}: @#{name}.try(&.raw)" unless attribute == key %}
        {% else %}
          {% loads << "@#{name} = #{attribute[3].id}.new(row.#{attribute[4].id})" %}
          {% columns << "#{attribute[4].id}: @#{name}.raw" unless attribute == key %}
        {% end %}
      {% elsif attribute[2] == "composite" %}
        {% if nilable %}
          {% reads = attribute[7].map { |part| "#{part[0].id}: row.#{part[1].id}" } %}
          {% loads << "@#{name} = #{base}.__sweettalk_from_columns(#{reads.join(", ").id})" %}
          {% for part in attribute[7] %}
            {% raw = part[4] == "value" ? ".raw" : "" %}
            {% columns << "#{part[1].id}: @#{name}.try(&.#{part[0].id}#{raw.id})" %}
          {% end %}
        {% else %}
          {% parts = attribute[7].map do |part|
               read = "row.#{part[1].id}"
               "#{part[0].id}: " + (part[4] == "value" ? "#{part[3].id}.new(#{read.id})" : read)
             end %}
          {% loads << "@#{name} = #{attribute[3].id}.new(#{parts.join(", ").id})" %}
          {% for part in attribute[7] %}
            {% raw = part[4] == "value" ? ".raw" : "" %}
            {% unless attribute == key %}
              {% columns << "#{part[1].id}: @#{name}.#{part[0].id}#{raw.id}" %}
            {% end %}
          {% end %}
        {% end %}
      {% else %}
        {% loads << "@#{attribute[4].id} = row.#{attribute[4].id}" %}
        {% columns << "#{attribute[4].id}: @#{attribute[4].id}" unless attribute == key %}
      {% end %}
    {% end %}
    {% columns << "state: __sweettalk_state" if moves %}
    {% arguments = (["@__sweettalk_row"] + columns).join(", ") %}
    {% outside = "#{short.id}[…] is for whenever blocks; read with #{short.id}.all" %}
    {% locals = key_values.map_with_index { |_, index| "key_#{index}" }.join(", ") %}
    {% wheres = key_columns.map_with_index { |column, index| "#{column.id}: key_#{index}" } %}
    @__sweettalk_row : {{ row }}

    def initialize(*, stored row : {{ row }})
      @__sweettalk_row = row
      {{ loads.join("\n").id }}
      {% if moves %}
        @state = State.parse(row.state)
      {% end %}
    end

    # The row for *{{ key[0].id }}*, locked for the rest of the handler; when absent it is
    # inserted with its defaults through `Start`, an upsert that leaves one row when two
    # handlers insert one key. Only a handler may ask for one.
    def self.[]({{ key[0].id }} : {{ key_type }}) : self
      work = ::Fiber.current.__sweettalk_work || raise ArgumentError.new({{ outside }})
      {% for value, index in key_values %}
        key_{{ index }} = {{ value.id }}
      {% end %}
      text = "{{ type }}:" + [{{ locals.id }}].join(":")
      (work.rows[text] ||= begin
        query = {{ row }}.query.where({{ wheres.join(", ").id }}).lock
        stored = query.first || begin
          start = {{ row }}::Start.new({{ wheres.join(", ").id }})
          ::SugarORM::Repo.insert(start)
          raise ::SweetTalk::Refusal.new(start.error_messages.join("; ")) unless start.saved?
          query.first!
        end
        new(stored: stored)
      end).as(self)
    end

    def self.all : Array(self)
      {{ row }}.query.order_by(:id, :asc).to_a.map { |row| new(stored: row) }
    end

    # The rows every `finds` and `counts` starts from: all of them.
    protected def self.__sweettalk_live
      {{ row }}.query
    end

    # Builds a projection or a process from each row the query reads. Protected, as an
    # aggregate's is.
    protected def self.__sweettalk_rows(query) : Array(self)
      query.to_a.map { |row| new(stored: row) }
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
