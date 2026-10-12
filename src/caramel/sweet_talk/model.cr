# The parent of every stored kind, with `has` and `the`, and the lifecycle words.
module SweetTalk
  # `moves`, the lifecycle of an aggregate or a process.
  module Lifecycle
    # `moves open >> placed >> shipped, placed >> cancelled` is the lifecycle, stored in a
    # `state` column. The first state is the initial one; `cancelled?` asks, and
    # `cancelled!`, private so only a command or a step moves it, refuses unless the
    # current state comes just before it in a chain.
    macro moves(*chains)
      {% states = [] of Nil %}
      {% before = {} of Nil => Nil %}
      {% for chain in chains %}
        {% steps = [] of Nil %}
        {% node = chain %}
        {% for step in 0..64 %}
          {% node = node.expressions[0] if node.is_a?(Expressions) && node.expressions.size == 1 %}
          {% if node.is_a?(Call) && node.name == ">>" && node.args.size == 1 %}
            {% steps.unshift(node.args[0]) %}
            {% node = node.receiver %}
          {% end %}
        {% end %}
        {% steps.unshift(node) %}
        {% for state, index in steps %}
          {% bare = state.is_a?(Call) && state.receiver.is_a?(Nop) && state.args.empty? &&
                    state.named_args.is_a?(Nop) && state.name != ">>" %}
          {% unless bare %}
            {% state.raise "moves takes bare state names joined by >>, " +
                           "as in moves open >> placed" %}
          {% end %}
          {% name = state.name.stringify %}
          {% states << name unless states.includes?(name) %}
          {% if index > 0 %}
            {% previous = steps[index - 1].name.stringify %}
            {% before[name] = [] of Nil unless before[name] %}
            {% before[name] << previous unless before[name].includes?(previous) %}
          {% end %}
        {% end %}
      {% end %}
      {% owner = @type.name.split("::").last.id %}
      SWEETTALK_MOVES = [{{ states.splat }}]

      enum State
        {% for state in states %}
          {{ state.camelcase.id }}
        {% end %}
      end

      getter state : State = State::{{ states[0].camelcase.id }}

      {% for state in states %}
        def {{ state.id }}? : Bool
          @state == State::{{ state.camelcase.id }}
        end
      {% end %}

      {% for state, predecessors in before %}
        {% allowed = predecessors.map do |predecessor|
             "@state == State::#{predecessor.camelcase.id}"
           end %}
        private def {{ state.id }}! : Nil
          unless {{ allowed.join(" || ").id }}
            raise ::SweetTalk::Refusal.new(
              "{{ owner }} cannot become {{ state.id }} while #{@state.to_s.downcase}")
          end
          @state = State::{{ state.camelcase.id }}
        end
      {% end %}
    end
  end

  # The parent of aggregates, entities and projections.
  abstract class Model
    # `has stock : Tins` is an attribute, and `has held : Tins = Tins.zero` one with a
    # default. What it is stored as depends on its type: a column, a value's raw column,
    # one column per part of a composite value, a reference to another aggregate or to an
    # application's schema, or a child table of entities. A value's bounds and length are
    # also `check` lines on its column, or on each part's column. `SWEETTALK_HAS_<NAME>`
    # records {name, line, kind, declared type, column, schema lines, raw column type,
    # parts, default} for the storage macros; a composite's parts are {part, column, raw
    # type, part type, part kind, check}. An index name over PostgreSQL's 63 bytes is
    # refused, and under caramel/tenancy so are the tenant's column and a central
    # context's reference to rows that belong to one tenant (ADR 0033).
    macro has(decl)
      {% unless decl.is_a?(TypeDeclaration) %}
        {% decl.raise "has takes a name and a type, as in has stock : Tins" %}
      {% end %}
      {% name = decl.var.id %}
      {% type = decl.type %}
      {% default = decl.value.is_a?(Nop) ? nil : decl.value.stringify %}
      {% value = decl.value %}
      {% literal = value.is_a?(BoolLiteral) || value.is_a?(NumberLiteral) ||
                   value.is_a?(StringLiteral) || value.is_a?(NilLiteral) %}
      {% kind = nil %}
      {% column = name.stringify %}
      {% lines = nil %}
      {% raw = nil %}
      {% parts = nil %}
      {% nilable = false %}
      {% if type.is_a?(Generic) && type.name.stringify == "Array" %}
        {% kind = "entities" %}
        {% column = nil %}
        {% child = "#{@type.constant("SWEETTALK_ROW").id}::#{type.type_vars[0]}" %}
        {% foreign = "#{@type.constant("SWEETTALK_STORED").id}_id" %}
        {% lines = "has_many #{name} : #{child.id}, foreign_key: :#{foreign.id}" %}
      {% elsif type.is_a?(Generic) && type.name.stringify == "Hash" %}
        {% decl.raise "has #{decl} cannot be stored: use an entity, " +
                      "as in has packings : Array(Packing)" %}
      {% else %}
        {% resolved = type.resolve? %}
        {% unless resolved %}
          {% decl.raise "has #{decl} names a type that is not declared yet: declare a value " +
                        "or an aggregate before the aggregate that stores it" %}
        {% end %}
        {% nilable = resolved.nilable? %}
        {% members = [resolved] %}
        {% members = resolved.union_types.reject { |member| member == Nil } if resolved.union? %}
        {% single = members.size == 1 && !resolved.union? %}
        {% columns = %w[String Int32 Int64 Bool Float64 Time] %}
        {% if single && members[0] < ::SweetTalk::Value %}
          {% kind = "value" %}
          {% raw = members[0].constant("SWEETTALK_WRAPS") %}
          {% lines = "field #{name} : #{raw.id}" %}
        {% elsif single && members[0] < ::SweetTalk::Composite %}
          {% kind = "composite" %}
          {% column = nil %}
          {% parts = [] of Nil %}
          {% composite = members[0] %}
          {% declared = composite.constants.select(&.starts_with?("SWEETTALK_PART_"))
               .map { |constant| composite.constant(constant) }.sort_by { |part| part[1] } %}
          {% for part in declared %}
            {% parts << {part[0], "#{name}_#{part[0].id}", part[3], part[2], part[4], part[5]} %}
          {% end %}
          {% lines = parts.map { |part| "field #{part[1].id} : #{part[2].id}" }.join("\n") %}
        {% elsif single && members[0] < ::SweetTalk::Aggregate %}
          {% kind = "reference" %}
          {% raw = "Int64" %}
          {% column = "#{name}_id" %}
          {% lines = "belongs_to #{name} : #{members[0].constant("SWEETTALK_ROW").id}" %}
        {% elsif single && members[0] < ::SugarORM::Schema %}
          {% kind = "record" %}
          {% raw = "Int64" %}
          {% column = "#{name}_id" %}
          {% lines = "belongs_to #{name} : ::#{members[0]}" %}
        {% elsif members.size == 1 && columns.includes?(members[0].stringify) %}
          {% kind = "column" %}
          {% raw = type.stringify %}
          {% lines = "field #{name} : #{type}" + (literal ? " = #{default.id}" : "") %}
        {% else %}
          {% decl.raise "has #{decl} cannot be stored: use String, Int32, Int64, Bool, Float64, " +
                        "Time, a value, an aggregate, an application's schema or an Array of " +
                        "this aggregate's entity" %}
        {% end %}
      {% end %}
      {% checks = [] of Nil %}
      {% if kind == "value" && members[0].constant("SWEETTALK_CHECK") %}
        {% checks << {column, members[0].constant("SWEETTALK_CHECK"),
                      members[0].name.split("::").last} %}
      {% elsif kind == "composite" %}
        {% for part in parts %}
          {% checks << {part[1], part[5], part[3].split("::").last} if part[5] %}
        {% end %}
      {% end %}
      {% for entry in checks %}
        {% check = entry[1] %}
        {% if check[0] == "range" %}
          {% suffix = entry[0] %}
          {% line = "check #{entry[0].id}: #{check[1].id}" %}
        {% else %}
          {% suffix = "#{entry[0].id}_#{check[1].id}" %}
          {% sql = "char_length(\"#{entry[0].id}\") #{check[2].id}" %}
          {% line = "check :#{suffix.id}, #{sql.stringify.id}" %}
        {% end %}
        {% constraint = "check_#{@type.constant("SWEETTALK_TABLE").id}_#{suffix.id}" %}
        {% if constraint.size > 63 %}
          {% decl.raise "has #{decl} would check #{entry[0].id} as #{constraint.id}, longer " +
                        "than PostgreSQL's 63 bytes: shorten the attribute, or give " +
                        "#{entry[2].id} database_check: false" %}
        {% end %}
        {% lines = "#{lines.id}\n#{line.id}" %}
      {% end %}
      {% keyed = @type < ::SweetTalk::Projection || @type < ::SweetTalk::Process %}
      {% key = @type.has_constant?("SWEETTALK_KEY") && @type.constant("SWEETTALK_KEY") %}
      {% if keyed && key != name.stringify && !((kind == "column" && literal) || nilable) %}
        {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
        {% decl.raise "has #{decl} in #{owner.id} needs a literal default, as in has tins : " +
                      "Int32 = 0: its row starts from its key alone" %}
      {% end %}
      {% table = @type.constant("SWEETTALK_TABLE") %}
      {% stored = parts ? parts.map(&.[1]) : [column] %}
      {% if keyed && key == name.stringify %}
        {% index = "index_#{table.id}_on_#{stored.join("_and_").id}" %}
        {% if index.size > 63 %}
          {% decl.raise "key #{decl} would index its key as #{index.id}, longer than " +
                        "PostgreSQL's 63 bytes: shorten the key" %}
        {% end %}
      {% elsif kind == "reference" || kind == "record" %}
        {% index = "index_#{table.id}_on_#{column.id}" %}
        {% if index.size > 63 %}
          {% decl.raise "has #{decl} would index #{column.id} as #{index.id}, longer than " +
                        "PostgreSQL's 63 bytes: shorten the attribute" %}
        {% end %}
      {% end %}
      {% contexts = ::SweetTalk::BoundedContext.includers %}
      {% home = contexts.find { |context| @type.name.starts_with?("#{context.name}::") } %}
      {% tenant = home && home.constant("SWEETTALK_TENANT") %}
      {% if tenant && stored.includes?("#{tenant[1].id}_id") %}
        {% decl.raise "has #{decl} would store #{tenant[1].id}_id, the column that names each " +
                      "row's tenant #{tenant[0].id}: name the attribute for its role, as in " +
                      "has owner : #{type}" %}
      {% end %}
      {% if home && home.constant("SWEETTALK_CENTRAL") %}
        {% shared = true %}
        {% if kind == "reference" %}
          {% target = members[0].name %}
          {% there = contexts.find { |context| target.starts_with?("#{context.name}::") } %}
          {% shared = there && there.constant("SWEETTALK_CENTRAL") %}
        {% elsif kind == "record" %}
          {% shared = !members[0].has_constant?(:SUGAR_TENANT) %}
        {% end %}
        {% unless shared %}
          {% decl.raise "has #{decl} would point from central context " +
                        "#{home.name.split("::").last.id} at rows that belong to one tenant: " +
                        "keep the reference in a tenanted context" %}
        {% end %}
      {% end %}
      {% attribute = {name.stringify, decl.line_number, kind, type.stringify, column, lines, raw,
                      parts, default} %}
      SWEETTALK_HAS_{{ name.upcase }} = {{ attribute }}

      {% if kind == "reference" %}
        @{{ name }}_id : Int64

        # The referenced aggregate's id; load it with `{{ type }}.find` when it is needed.
        def {{ name }} : {{ type }}::Id
          {{ type }}::Id.new(@{{ name }}_id)
        end
      {% elsif kind == "record" %}
        @{{ name }}_id : Int64

        # The referenced record's id; `load` reads the record.
        def {{ name }} : ::SweetTalk::RecordId({{ type }})
          ::SweetTalk::RecordId({{ type }}).new(@{{ name }}_id)
        end
      {% elsif @type < ::SweetTalk::Projection %}
        property {{ decl }}
      {% else %}
        getter {{ decl }}
      {% end %}
    end

    # `the total : Cents = expression` is a derived value, never stored.
    macro the(decl)
      {% if decl.is_a?(TypeDeclaration) && !decl.value.is_a?(Nop) %}
        {% derived = {decl.var.stringify, decl.line_number} %}
        SWEETTALK_THE_{{ decl.var.id.upcase }} = {{ derived }}

        def {{ decl.var }} : {{ decl.type }}
          ::SweetTalk.coerce({{ decl.type }}, ({{ decl.value }}))
        end
      {% else %}
        {% name = decl.is_a?(TypeDeclaration) ? decl.var : decl %}
        {% name = decl.target if decl.is_a?(Assign) %}
        {% decl.raise "the #{name} needs a type, as in the #{name} : Cents = …" %}
      {% end %}
    end

    macro whenever(event, border = nil, each = nil, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% event.raise "whenever belongs in a context, a border or a projection, or in a process, " +
                     "not in #{owner.id}" %}
    end

    macro key(decl)
      {% decl.raise "key belongs in a projection or a process: " +
                    "it names the attribute that picks a row" %}
    end

    macro service(call, returns = nil, means = nil, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% call.raise "service belongs in a context, not in #{owner.id}" %}
    end

    macro compensate(event, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% event.raise "compensate belongs beside a whenever in a context, a border or a process, " +
                     "not in #{owner.id}" %}
    end

    macro deadline(name, after = nil, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% name.raise "deadline belongs in a process, not in #{owner.id}" %}
    end

    def refuse(message : String) : NoReturn
      raise ::SweetTalk::Refusal.new(message)
    end
  end
end
