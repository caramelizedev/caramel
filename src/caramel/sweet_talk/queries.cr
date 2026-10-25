# Repository queries, `finds` and `counts`, shared by aggregates and projections.
module SweetTalk
  # `finds` and `counts`: the queries an aggregate or a projection declares on its rows.
  module Queried
    # `finds placed_for(member : Account), where: {member: member, state: :placed}` is a
    # repository query: the aggregates (or a projection's rows) whose attributes equal the
    # expressions, by id, with their entities, skipping removed aggregates. A value, an id,
    # an aggregate, a record, a list or a range of them compares by its column; a
    # composite value by each part; `state:` takes a state or a list of states.
    # `satisfying: Dispatchable` adds a specification on this aggregate (not on a
    # projection); `order: {placed_on: :desc}` sorts by `id` or attributes stored in one
    # column, id breaking ties; `first: count` returns at most that many. Each part is
    # optional, but one is given. With a block instead, `finds newest(count : Int32) do
    # |orders| orders.order_by(:created_at, :desc).limit(count) end` narrows the live rows
    # with SugarORM's `where`, `where_null`, `order_by`, `limit` and `offset`, and the
    # results are built from what it returns. The context checks every query when it
    # closes (`__sweettalk_check_queries`), so a wrong one does not compile even if
    # nothing calls it.
    macro finds(call, where = nil, satisfying = nil, order = nil, first = nil, **unknown,
                &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "finds takes a verb and typed arguments, as in finds " +
                      "placed_for(member : Account), where: {member: member, state: :placed}" %}
      {% end %}
      {% verb = call.name %}
      {% short = @type.name.split("::").last %}
      {% unless unknown.empty? %}
        {% call.raise "finds #{verb} takes where:, satisfying:, order: and first:, or a block, " +
                      "not #{unknown.keys[0]}:" %}
      {% end %}
      {% kept = %w[create find find? all new allocate] %}
      {% kept = %w[all new allocate] if @type < ::SweetTalk::Projection %}
      {% if kept.includes?(verb.stringify) %}
        {% call.raise "finds #{verb} would replace #{short.id}.#{verb}: name it for what it " +
                      "finds" %}
      {% end %}
      {% if @type < ::SweetTalk::Projection && !satisfying.is_a?(NilLiteral) %}
        {% satisfying.raise "finds #{verb} takes satisfying: only in an aggregate: a " +
                            "specification is a rule on an aggregate, and #{short.id} is a " +
                            "projection" %}
      {% end %}
      {% if @type.has_constant?("SWEETTALK_QUERY_#{verb.upcase}") %}
        {% call.raise "#{short.id} already has a query named #{verb}: give each finds and " +
                      "counts its own name" %}
      {% end %}
      {% declarative = !where.is_a?(NilLiteral) || !satisfying.is_a?(NilLiteral) ||
                       !order.is_a?(NilLiteral) || !first.is_a?(NilLiteral) %}
      {% if block && declarative %}
        {% call.raise "finds #{verb} takes a block, or where:, satisfying:, order: and first:, " +
                      "not both" %}
      {% elsif !block && !declarative %}
        {% call.raise "finds #{verb} adds nothing to #{short.id}.all: give where:, satisfying:, " +
                      "order: or first:" %}
      {% end %}
      {% unless where.is_a?(NilLiteral) || where.is_a?(NamedTupleLiteral) %}
        {% where.raise "finds #{verb} takes where: {attribute: value}, as in where: " +
                       "{member: member, state: :placed}" %}
      {% end %}
      {% unless order.is_a?(NilLiteral) || order.is_a?(NamedTupleLiteral) %}
        {% order.raise "finds #{verb} takes order: {attribute: :asc or :desc}, as in " +
                       "order: {id: :desc}" %}
      {% end %}
      {% at = "#{call.filename.id}:#{call.line_number}:#{call.column_number}" %}
      {% if block %}
        {% rows = block.args.size == 1 ? block.args[0].stringify : nil %}
        {% body = block.body %}
        {% body = body.expressions[0] if body.is_a?(Expressions) && body.expressions.size == 1 %}
        {% if body.stringify.includes?("Rows::") %}
          {% context = @type.name.split("::")[0..-2].join("::") %}
          {% body.raise "#{context.id} names Rows, SweetTalk's storage: change an aggregate " +
                        "through its commands, and read it with find" %}
        {% end %}
        {% if body.stringify =~ /\b(SugarORM|Repo)\b/ %}
          {% body.raise "finds #{verb} reads only the rows it is given, so it names neither " +
                        "SugarORM nor its Repo" %}
        {% end %}
        {% node = body %}
        {% for step in 0..63 %}
          {% node = node.expressions[0] if node.is_a?(Expressions) && node.expressions.size == 1 %}
          {% if node.is_a?(Call) && !node.receiver.is_a?(Nop) %}
            {% unless %w[where where_null order_by limit offset].includes?(node.name.stringify) %}
              {% node.raise "finds #{verb} narrows #{rows.id} with where, where_null, order_by, " +
                            "limit and offset only, so it reads #{short.id} rows and writes " +
                            "nothing, not #{node.name}" %}
            {% end %}
            {% node = node.receiver %}
          {% end %}
        {% end %}
        {% unless rows && (node.is_a?(Var) || node.is_a?(Call)) && node.stringify == rows %}
          {% at_body = body.is_a?(Nop) ? call : body %}
          {% at_body.raise "finds #{verb} takes a block of one expression that narrows the " +
                           "rows it is given, as in do |orders| orders.order_by(:created_at, " +
                           ":desc) end" %}
        {% end %}
        # {word, verb, where: keys, states, order: keys, satisfying:, file:line:column}
        SWEETTALK_QUERY_{{ verb.upcase }} = {"finds", {{ verb.stringify }}, [] of String,
                                             [] of String, [] of String, nil, {{ at }}}

        def self.{{ verb }}({{ call.args.splat }}) : Array(self)
          {{ block.args[0] }} = __sweettalk_live
          __sweettalk_rows({{ body }})
        end
      {% else %}
        {% keys = where.is_a?(NilLiteral) ? [] of String : where.keys.map(&.stringify) %}
        {% states = [] of String %}
        {% if where.is_a?(NamedTupleLiteral) %}
          {% for key, value in where %}
            {% if key.stringify == "state" %}
              {% listed = value.is_a?(ArrayLiteral) ? value : [value] %}
              {% for state in listed %}
                {% states << state.id.stringify %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        {% sorts = [] of String %}
        {% if order.is_a?(NamedTupleLiteral) %}
          {% for key, direction in order %}
            {% unless %w[asc desc].includes?(direction.id.stringify) %}
              {% direction.raise "finds #{verb} orders #{key} by #{direction}: take :asc or " +
                                 ":desc" %}
            {% end %}
            {% sorts << key.stringify %}
          {% end %}
        {% end %}
        {% rule = satisfying.is_a?(NilLiteral) ? nil : satisfying.stringify %}
        # {word, verb, where: keys, states, order: keys, satisfying:, file:line:column}
        SWEETTALK_QUERY_{{ verb.upcase }} = {"finds", {{ verb.stringify }}, {{ keys }} of String,
                                             {{ states }} of String, {{ sorts }} of String,
                                             {{ rule }}, {{ at }}}
        __sweettalk_filter {{ call }}, {{ where }}, {{ satisfying }}

        def self.{{ verb }}({{ call.args.splat }}) : Array(self)
          query = __sweettalk_filtered_{{ verb }}({{ call.args.map(&.var).splat }})
          {% if order.is_a?(NamedTupleLiteral) %}
            \{% begin %}
              \{% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
                   .map { |constant| @type.constant(constant) } %}
              {% for key, direction in order %}
                {% if key.stringify == "id" %}
                  query = query.order_by(:id, {{ direction }})
                {% else %}
                  \{% attribute = attributes.find { |attribute|
                       attribute[0] == {{ key.stringify }}
                     } %}
                  query = query.order_by(:\{{ attribute[4].id }}, {{ direction }})
                {% end %}
              {% end %}
            \{% end %}
          {% end %}
          {% unless sorts.includes?("id") %}
            query = query.order_by(:id, :asc)
          {% end %}
          {% unless first.is_a?(NilLiteral) %}
            query = query.limit({{ first }})
          {% end %}
          __sweettalk_rows(query)
        end
      {% end %}
      # Types the query now, so a value of the wrong type does not compile even when
      # nothing calls it; typeof runs nothing.
      {% nothing = call.args.map { |arg| "Pointer(#{arg.type}).null.value".id } %}
      typeof({{ verb }}({{ nothing.splat }}))
    end

    # `counts placed_count_for(member : Account), where: {member: member, state: :placed}`
    # is how many live aggregates (or projection rows) `finds` with the same where: and
    # satisfying: would return, read in one statement; with neither, every live one.
    macro counts(call, where = nil, satisfying = nil, **unknown, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "counts takes a verb and typed arguments, as in counts " +
                      "placed_count_for(member : Account), where: {member: member, state: " +
                      ":placed}" %}
      {% end %}
      {% verb = call.name %}
      {% short = @type.name.split("::").last %}
      {% if block %}
        {% call.raise "counts #{verb} takes where: and satisfying:, not a block" %}
      {% end %}
      {% unless unknown.empty? %}
        {% call.raise "counts #{verb} takes where: and satisfying:, not #{unknown.keys[0]}:" %}
      {% end %}
      {% kept = %w[create find find? all new allocate] %}
      {% kept = %w[all new allocate] if @type < ::SweetTalk::Projection %}
      {% if kept.includes?(verb.stringify) %}
        {% call.raise "counts #{verb} would replace #{short.id}.#{verb}: name it for what it " +
                      "counts" %}
      {% end %}
      {% if @type < ::SweetTalk::Projection && !satisfying.is_a?(NilLiteral) %}
        {% satisfying.raise "counts #{verb} takes satisfying: only in an aggregate: a " +
                            "specification is a rule on an aggregate, and #{short.id} is a " +
                            "projection" %}
      {% end %}
      {% if @type.has_constant?("SWEETTALK_QUERY_#{verb.upcase}") %}
        {% call.raise "#{short.id} already has a query named #{verb}: give each finds and " +
                      "counts its own name" %}
      {% end %}
      {% unless where.is_a?(NilLiteral) || where.is_a?(NamedTupleLiteral) %}
        {% where.raise "counts #{verb} takes where: {attribute: value}, as in where: " +
                       "{member: member, state: :placed}" %}
      {% end %}
      {% keys = where.is_a?(NilLiteral) ? [] of String : where.keys.map(&.stringify) %}
      {% states = [] of String %}
      {% if where.is_a?(NamedTupleLiteral) %}
        {% for key, value in where %}
          {% if key.stringify == "state" %}
            {% listed = value.is_a?(ArrayLiteral) ? value : [value] %}
            {% for state in listed %}
              {% states << state.id.stringify %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      {% at = "#{call.filename.id}:#{call.line_number}:#{call.column_number}" %}
      {% rule = satisfying.is_a?(NilLiteral) ? nil : satisfying.stringify %}
      # {word, verb, where: keys, states, order: keys, satisfying:, file:line:column}
      SWEETTALK_QUERY_{{ verb.upcase }} = {"counts", {{ verb.stringify }},
                                           {{ keys }} of String, {{ states }} of String,
                                           [] of String, {{ rule }}, {{ at }}}
      __sweettalk_filter {{ call }}, {{ where }}, {{ satisfying }}

      def self.{{ verb }}({{ call.args.splat }}) : Int64
        __sweettalk_filtered_{{ verb }}({{ call.args.map(&.var).splat }}).count
      end

      {% nothing = call.args.map { |arg| "Pointer(#{arg.type}).null.value".id } %}
      typeof({{ verb }}({{ nothing.splat }}))
    end

    # The live rows a `finds` or `counts` filters, before any order or limit. Its keys are
    # checked when the context closes, so this body assumes they are right.
    macro __sweettalk_filter(call, where, satisfying)
      {% verb = call.name %}
      {% where = {} of Nil => Nil if where.is_a?(NilLiteral) %}
      def self.__sweettalk_filtered_{{ verb }}({{ call.args.splat }})
        \{% begin %}
          query = __sweettalk_live
          \{% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
               .map { |constant| @type.constant(constant) } %}
          {% for key, value in where %}
            {% if key.stringify == "state" %}
              {% states = value.is_a?(ArrayLiteral) ? value : [value] %}
              {% wanted = states.map(&.id.stringify) %}
              {% wanted = wanted[0] unless value.is_a?(ArrayLiteral) %}
              query = query.where(state: {{ wanted }})
            {% else %}
              \{% attribute = attributes.find { |attribute|
                   attribute[0] == {{ key.stringify }}
                 } %}
              {% if value.is_a?(NilLiteral) %}
                \{% if attribute && !attribute[9] %}
                  \{% raise "{{ call.name.id }} asks for {{ key.id }}: nil, but {{ key.id }} is " +
                           "not optional: nil is a value of an optional attribute, as in " +
                           "has {{ key.id }} : #{attribute[3].id}?\n  --> {{ call.filename.id }}:" +
                           "{{ call.line_number }}:{{ call.column_number }}" %}
                \{% end %}
              {% end %}
              \{% if attribute[2] == "composite" %}
                composite_{{ key.id }} = ({{ value }})
                \{% parts = attribute[7].map do |part|
                     "#{part[1].id}: ::SweetTalk.column(composite_{{ key.id }}.#{part[0].id})"
                   end %}
                \{% if attribute[9] %}
                  if composite_{{ key.id }}.nil?
                    query = query.where(\{{ attribute[7][0][1].id }}: nil)
                  else
                    query = query.where(\{{ parts.join(", ").id }})
                  end
                \{% else %}
                  query = query.where(\{{ parts.join(", ").id }})
                \{% end %}
              \{% else %}
                query = query.where(\{{ attribute[4].id }}: ::SweetTalk.column({{ value }}))
              \{% end %}
            {% end %}
          {% end %}
          {% unless satisfying.is_a?(NilLiteral) %}
            query = query.where_condition({{ satisfying }}.__sweettalk_condition)
          {% end %}
          query
        \{% end %}
      end
    end
  end
end
