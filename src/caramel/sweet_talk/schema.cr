# The SugarORM schema and changeset of each stored kind.
module SweetTalk
  # The SugarORM schema and changeset for one aggregate, entity, projection or process,
  # and for a projection or a process `Start`, the upsert that inserts a row by its key.
  # In a tenanted context the schema declares `tenant`, so SugarORM scopes every read,
  # lock, key and upsert by the bound tenant (ADR 0033).
  macro __sweettalk_schema(owner)
    {% type = owner.resolve %}
    {% row = type.constant("SWEETTALK_ROW").id %}
    {% attributes = type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
         .map { |constant| type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
    {% parent = type.has_constant?("SWEETTALK_PARENT") ? type.constant("SWEETTALK_PARENT") : nil %}
    {% moves = type.has_constant?("SWEETTALK_MOVES") ? type.constant("SWEETTALK_MOVES") : nil %}
    {% named = type.has_constant?("SWEETTALK_KEY") ? type.constant("SWEETTALK_KEY") : nil %}
    {% key = named ? attributes.find { |attribute| attribute[0] == named } : nil %}
    {% indexed = key && (key[2] == "composite" ? key[7].map { |part| part[1] } : [key[4]]) %}
    {% constraints = type.constants.select(&.starts_with?("SWEETTALK_CONSTRAINT_"))
         .map { |constant| type.constant(constant) }.sort_by { |constraint| constraint[1] } %}
    {% aggregate = type < ::SweetTalk::Aggregate %}
    {% home = ::SweetTalk::BoundedContext.includers
         .find { |context| type.name.starts_with?("#{context.name}::") } %}
    {% tenant = home && home.constant("SWEETTALK_TENANT") %}
    struct {{ row }} < ::SugarORM::Schema
      schema {{ type.constant("SWEETTALK_TABLE") }} do
        field id : Int64, primary: true
        {% if tenant %}
          tenant {{ tenant[1].id }} : ::{{ tenant[0].id }}
        {% end %}
        {% if parent %}
          belongs_to {{ parent[0].id }} : {{ parent[1].id }}
        {% end %}
        {% for attribute in attributes %}
          {{ attribute[5].id }}
        {% end %}
        {% if moves %}
          {% check = type.constant("SWEETTALK_STATE_CHECK") %}
          field state : String = {{ moves[0] }}
          check :{{ check[0].id }}, {{ check[1] }}
        {% end %}
        {% if aggregate %}
          field removed_at : Time?
        {% end %}
        {% if key %}
          index {{ indexed.map { |column| ":#{column.id}" }.join(", ").id }}, unique: true
        {% end %}
        {% for constraint in constraints %}
          {{ constraint[2].id }}
        {% end %}
        timestamps
      end
    end

    class {{ row }}::Changeset < ::SugarORM::Changeset({{ row }})
      {% if parent %}
        param {{ parent[0].id }}_id : Int64
      {% end %}
      {% for attribute in attributes %}
        {% if attribute[2] == "composite" %}
          {% for part in attribute[7] %}
            param {{ part[1].id }} : {{ part[2].id }}
          {% end %}
        {% elsif attribute[2] != "entities" %}
          param {{ attribute[4].id }} : {{ attribute[6].id }}
        {% end %}
      {% end %}
      {% if moves %}
        param state : String
      {% end %}
      {% if aggregate %}
        param removed_at : Time?
      {% end %}
    end

    {% if key %}
      class {{ row }}::Start < ::SugarORM::Changeset({{ row }})
        {% if key[2] == "composite" %}
          {% for part in key[7] %}
            param {{ part[1].id }} : {{ part[2].id }}
          {% end %}
        {% else %}
          param {{ key[4].id }} : {{ key[6].id }}
        {% end %}
        upsert on: [{{ indexed.map { |column| ":#{column.id}" }.join(", ").id }}]
      end
    {% end %}
  end

  # The schema of *owner*, an aggregate's entity, then of each entity it holds, at every
  # depth.
  macro __sweettalk_schemas(owner)
    ::SweetTalk.__sweettalk_schema({{ owner }})
    {% type = owner.resolve %}
    {% for constant in type.constants.select(&.starts_with?("SWEETTALK_HAS_")) %}
      {% attribute = type.constant(constant) %}
      {% if attribute[2] == "entities" %}
        ::SweetTalk.__sweettalk_schemas({{ owner }}::{{ attribute[3][6..-2].id }})
      {% end %}
    {% end %}
  end

  # A context's event log (ADR 0048). With `event_log: true` it is `Rows::Events`, the
  # `<context>_events` table, append-only and tenanted as the context's rows are;
  # `__sweettalk_log`, which `SweetTalk.dispatch` calls with every event and which writes
  # one row for an event of this context or of a kernel it shares; `logged`, the typed
  # reader; and `__sweettalk_prune`, which the schedule `event_log: 90.days` registers
  # loops, once an hour in Cold Brew's scheduler (ADR 0051). Without the keyword
  # `__sweettalk_log` does nothing. A declaration whose table the log would take is
  # refused.
  macro __sweettalk_event_log(owner)
    {% type = owner.resolve %}
    {% short = type.name.split("::").last %}
    {% if type.constant("SWEETTALK_EVENT_LOG") %}
      {% stored = type.constant("SWEETTALK_STORED") %}
      {% table = "#{stored.id}_events" %}
      {% tenant = type.constant("SWEETTALK_TENANT") %}
      {% homes = [stored] + type.constant("SWEETTALK_SHARES").map(&.underscore) %}
      {% for other in ::SweetTalk::Model.all_subclasses %}
        {% taken = other.has_constant?("SWEETTALK_TABLE") && other.constant("SWEETTALK_TABLE") %}
        {% if taken == table %}
          {% raise "context #{short.id} keeps its event log in #{table.id}, the table " +
                   "#{other.constant("SWEETTALK_KIND").id} #{other.name.split("::").last.id} " +
                   "stores its rows in: rename one of them" %}
        {% end %}
      {% end %}
      # The stored names of the context and the kernels whose events this log keeps
      SWEETTALK_LOGS = [{{ homes.splat }}] of String

      struct Rows::Events < ::SugarORM::Schema
        schema {{ table }} do
          field id : Int64, primary: true
          {% if tenant %}
            tenant {{ tenant[1].id }} : ::{{ tenant[0].id }}
          {% end %}
          field event_id : String
          field aggregate : String
          field name : String
          field subject_id : Int64?
          field occurred_at : Time
          field actor : String?
          field cause_id : String?
          field flow_id : String
          field fields : JSON::Any, codec: ::SugarORM::JSONB(JSON::Any)
          field created_at : Time
          index :event_id, unique: true
          index :flow_id
          index :cause_id
          index :aggregate, :subject_id, :id
          index :occurred_at
        end
      end

      # Writes the event's row when it is one this log keeps, on the current connection,
      # so it commits with the command or the service that emitted it.
      def self.__sweettalk_log(event : ::SweetTalk::Event) : Nil
        return unless SWEETTALK_LOGS.includes?(event.__sweettalk_home)
        aggregate, name = event.__sweettalk_logged_as(SWEETTALK_STORED)
        Rows::Events.create!(event_id: event.event_id, aggregate: aggregate, name: name,
          subject_id: event.__sweettalk_subject_id, occurred_at: event.occurred_at,
          actor: event.actor, cause_id: event.cause_id, flow_id: event.flow_id,
          fields: JSON.parse(event.__sweettalk_fields), created_at: Time.utc)
      end

      # `{{ short.id }}.logged(Order::Placed, subject: id, since: t, limit: 100)`: the
      # logged events of one class, oldest first and newest last, the first *limit* of
      # them; `subject:` keeps one aggregate's, `since:` those that occurred at or after
      # a time. A class this log does not keep raises ArgumentError.
      def self.logged(kind : E.class, *, subject : ::SweetTalk::Identity | Int64 | Nil = nil,
                      since : Time? = nil, limit : Int32 = 100) : Array(E) forall E
        unless SWEETTALK_LOGS.includes?(E.__sweettalk_home)
          raise ArgumentError.new("#{E.name} is not logged in {{ table.id }}: " +
                                  "{{ short.id }} logs the events of #{SWEETTALK_LOGS.join(", ")}")
        end
        aggregate, name = E.__sweettalk_logged_as(SWEETTALK_STORED)
        __sweettalk_logged_rows(aggregate, name, subject, since, limit).map do |row|
          E.__sweettalk_load(row.subject_id, row.fields.to_json, __sweettalk_logged_meta(row))
        end
      end

      # `{{ short.id }}.logged(subject: id)`: the logged events of every class, as
      # `SweetTalk::Event`, under the same keywords.
      def self.logged(*, subject : ::SweetTalk::Identity | Int64 | Nil = nil,
                      since : Time? = nil, limit : Int32 = 100) : Array(::SweetTalk::Event)
        __sweettalk_logged_rows(nil, nil, subject, since, limit).map do |row|
          __sweettalk_logged_event(row)
        end
      end

      protected def self.__sweettalk_logged_rows(aggregate : String?, name : String?,
                                                 subject, since : Time?,
                                                 limit : Int32) : Array(Rows::Events)
        query = Rows::Events.query
        query = query.where(aggregate: aggregate) if aggregate
        query = query.where(name: name) if name
        id = subject.is_a?(::SweetTalk::Identity) ? subject.raw : subject
        query = query.where(subject_id: id) if id
        query = query.where("occurred_at >= ?", since) if since
        query.order_by(:id, :asc).limit(limit).to_a
      end

      # A row's metadata as the event's JSON, for `__sweettalk_load`.
      def self.__sweettalk_logged_meta(row : Rows::Events) : String
        {id: row.event_id, at: row.occurred_at.to_rfc3339(fraction_digits: 6), by: row.actor,
         cause: row.cause_id, flow: row.flow_id}.to_json
      end

      # The typed event a row holds, by the aggregate and name it stores; a row no event
      # of this log stores any more is an error naming it.
      def self.__sweettalk_logged_event(row : Rows::Events) : ::SweetTalk::Event
        case {row.aggregate, row.name}
        {% for event in ::SweetTalk::Event.all_subclasses %}
          {% if event.has_constant?("SWEETTALK_HOME") &&
                  homes.includes?(event.constant("SWEETTALK_HOME")) %}
            {% home = event.constant("SWEETTALK_HOME") %}
            {% aggregate = event.constant("SWEETTALK_AGGREGATE") %}
            {% own = home == stored %}
            {% column = aggregate ? (own ? aggregate : "#{home.id}_#{aggregate.id}") : home %}
            when { {{ column }}, {{ event.constant("SWEETTALK_NAME") }} }
              {{ event }}.__sweettalk_load(row.subject_id, row.fields.to_json,
                __sweettalk_logged_meta(row))
          {% end %}
        {% end %}
        else
          raise ArgumentError.new("{{ table.id }} row #{row.id} holds #{row.aggregate}." +
                                  "#{row.name}, which no event of {{ short.id }} stores: " +
                                  "add renamed_from: to the event that replaced it")
        end
      end

      # Deletes up to *chunk* rows that occurred before *before*, oldest first, across
      # every tenant; the count deleted.
      def self.__sweettalk_prune(before : Time, chunk : Int32) : Int64
        {% if tenant %}
          ::Caramel::Tenancy.without do
            Rows::Events.query.where("occurred_at < ?", before).order_by(:id, :asc).limit(chunk)
              .delete_all
          end
        {% else %}
          Rows::Events.query.where("occurred_at < ?", before).order_by(:id, :asc).limit(chunk)
            .delete_all
        {% end %}
      end

      {% days = type.constant("SWEETTALK_EVENT_DAYS") %}
      {% if days %}
        # Deletes, once an hour in Cold Brew's scheduler, the events the log no longer keeps.
        ::Caramel::ColdBrew.every(1.hour, {{ "sweettalk:prune:#{table.id}" }}) do
          ::SweetTalk.__sweettalk_pruning({{ days }}.days.ago, 1000) do |before, chunk|
            ::{{ type }}.__sweettalk_prune(before, chunk)
          end
          nil
        end
      {% end %}
    {% else %}
      def self.__sweettalk_log(event : ::SweetTalk::Event) : Nil
      end
    {% end %}
  end
end
