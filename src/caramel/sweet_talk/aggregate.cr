# Aggregates: identity, repository, factories, queries, commands and removal.
module SweetTalk
  # An aggregate root: identity, a repository, a lifecycle, invariants, and commands
  # that run as one transaction on this aggregate alone.
  abstract class Aggregate < Model
    include Guarded
    include Lifecycle
    include Queried

    @__sweettalk_id : Int64? = nil
    @__sweettalk_removed_at : Time? = nil
    @__sweettalk_events = [] of ::SweetTalk::Event
    # False once found with `entities: false`: the lists are empty and may not be read.
    @__sweettalk_entities = true

    # `entity Line, means: "…" do … end` is an entity inside this aggregate, stored in a
    # child table named after the aggregate. In a tenanted context the aggregate's key
    # column may not be the tenant's.
    macro entity(name, means = nil, renamed_from = nil, &block)
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
      {% stored = (renamed_from || name).stringify.underscore %}
      {% table = "#{@type.constant("SWEETTALK_BASE").id}_#{stored.id}" %}
      {% parent = {@type.constant("SWEETTALK_STORED"), @type.constant("SWEETTALK_ROW")} %}
      {% home = ::SweetTalk::BoundedContext.includers
           .find { |context| @type.name.starts_with?("#{context.name}::") } %}
      {% tenant = home && home.constant("SWEETTALK_TENANT") %}
      {% if tenant && parent[0] == tenant[1] %}
        {% name.raise "entity #{name} would name its aggregate in #{tenant[1].id}_id, the " +
                      "column that names each row's tenant #{tenant[0].id}: rename aggregate " +
                      "#{@type.name.split("::").last.id}" %}
      {% end %}
      class {{ name }} < ::SweetTalk::Entity
        SWEETTALK_KIND   = "entity"
        SWEETTALK_MEANS  = {{ means }}
        SWEETTALK_ROW    = {{ "#{@type.constant("SWEETTALK_ROW").id}::#{name}" }}
        SWEETTALK_PARENT = {{ parent }}
        ::SweetTalk.__sweettalk_table({{ table }},
          {{ "entity #{@type.name.split("::").last.id}::#{name}" }})

        {{ block ? block.body : nil }}

        __sweettalk_storage
      end
    end

    # `event Placed, lines : Array(Line), means: "…"` is one of this aggregate's events. It
    # records its subject and its fields when it is emitted, with an id, the time and the
    # actor. `carries: [member, total]` adds one field for each attribute or derived value
    # it names, of that attribute's type, which `emit` reads from the aggregate and a command
    # cannot give; the attribute is declared above the event. Its channel fits
    # PostgreSQL's 63 characters, or 42 in a program that requires caramel/tenancy, which
    # prefixes a tenant's `t<id>:`. `SWEETTALK_CARRIES` lists the names it carries.
    macro event(name, *fields, carries = nil, means = nil, renamed_from = nil)
      {% subject = @type.name.split("::").last.underscore.id %}
      {% reserved = %w[event_id occurred_at actor cause_id flow_id] + ["#{subject}_id"] %}
      {% short = @type.name.split("::").last %}
      {% names = fields.map(&.var.stringify) %}
      {% carried = [] of Nil %}
      {% unless carries.is_a?(NilLiteral) %}
        {% unless carries.is_a?(ArrayLiteral) && carries.size > 0 %}
          {% carries.raise "event #{name} takes carries: a list of #{short.id}'s attributes or " +
                           "derived values, as in carries: [member, total], not #{carries}" %}
        {% end %}
        {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
             .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
        {% deriveds = @type.constants.select(&.starts_with?("SWEETTALK_THE_"))
             .map { |constant| @type.constant(constant) }.sort_by { |derived| derived[1] } %}
        {% for item in carries %}
          {% label = item.id.stringify %}
          {% attribute = attributes.find { |candidate| candidate[0] == label } %}
          {% derived = deriveds.find { |candidate| candidate[0] == label } %}
          {% unless attribute || derived %}
            {% have = (attributes.map(&.[0]) + deriveds.map(&.[0])).join(", ") %}
            {% item.raise "event #{name} carries #{label.id}, which #{short.id} does not have " +
                          "above it; it has #{have.id}: declare #{label.id} before the event" %}
          {% end %}
          {% if reserved.includes?(label) %}
            {% item.raise "event #{name} cannot have a field named #{label.id}: SweetTalk " +
                          "records it" %}
          {% end %}
          {% if names.includes?(label) %}
            {% item.raise "event #{name} has a field named #{label.id} twice: carry it, or " +
                          "declare it, not both" %}
          {% end %}
          {% type = derived ? derived[2] : attribute[3] %}
          {% if attribute && attribute[2] == "reference" %}
            {% optional = attribute[9] ? "?" : "" %}
            {% type = "#{attribute[10].id}::Id#{optional.id}" %}
          {% elsif attribute && attribute[2] == "record" %}
            {% optional = attribute[9] ? "?" : "" %}
            {% type = "::SweetTalk::RecordId(#{attribute[10].id})#{optional.id}" %}
          {% end %}
          {% names << label %}
          {% carried << {label, type} %}
        {% end %}
      {% end %}
      {% stored = (renamed_from || name).stringify.underscore %}
      {% context = @type.constant("SWEETTALK_CONTEXT") %}
      {% aggregate = @type.constant("SWEETTALK_STORED") %}
      {% channel = "sweettalk.#{context.id}.#{aggregate.id}.#{stored.id}" %}
      {% pairs = carried.empty? ? "[] of Nil".id : carried %}
      ::SweetTalk.__sweettalk_event({{ name }}{% for field in fields %}, {{ field }}{% end %},
        carried: {{ pairs }}, channel: {{ channel }}, means: {{ means }},
        renamed_from: {{ renamed_from }}, subject: ::{{ @type }}, tenanted: false)
    end

    # `emit Placed, lines: lines` records an event; the command dispatches it when it
    # commits. A field the event carries is read from the aggregate as it is now, and a
    # command cannot give it.
    macro emit(event, **fields)
      {% own = event.is_a?(Path) && event.names.size == 1 &&
               @type.has_constant?(event.names[0].stringify) %}
      {% unless own %}
        {% event.raise "#{@type.name.split("::").last.id} emits only its own events, " +
                       "and #{event} is not one of them" %}
      {% end %}
      {% given = fields.map { |key, value| ", #{key}: #{value}" }.join("") %}
      {% given_names = fields.keys.map(&.stringify) %}
      {% for label in @type.constant(event.names[0].stringify).constant("SWEETTALK_CARRIES") %}
        {% if given_names.includes?(label) %}
          {% event.raise "emit #{event} gives #{label.id}, which the event carries from " +
                         "#{@type.name.split("::").last.id}: it is read from the aggregate, so " +
                         "an event cannot say what the aggregate does not hold; change " +
                         "#{label.id} before the emit, or declare a field of another name " +
                         "instead of carrying it" %}
        {% end %}
        {% given = "#{given.id}, #{label.id}: self.#{label.id}" %}
      {% end %}
      @__sweettalk_events << {{ event }}.new(self{{ given.id }})
    end

    # `to restock(tins : Tins) do … end` is a command, timed as a domain span named
    # `Catalogue::Tea#restock`.
    macro to(call, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "to takes a verb and typed arguments, " +
                      "as in to restock(tins : Tins) do … end" %}
      {% end %}
      {% if call.name == "finalize" %}
        {% call.raise "command finalize would replace the garbage collector's finalize on " +
                      "#{@type.name.split("::").last.id}: name it for what it does, as in " +
                      "to wind_up" %}
      {% end %}
      {% parts = @type.name.split("::") %}
      {% span = "#{parts[-2].id}::#{parts[-1].id}##{call.name}" %}
      __sweettalk_no_stray_writes({{ call.name.stringify }}, {{ block.body.stringify }})
      def {{ call.name }}({{ call.args.splat }}) : Nil
        ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
          __sweettalk_command do
            {{ block.body }}
          end
        end
      end

      # Typed by `SweetTalk.boot`, so the body compiles whether or not anything calls it.
      def self.__sweettalk_touch_{{ call.name }} : Nil
        {% params = ["aggregate : self"] + call.args.map { |arg| "#{arg.var} : #{arg.type}" } %}
        {% names = call.args.map(&.var) %}
        ->({{ params.join(", ").id }}) { aggregate.{{ call.name }}({{ names.splat }}) }
        nil
      end
    end

    # `factory open(member : Account, …) do … end` is the way to make this aggregate. It
    # builds the aggregate from the arguments named like its attributes, then runs the body
    # as its first change, in one transaction: the body may emit, and the events are
    # dispatched once the aggregate is saved and has an id. An aggregate with a factory
    # has no `create`. It is timed as a domain span named `Ordering::Order.open`.
    macro factory(call, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "factory takes a verb and typed arguments, " +
                      "as in factory open(member : Account) do … end" %}
      {% end %}
      {% verb = call.name %}
      {% parts = @type.name.split("::") %}
      {% short = parts.last %}
      {% span = "#{parts[-2].id}::#{short.id}.#{verb}" %}
      {% if %w[create find find? all new allocate].includes?(verb.stringify) %}
        {% call.raise "factory #{verb} would replace #{short.id}.#{verb}: " +
                      "name it for what it makes, as in factory open" %}
      {% end %}
      {% at = "\n  --> #{call.filename.id}:#{call.line_number}:#{call.column_number}" %}
      {% given = call.args.map(&.var.stringify) %}
      {% factory = {verb.stringify, call.line_number} %}
      __sweettalk_no_stray_writes({{ verb.stringify }},
        {{ block.body.stringify }})
      SWEETTALK_FACTORY_{{ verb.upcase }} = {{ factory }}

      def self.{{ verb }}({{ call.args.splat }}) : self
        \{% begin %}
          \{% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
               .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
          \{% for attribute in attributes %}
            \{% set = {{ given }}.includes?(attribute[0]) || attribute[8] ||
                     attribute[2] == "entities" %}
            \{% unless set %}
              \{% raise "factory {{ verb }} does not set #{attribute[0].id}: take " +
                       "#{attribute[0].id} : #{attribute[3].id}, or give has " +
                       "#{attribute[0].id} a default" + {{ at }} %}
            \{% end %}
          \{% end %}
          \{% named = attributes.select { |attribute| {{ given }}.includes?(attribute[0]) }
               .map { |attribute| "#{attribute[0].id}: #{attribute[0].id}" } %}
          ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
            ::SweetTalk.__sweettalk_enter(self)
            aggregate = __sweettalk_assemble(\{{ named.join(", ").id }})
            aggregate.__sweettalk_make_{{ verb }}({{ call.args.map(&.var).splat }})
            aggregate
          end
        \{% end %}
      end

      def __sweettalk_make_{{ verb }}({{ call.args.splat }}) : Nil
        __sweettalk_making { __sweettalk_factory_{{ verb }}({{ call.args.map(&.var).splat }}) }
      end

      private def __sweettalk_factory_{{ verb }}({{ call.args.splat }}) : Nil
        {{ block.body }}
      end

      # Typed by `SweetTalk.boot`, so the body compiles whether or not anything calls it.
      def self.__sweettalk_touch_{{ verb }} : Nil
        {% params = call.args.map { |arg| "#{arg.var} : #{arg.type}" } %}
        ->({{ params.join(", ").id }}) { {{ verb }}({{ call.args.map(&.var).splat }}) }
        nil
      end
    end

    # The id, constructors, repository, saving and the command transaction, from the
    # attributes declared so far; then the tables, the root's first.
    macro __sweettalk_storage
      {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      {% stored = attributes.reject { |attribute| attribute[2] == "entities" } %}
      {% collections = attributes.select { |attribute| attribute[2] == "entities" } %}
      {% moves = @type.has_constant?("SWEETTALK_MOVES") %}
      {% row = @type.constant("SWEETTALK_ROW").id %}
      {% table = @type.constant("SWEETTALK_TABLE") %}
      {% short = @type.name.split("::").last %}
      {% foreign = "#{@type.constant("SWEETTALK_STORED").id}_id".id %}
      {% factories = @type.constants.select(&.starts_with?("SWEETTALK_FACTORY_")) %}
      {% home = ::SweetTalk::BoundedContext.includers
           .find { |context| @type.name.starts_with?("#{context.name}::") } %}
      {% tenant = home && home.constant("SWEETTALK_TENANT") %}
      {% positional = [] of Nil %}
      {% keywords = [] of Nil %}
      {% loads = [] of Nil %}
      {% columns = [] of Nil %}
      {% copies = [] of Nil %}
      {% for attribute in attributes %}
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
          {% copies << "@#{name} = fresh.@#{name}" %}
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
          {% copies << "@#{name} = fresh.@#{name}" %}
        {% elsif attribute[2] == "entities" %}
          {% copies << "@#{name} = fresh.@#{name}" %}
        {% else %}
          {% loads << "@#{attribute[4].id} = row.#{attribute[4].id}" %}
          {% columns << "#{attribute[4].id}: @#{attribute[4].id}" %}
          {% copies << "@#{attribute[4].id} = fresh.@#{attribute[4].id}" %}
        {% end %}
      {% end %}
      {% columns << "state: __sweettalk_state" if moves %}
      {% columns << "removed_at: @__sweettalk_removed_at" %}
      {% referring = stored.select { |attribute| %w(reference record).includes?(attribute[2]) } %}
      {% lists = collections.map { |collection| ", #{collection[0].id} : #{collection[3].id}" } %}
      {% preloads = collections.map { |collection| ".preload(:#{collection[0].id})" } %}
      {% children = collections.map do |collection|
           child = collection[3][6..-2].id
           name = collection[0].id
           ", #{name}: loaded.#{name}.map { |child| #{child}.new(stored: child) }"
         end %}
      {% empties = collections.map do |collection|
           ", #{collection[0].id}: #{collection[3].id}.new"
         end %}
      {% missing = "There is no #{short.id} " %}
      @__sweettalk_row : {{ row }}? = nil

      # When this aggregate's row was inserted; nil until it is saved.
      def created_at : Time?
        @__sweettalk_row.try(&.created_at)
      end

      # When this aggregate's row last changed; nil until it is saved.
      def updated_at : Time?
        @__sweettalk_row.try(&.updated_at)
      end

      {% if tenant %}
        # The id of the tenant this aggregate belongs to: its row's, or the bound tenant's
        # before it is first saved.
        def tenant_id : Int64
          if row = @__sweettalk_row
            row.{{ tenant[1].id }}_id
          else
            ::Caramel::Tenancy.current.id
          end
        end

        # The tenant this aggregate belongs to, read from the tenant model.
        def tenant : ::{{ tenant[0].id }}
          ::Caramel::Tenancy.find(tenant_id).not_nil!
        end
      {% end %}

      # This aggregate's typed id.
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

        # The table whose row this id names, and the lock of a batch of such rows, for
        # `SweetTalk.lock` (ADR 0046).
        def __sweettalk_table : String
          {{ table }}
        end

        def __sweettalk_lock(raws : Array(Int64)) : Nil
          {{ @type }}.__sweettalk_lock(raws)
        end
      end

      def self.__sweettalk_table : String
        {{ table }}
      end

      # Locks the live rows of *raws* `FOR UPDATE`, by id, in one statement; an id with no
      # live row raises `Missing`.
      def self.__sweettalk_lock(raws : Array(Int64)) : Nil
        held = {{ row }}.query.where(removed_at: nil).where(id: raws).order_by(:id, :asc).lock
        absent = raws - held.to_a.map(&.id)
        return if absent.empty?
        raise ::SweetTalk::Missing.new("{{ missing.id }}#{absent.first}.")
      end

      def initialize({{ positional.join(", ").id }})
        {% for attribute in referring %}
          @{{ attribute[4].id }} = ::SweetTalk.raw_id({{ attribute[0].id }})
        {% end %}
      end

      {% for collection in collections %}
        # The ids of the rows this list was loaded with; a save deletes those it drops.
        @__sweettalk_loaded_{{ collection[0].id }} = [] of Int64
      {% end %}

      def initialize(*, stored row : {{ row }}, entities : Bool = true{{ lists.join("").id }})
        @__sweettalk_row = row
        @__sweettalk_id = row.id
        @__sweettalk_removed_at = row.removed_at
        @__sweettalk_entities = entities
        {{ loads.join("\n").id }}
        {% for collection in collections %}
          @{{ collection[0].id }} = {{ collection[0].id }}
          @__sweettalk_loaded_{{ collection[0].id }} =
            {{ collection[0].id }}.map(&.__sweettalk_raw_id)
        {% end %}
        {% if moves %}
          @state = State.parse(row.state)
        {% end %}
      end

      def id : Id
        Id.new(__sweettalk_raw_id)
      end

      {% for collection in collections %}
        # The list, once loaded; an aggregate found with `entities: false` has none to read.
        def {{ collection[0].id }} : {{ collection[3].id }}
          return @{{ collection[0].id }} if @__sweettalk_entities
          raise ::SweetTalk::Unloaded.new("{{ short.id }} #{@__sweettalk_id} was found without " +
                                          "its {{ collection[0].id }}: find it with entities")
        end
      {% end %}

      # The aggregate `create` and a factory start from: every attribute by name, each that has
      # a default or is optional left out when not given, wherever it is declared. An aggregate
      # without attributes takes none, since a bare `*` needs a name after it.
      {% named = keywords.empty? ? "" : "*, #{keywords.join(", ").id}" %}
      protected def self.__sweettalk_assemble({{ named.id }}) : self
        new({{ attributes.map(&.[0].id).splat }})
      end

      {% if factories.empty? %}
        {% span = "#{@type.name.split("::")[-2].id}::#{short.id}.create" %}
        # Checks the invariants and inserts the root, then its entities, in one transaction,
        # timed as a domain span named `Catalogue::Tea.create`.
        def self.create({{ named.id }}) : self
          ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
            ::SweetTalk.__sweettalk_enter(self)
            aggregate = new({{ attributes.map(&.[0].id).splat }})
            ::SugarORM::Repo.transaction do
              aggregate.__sweettalk_check
              aggregate.__sweettalk_save
            end
            ::SweetTalk.__sweettalk_created(aggregate)
            aggregate
          end
        end
      {% end %}

      # The aggregate by id, or nil. `entities: false` reads the root alone, in one
      # statement: its lists cannot be read, and a command on it loads them.
      def self.find?(id : Id, *, entities : Bool = true) : self?
        ::SweetTalk.__sweettalk_checked
        __sweettalk_find?(id.raw, entities)
      end

      def self.find(id : Id, *, entities : Bool = true) : self
        find?(id, entities: entities) || raise ::SweetTalk::Missing.new("{{ missing.id }}#{id}.")
      end

      def self.__sweettalk_find?(raw : Int64, entities : Bool = true) : self?
        query = {{ row }}.query.where(removed_at: nil).where(id: raw)
        __sweettalk_rows(query, entities).first?
      end

      def self.all : Array(self)
        __sweettalk_rows(__sweettalk_live.order_by(:id, :asc))
      end

      # The rows every `finds` and `counts` starts from: those not removed.
      protected def self.__sweettalk_live
        {{ row }}.query.where(removed_at: nil)
      end

      # The aggregates that satisfy *satisfying*, a specification on this aggregate, by
      # id: the rule its predicate reads in Crystal, read by PostgreSQL.
      def self.all(*, satisfying : S.class) : Array(self) forall S
        \{% unless S < ::SweetTalk::Specification &&
                    S.constant("SWEETTALK_ON") == {{ @type.name.stringify }} %}
          \{% raise "{{ short.id }}.all(satisfying: #{S}) takes a specification on " +
                   "{{ short.id }}" %}
        \{% end %}
        query = __sweettalk_live.where_condition(S.__sweettalk_condition)
        __sweettalk_rows(query.order_by(:id, :asc))
      end

      # Builds an aggregate from each row the query reads, with one more query per
      # collection of entities, or none when *entities* is false. Protected: only this
      # aggregate's own repository builds aggregates from rows.
      protected def self.__sweettalk_rows(query, entities : Bool = true) : Array(self)
        {% if collections.empty? %}
          query.to_a.map { |row| new(stored: row) }
        {% else %}
          unless entities
            return query.to_a.map do |row|
              new(stored: row, entities: false{{ empties.join("").id }})
            end
          end
          query{{ preloads.join("").id }}.to_a.map do |loaded|
            new(stored: loaded.record{{ children.join("").id }})
          end
        {% end %}
      end

      {% constraints = @type.constants.select(&.starts_with?("SWEETTALK_CONSTRAINT_"))
           .map { |constant| @type.constant(constant) }.sort_by { |constraint| constraint[1] } %}
      # The sentence each unique index and check this aggregate declared refuses with, by
      # the constraint's name (ADR 0045); a violation of any other constraint stays raw.
      SWEETTALK_REFUSALS = {
        {% for constraint in constraints %}
          {% if constraint[4] %}
            {{ constraint[3].id }} => {{ constraint[4] }},
          {% end %}
        {% end %}
      } of String => String

      # Deletes, in one statement per list, the entity rows this aggregate loaded and no
      # longer holds, and none when it dropped none; then writes the root through its
      # changeset and each entity, each only when a column changes. The deletes come first
      # so an entity replaced by one with the same unique value saves.
      def __sweettalk_save : Nil
        {% for collection in collections %}
          held = @{{ collection[0].id }}.compact_map { |entity| entity.@__sweettalk_id }
          dropped = @__sweettalk_loaded_{{ collection[0].id }} - held
          unless dropped.empty?
            {{ row }}::{{ collection[3][6..-2].id }}.query.where({{ foreign }}: __sweettalk_raw_id)
              .where(id: dropped).delete_all
          end
        {% end %}
        changeset = if row = @__sweettalk_row
                      {{ row }}::Changeset.new(row, {{ columns.join(", ").id }})
                    else
                      {{ row }}::Changeset.new({{ columns.join(", ").id }})
                    end
        unless row && changeset.changes.empty? && changeset.valid?
          begin
            row ? ::SugarORM::Repo.update(changeset) : ::SugarORM::Repo.insert(changeset)
          rescue error : ::SugarORM::UniqueViolation | ::SugarORM::CheckViolation
            ::SweetTalk.__sweettalk_refuse(error, SWEETTALK_REFUSALS)
          end
          unless changeset.saved?
            raise ::SweetTalk::Refusal.new(changeset.error_messages.join("; "))
          end
          @__sweettalk_row = changeset.record
          @__sweettalk_id = changeset.record.id
        end
        {% for collection in collections %}
          @__sweettalk_loaded_{{ collection[0].id }} =
            @{{ collection[0].id }}.map(&.__sweettalk_save({{ foreign }}: __sweettalk_raw_id))
        {% end %}
      end

      # Takes the state of *fresh*, a copy just read from the database.
      def __sweettalk_copy(fresh : self) : Nil
        @__sweettalk_row = fresh.@__sweettalk_row
        @__sweettalk_removed_at = fresh.@__sweettalk_removed_at
        @__sweettalk_entities = fresh.@__sweettalk_entities
        {{ copies.join("\n").id }}
        {% for collection in collections %}
          @__sweettalk_loaded_{{ collection[0].id }} =
            fresh.@__sweettalk_loaded_{{ collection[0].id }}
        {% end %}
        {% if moves %}
          @state = fresh.@state
        {% end %}
      end

      # Takes what is stored again, after a rolled-back change, and drops the events the
      # change queued; an aggregate whose row is gone keeps what it has.
      def __sweettalk_reload : Nil
        @__sweettalk_events.clear
        if fresh = self.class.__sweettalk_find?(__sweettalk_raw_id)
          __sweettalk_copy(fresh)
        end
      end

      # A command: load the aggregate with its row locked, run the body, check the
      # invariants, save, then enqueue the events' jobs and notifications, all in one
      # transaction on this aggregate alone. A refusal rolls it back and reloads what is
      # stored.
      private def __sweettalk_command(&) : Nil
        if ::SweetTalk.__sweettalk_enter(self)
          yield
          return
        end
        fiber = ::Fiber.current
        fiber.__sweettalk_command = self
        begin
          ::SweetTalk.__sweettalk_flowing do
            ::SugarORM::Repo.transaction do
              locked = {{ row }}.query.where(removed_at: nil).where(id: __sweettalk_raw_id).lock
              loaded = self.class.__sweettalk_rows(locked).first?
              __sweettalk_copy(loaded || raise ::SweetTalk::Missing.new("{{ missing.id }}#{id}."))
              yield
              __sweettalk_check
              __sweettalk_save
              __sweettalk_dispatch_events
            end
          end
        rescue error : ::SweetTalk::Refusal | ::SweetTalk::Boundary
          __sweettalk_reload
          raise error
        ensure
          fiber.__sweettalk_command = nil
        end
      end

      ::SweetTalk.__sweettalk_schema({{ @type }})
      {% for collection in collections %}
        ::SweetTalk.__sweettalk_schema({{ @type }}::{{ collection[3][6..-2].id }})
      {% end %}
    end

    def __sweettalk_raw_id : Int64
      short = self.class.name.split("::").last
      @__sweettalk_id || raise NilAssertionError.new("#{short} has no id until it is created")
    end

    # The table this aggregate's rows live in, and what is stored read again; each
    # aggregate's `__sweettalk_storage` defines both, so a call through `Aggregate` or
    # `Aggregate.class` reaches the subclass's.
    def self.__sweettalk_table : String
      raise NotImplementedError.new("#{name}.__sweettalk_table")
    end

    def __sweettalk_reload : Nil
      raise NotImplementedError.new("#{self.class.name}#__sweettalk_reload")
    end

    def __sweettalk_same?(other : ::SweetTalk::Aggregate) : Bool
      return true if same?(other)
      self.class == other.class && !@__sweettalk_id.nil? && @__sweettalk_id == other.@__sweettalk_id
    end

    def ==(other : ::SweetTalk::Aggregate) : Bool
      self.class == other.class && @__sweettalk_id == other.@__sweettalk_id
    end

    def hash(hasher)
      @__sweettalk_id.hash(hasher)
    end

    def to_s(io : IO) : Nil
      {% if @type.has_constant?("SWEETTALK_HAS_NAME") %}
        io << name
      {% else %}
        io << {{ @type.name.split("::").last }} << ' ' << @__sweettalk_id
      {% end %}
    end

    # Enqueues the jobs and notifications of the events this aggregate emitted. Each is
    # recorded again first, now that the save gave every entity among its facts an id.
    def __sweettalk_dispatch_events : Nil
      events = @__sweettalk_events.dup
      @__sweettalk_events.clear
      events.each do |event|
        event.__sweettalk_repack
        ::SweetTalk.dispatch(event)
      end
    end

    # Runs a factory's body on this new aggregate as its first change, then checks the
    # invariants, saves it and dispatches its events, in one transaction; while it runs,
    # changing another aggregate is refused as in a command. Once it is saved, the open
    # handling remembers it as the aggregate it changed.
    def __sweettalk_making(&) : Nil
      fiber = ::Fiber.current
      fiber.__sweettalk_command = self
      begin
        ::SweetTalk.__sweettalk_flowing do
          ::SugarORM::Repo.transaction do
            yield
            __sweettalk_check
            __sweettalk_save
            __sweettalk_dispatch_events
          end
        end
        ::SweetTalk.__sweettalk_created(self)
      ensure
        fiber.__sweettalk_command = nil
      end
    end

    # Marks this aggregate removed: its row stays, and `find`, `find?`, `all` and every
    # `finds` skip it. Only a command calls it.
    private def remove : Nil
      @__sweettalk_removed_at ||= Time.utc
    end

    # Runs every `never` and `always` of this aggregate, then of each of its entities.
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
  end
end
