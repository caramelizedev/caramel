# Entities, stored with their aggregate.
module SweetTalk
  # An entity inside an aggregate: a row of the aggregate's child table, or a detached
  # fact inside an event. Its `never` and `always` run with its aggregate's.
  abstract class Entity < Model
    include Guarded
    include Holding

    @__sweettalk_id : Int64? = nil

    # The constructors, facts, loading and saving, from the attributes declared so far; an
    # entity that holds entities loads, saves and drops them with its own (ADR 0050).
    macro __sweettalk_storage
      {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      {% collections = attributes.select { |attribute| attribute[2] == "entities" } %}
      {% row = @type.constant("SWEETTALK_ROW").id %}
      {% foreign = "#{@type.constant("SWEETTALK_PARENT")[0].id}_id".id %}
      {% own = "#{@type.constant("SWEETTALK_STORED").id}_id".id %}
      {% fk = "fk_#{@type.constant("SWEETTALK_TABLE").id}_#{foreign}" %}
      {% if fk.size > 63 %}
        {% path = @type.name.split("::") %}
        {% raise "entity #{path[-2].id}::#{path[-1].id} would name its key to its parent " +
                 "#{fk.id}, longer than PostgreSQL's 63 bytes: shorten its name or its parent's" %}
      {% end %}
      {% positional = [] of Nil %}
      {% keywords = [] of Nil %}
      {% loads = [] of Nil %}
      {% columns = [] of Nil %}
      {% facts = [] of Nil %}
      {% packs = [] of Nil %}
      {% for attribute, index in attributes %}
        {% name = attribute[0].id %}
        {% type = attribute[3].id %}
        {% base = attribute[10] %}
        {% nilable = attribute[9] %}
        {% default = attribute[8] %}
        {% default = "[] of #{attribute[3][6..-2].id}" if attribute[2] == "entities" %}
        {% trailing = true %}
        {% for later in attributes %}
          {% unset = !later[8] && later[2] != "entities" %}
          {% trailing = false if later[1] >= attribute[1] && unset %}
        {% end %}
        {% if attribute[2] == "reference" || attribute[2] == "record" %}
          {% target = "#{base.id}::Id" %}
          {% target = "::SweetTalk::RecordId(#{base.id})" if attribute[2] == "record" %}
          {% accepted = "#{base.id} | #{target.id}" %}
          {% accepted = "#{accepted.id} | Nil" if nilable %}
          {% positional << "#{name} : #{accepted.id}" +
                           (trailing && nilable ? " = #{default.id}" : "") %}
          {% keywords << "#{name} : #{accepted.id}" + (nilable ? " = #{default.id}" : "") %}
        {% else %}
          {% positional << "@#{name} : #{type}" + (trailing && default ? " = #{default.id}" : "") %}
          {% keywords << "#{name} : #{type}" + (default ? " = #{default.id}" : "") %}
        {% end %}
        {% if attribute[2] == "value" %}
          {% if nilable %}
            {% loads << "@#{name} = row.#{attribute[4].id}.try { |raw| #{base.id}.new(raw) }" %}
            {% columns << "#{attribute[4].id}: @#{name}.try(&.raw)" %}
          {% else %}
            {% loads << "@#{name} = #{type}.new(row.#{attribute[4].id})" %}
            {% columns << "#{attribute[4].id}: @#{name}.raw" %}
          {% end %}
        {% elsif attribute[2] == "composite" %}
          {% if nilable %}
            {% reads = attribute[7].map { |part| "#{part[0].id}: row.#{part[1].id}" } %}
            {% loads << "@#{name} = #{base.id}.__sweettalk_from_columns(#{reads.join(", ").id})" %}
            {% for part in attribute[7] %}
              {% raw = part[4] == "value" ? ".raw" : "" %}
              {% columns << "#{part[1].id}: @#{name}.try(&.#{part[0].id}#{raw.id})" %}
            {% end %}
          {% else %}
            {% parts = attribute[7].map do |part|
                 read = "row.#{part[1].id}"
                 "#{part[0].id}: " + (part[4] == "value" ? "#{part[3].id}.new(#{read.id})" : read)
               end %}
            {% loads << "@#{name} = #{type}.new(#{parts.join(", ").id})" %}
            {% for part in attribute[7] %}
              {% raw = part[4] == "value" ? ".raw" : "" %}
              {% columns << "#{part[1].id}: @#{name}.#{part[0].id}#{raw.id}" %}
            {% end %}
          {% end %}
        {% elsif attribute[2] == "entities" %}
        {% else %}
          {% loads << "@#{attribute[4].id} = row.#{attribute[4].id}" %}
          {% columns << "#{attribute[4].id}: @#{attribute[4].id}" %}
        {% end %}
        {% if attribute[2] == "reference" || attribute[2] == "record" %}
          {% read = nilable ? "as_i64?" : "as_i64" %}
          {% facts << "@#{attribute[4].id} = fact[#{attribute[4]}].#{read.id}" %}
          {% packs << "json.field(#{attribute[4]}, @#{attribute[4].id})" %}
        {% elsif attribute[2] == "entities" %}
          # A job queued before the entity held this list carries no key for it: empty.
          {% facts << "@#{name} = (listed = fact[#{attribute[0]}]?) ? " +
                      "::SweetTalk.unpack(#{type}, listed) : #{default.id}" %}
          {% packs << "json.field(#{attribute[0]}) { ::SweetTalk.pack(json, @#{name}) }" %}
        {% else %}
          {% facts << "@#{name} = ::SweetTalk.unpack(#{type}, fact[#{attribute[0]}])" %}
          {% packs << "json.field(#{attribute[0]}) { ::SweetTalk.pack(json, @#{name}) }" %}
        {% end %}
      {% end %}
      {% referring = attributes.select do |attribute|
           %w[reference record].includes?(attribute[2])
         end %}
      {% arguments = (["#{foreign}: #{foreign}"] + columns).join(", ") %}
      {% lists = collections.map do |collection|
           ", #{collection[0].id} : #{collection[3].id} = [] of #{collection[3][6..-2].id}"
         end %}
      @__sweettalk_row : {{ row }}? = nil

      # When this entity's row was inserted; nil until its aggregate is saved.
      def created_at : Time?
        @__sweettalk_row.try(&.created_at)
      end

      # When this entity's row last changed; nil until its aggregate is saved.
      def updated_at : Time?
        @__sweettalk_row.try(&.updated_at)
      end

      def initialize({{ positional.join(", ").id }})
        {% for attribute in referring %}
          @{{ attribute[4].id }} = ::SweetTalk.raw_id({{ attribute[0].id }})
        {% end %}
      end

      {% unless keywords.empty? %}
        # Every attribute by name, each that has a default or is optional left out when not
        # given, wherever it is declared.
        def initialize(*, {{ keywords.join(", ").id }})
          initialize({{ attributes.map(&.[0].id).splat }})
        end
      {% end %}

      {% for collection in collections %}
        # The ids of the rows this list was loaded with; a save deletes those it drops.
        @__sweettalk_loaded_{{ collection[0].id }} = [] of Int64
      {% end %}

      def initialize(*, stored row : {{ row }}{{ lists.join("").id }})
        @__sweettalk_row = row
        @__sweettalk_id = row.id
        {{ loads.join("\n").id }}
        {% for collection in collections %}
          @{{ collection[0].id }} = {{ collection[0].id }}
          @__sweettalk_loaded_{{ collection[0].id }} =
            {{ collection[0].id }}.map(&.__sweettalk_raw_id)
        {% end %}
      end

      # Builds one entity per row, with its lists read in one statement per list for every
      # row at once, and none for an empty level.
      def self.__sweettalk_load(rows : Array({{ row }})) : Array(self)
        {% if collections.empty? %}
          rows.map { |row| new(stored: row) }
        {% else %}
          ids = rows.map(&.id)
          {% for collection in collections %}
            {% child = collection[3][6..-2].id %}
            {% name = collection[0].id %}
            rows_{{ name }} = if ids.empty?
                                [] of {{ row }}::{{ child }}
                              else
                                {{ row }}::{{ child }}.query.where({{ own }}: ids)
                                  .order_by(:id, :asc).to_a
                              end
            built_{{ name }} = {{ child }}.__sweettalk_load(rows_{{ name }}).zip(rows_{{ name }})
            by_{{ name }} = built_{{ name }}.group_by { |pair| pair[1].{{ own }} }
          {% end %}
          {% children = collections.map do |collection|
               ", #{collection[0].id}: (by_#{collection[0].id}[row.id]? || " +
                 "[] of {#{collection[3][6..-2].id}, #{row}::#{collection[3][6..-2].id}})" +
                 ".map(&.[0])"
             end %}
          rows.map { |row| new(stored: row{{ children.join("").id }}) }
        {% end %}
      end

      # Deletes the rows *query* matches with every row of every list under them, innermost
      # first, one statement per list per level.
      def self.__sweettalk_drop(query) : Nil
        {% for collection in collections %}
          {% child = collection[3][6..-2].id %}
          {{ child }}.__sweettalk_drop({{ row }}::{{ child }}.query.where_in(:{{ own }}, query))
        {% end %}
        query.delete_all
      end

      # This entity's typed id, once its aggregate is saved.
      struct Id < ::SweetTalk::Identity
        include ::Caramel::FieldValue(Int64)

        getter raw : Int64

        def initialize(@raw : Int64)
        end

        # Builds the id a contract field binds; any Int64 is one.
        def self.from_field(raw : Int64, & : String ->) : self
          new(raw)
        end

        def to_s(io : IO) : Nil
          io << raw
        end
      end

      def id : Id
        Id.new(__sweettalk_raw_id)
      end

      # A detached copy rebuilt from an event's facts; it has no row. A job queued before
      # facts carried an id holds none: nil.
      def initialize(*, fact : JSON::Any)
        @__sweettalk_id = fact["id"]?.try(&.as_i64?)
        {{ facts.join("\n").id }}
      end

      def self.__sweettalk_unpack(any : JSON::Any) : self
        new(fact: any)
      end

      # Writes this entity's attributes as a fact, after its id: the row's, or null until its
      # aggregate is saved.
      def __sweettalk_pack(json : JSON::Builder) : Nil
        json.object do
          json.field("id", @__sweettalk_id)
          {{ packs.join("\n").id }}
        end
      end

      {% constraints = @type.constants.select(&.starts_with?("SWEETTALK_CONSTRAINT_"))
           .map { |constant| @type.constant(constant) }.sort_by { |constraint| constraint[1] } %}
      # The sentence each unique index and check this entity declared refuses with, by the
      # constraint's name (ADR 0045); a violation of any other constraint stays raw.
      SWEETTALK_REFUSALS = {
        {% for constraint in constraints %}
          {% if constraint[4] %}
            {{ constraint[3].id }} => {{ constraint[4] }},
          {% end %}
        {% end %}
      } of String => String

      # Inserts or updates this entity's row under its parent; returns its id. A row
      # another parent holds, or one a rolled-back create or factory left behind, is not
      # this parent's, so the entity is inserted again as a new row of its own. A row whose
      # columns all hold what the entity says is left as it is: no statement. The rows each
      # list loaded and dropped are deleted first, then each kept entity is saved in turn.
      def __sweettalk_save(*, {{ foreign }} : Int64) : Int64
        row = @__sweettalk_row
        row = nil if row && row.{{ foreign }} != {{ foreign }}
        {% for collection in collections %}
          if row
            held = @{{ collection[0].id }}.compact_map { |entity| entity.@__sweettalk_id }
            dropped = @__sweettalk_loaded_{{ collection[0].id }} - held
            unless dropped.empty?
              {{ collection[3][6..-2].id }}.__sweettalk_drop(
                {{ row }}::{{ collection[3][6..-2].id }}.query.where({{ own }}: row.id)
                  .where(id: dropped))
            end
          end
        {% end %}
        changeset = if row
                      {{ row }}::Changeset.new(row, {{ arguments.id }})
                    else
                      {{ row }}::Changeset.new({{ arguments.id }})
                    end
        id = if row && changeset.changes.empty? && changeset.valid?
               row.id
             else
               __sweettalk_write(row, changeset)
             end
        {% for collection in collections %}
          @__sweettalk_loaded_{{ collection[0].id }} =
            @{{ collection[0].id }}.map(&.__sweettalk_save({{ own }}: id))
        {% end %}
        id
      end

      private def __sweettalk_write(row : {{ row }}?, changeset : {{ row }}::Changeset) : Int64
        begin
          row ? ::SugarORM::Repo.update(changeset) : ::SugarORM::Repo.insert(changeset)
        rescue error : ::SugarORM::UniqueViolation | ::SugarORM::CheckViolation
          ::SweetTalk.__sweettalk_refuse(error, SWEETTALK_REFUSALS)
        end
        raise ::SweetTalk::Refusal.new(changeset.error_messages.join("; ")) unless changeset.saved?
        @__sweettalk_row = changeset.record
        @__sweettalk_id = changeset.record.id
      end
    end

    # Runs every `never` and `always` of this entity, then of each entity in its lists.
    def __sweettalk_check : Nil
      {% for method in @type.methods %}
        {% if method.name.starts_with?("__sweettalk_never_") ||
                method.name.starts_with?("__sweettalk_always_") %}
          {{ method.name }}
        {% end %}
      {% end %}
      {% for constant in @type.constants.select(&.starts_with?("SWEETTALK_HAS_")) %}
        {% if @type.constant(constant)[2] == "entities" %}
          @{{ @type.constant(constant)[0].id }}.each(&.__sweettalk_check)
        {% end %}
      {% end %}
    end

    def __sweettalk_raw_id : Int64
      short = self.class.name.split("::").last
      @__sweettalk_id ||
        raise NilAssertionError.new("#{short} has no id until its aggregate is saved")
    end
  end
end
