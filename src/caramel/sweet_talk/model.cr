# The parent of every stored kind, with `has` and `the`, and the lifecycle words.
module SweetTalk
  # `__sweettalk_hashed(CONSTANT, {"state_@digest", "…"}, "a,b")` defines CONSTANT as the
  # tuple with each `@digest` in its strings replaced by the FNV-1a 32-bit hash of the text,
  # as eight hex digits. A check's name carries it, so a changed list or a changed set of
  # parts is a new constraint, which the differ replaces. Every hashed check name comes
  # from here. With a *constraint* name, as in `"check_shop_orders_state_@digest"`, and a
  # *too_long* message that holds `@name`, it refuses a name over PostgreSQL's 63 bytes.
  macro __sweettalk_hashed(constant, tuple, text, constraint = nil, too_long = nil)
    {% hash = 2166136261 %}
    {% for char in text.chars %}
      {% hash = ((hash ^ char.ord) * 16777619) % 4294967296 %}
    {% end %}
    {% digits = "0123456789abcdef".chars %}
    {% hex = [28, 24, 20, 16, 12, 8, 4, 0].map { |shift| digits[(hash >> shift) & 15] } %}
    {% hex = hex.join("") %}
    {% items = tuple.map { |item| item.is_a?(StringLiteral) ? item.gsub(/@digest/, hex) : item } %}
    {% unless constraint.is_a?(NilLiteral) %}
      {% named = constraint.gsub(/@digest/, hex) %}
      {% raise too_long.gsub(/@name/, named) if named.size > 63 %}
    {% end %}
    {{ constant.id }} = { {{ items.splat }} }
  end

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
      # The check that keeps `state` to these states, named by the hash of the states.
      {% listed = states.map { |state| "'#{state.id}'" }.join(", ") %}
      {% constraint = "check_#{@type.constant("SWEETTALK_TABLE").id}_state_@digest" %}
      {% at = "#{chains[0].filename.id}:#{chains[0].line_number}:#{chains[0].column_number}" %}
      {% too_long = "moves would check #{owner}'s states as @name, longer than PostgreSQL's 63 " +
                    "bytes: shorten the context or the #{owner} name\n  --> #{at.id}" %}
      SWEETTALK_MOVES = [{{ states.splat }}]
      # {constraint suffix, expression} of the check that keeps `state` to these states
      ::SweetTalk.__sweettalk_hashed(SWEETTALK_STATE_CHECK,
        {"state_@digest", {{ "\"state\" IN (#{listed.id})" }}}, {{ states.sort.join(",") }},
        {{ constraint }}, {{ too_long }})

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

      # The state as `moves` spells it, the text its `state` column stores.
      def __sweettalk_state : String
        case @state
        {% for state in states %}
        in State::{{ state.camelcase.id }} then {{ state }}
        {% end %}
        end
      end

      {% for state, predecessors in before %}
        {% allowed = predecessors.map do |predecessor|
             "@state == State::#{predecessor.camelcase.id}"
           end %}
        private def {{ state.id }}! : Nil
          unless {{ allowed.join(" || ").id }}
            raise ::SweetTalk::Refusal.new(
              "{{ owner }} cannot become {{ state.id }} while #{__sweettalk_state}")
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
    # also `check` lines on its column, or on each part's column. A type followed by `?`,
    # as in `has owner : Setup::Owner?`, `has reason : Reason?` and `has leg : Leg?`, is
    # optional: its column, or every column of a composite value, is nullable, its getter
    # returns nil when it is not set, and it starts as nil unless given a default. A
    # composite value that is optional also gets a check that every part is set or none is.
    # `SWEETTALK_HAS_<NAME>` records {name, line, kind, declared type, column, schema
    # lines, raw column type, parts, default, optional, base type} for the storage macros,
    # the base type being the declared one without its `?`; a composite's parts are {part,
    # column, raw type, part type, part kind, check}, the raw type ending in `?` when the
    # composite is optional. An index name over PostgreSQL's 63 bytes is refused, and under
    # caramel/tenancy so are the tenant's column and a central context's reference to rows
    # that belong to one tenant (ADR 0033).
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
      {% base = type.stringify %}
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
        {% single = members.size == 1 && (!resolved.union? || nilable) %}
        {% base = "::#{members[0].name}" if single && nilable %}
        {% optional = nilable ? "?" : "" %}
        {% columns = %w[String Int32 Int64 Bool Float64 Time] %}
        {% if single && members[0] < ::SweetTalk::Value %}
          {% kind = "value" %}
          {% raw = "#{members[0].constant("SWEETTALK_WRAPS").id}#{optional.id}" %}
          {% lines = "field #{name} : #{raw.id}" %}
        {% elsif single && members[0] < ::SweetTalk::Composite %}
          {% kind = "composite" %}
          {% column = nil %}
          {% parts = [] of Nil %}
          {% composite = members[0] %}
          {% declared = composite.constants.select(&.starts_with?("SWEETTALK_PART_"))
               .map { |constant| composite.constant(constant) }.sort_by { |part| part[1] } %}
          {% for part in declared %}
            {% parts << {part[0], "#{name}_#{part[0].id}", "#{part[3].id}#{optional.id}", part[2],
                         part[4], part[5]} %}
          {% end %}
          {% lines = parts.map { |part| "field #{part[1].id} : #{part[2].id}" }.join("\n") %}
        {% elsif single && members[0] < ::SweetTalk::Aggregate %}
          {% kind = "reference" %}
          {% raw = "Int64#{optional.id}" %}
          {% column = "#{name}_id" %}
          {% row = members[0].constant("SWEETTALK_ROW") %}
          {% lines = "belongs_to #{name} : #{row.id}#{optional.id}" %}
        {% elsif single && members[0] < ::SugarORM::Schema %}
          {% kind = "record" %}
          {% raw = "Int64#{optional.id}" %}
          {% column = "#{name}_id" %}
          {% lines = "belongs_to #{name} : ::#{members[0]}#{optional.id}" %}
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
          {% subject = "\"#{entry[0].id}\"" %}
          {% subject = "char_length(#{subject.id})" if check[0] == "length" %}
          {% sql = "#{subject.id} #{check[2].id}" %}
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
      {% if kind == "composite" && nilable && parts.size > 1 %}
        {% digest = composite.constant("SWEETTALK_OPTIONAL_CHECK")[0] %}
        {% suffix = "#{name}_#{digest.id}" %}
        {% listed = parts.map { |part| "\"#{part[1].id}\"" }.join(", ") %}
        {% sql = "num_nonnulls(#{listed.id}) IN (0, #{parts.size})" %}
        {% constraint = "check_#{@type.constant("SWEETTALK_TABLE").id}_#{suffix.id}" %}
        {% if constraint.size > 63 %}
          {% decl.raise "has #{decl} would check its parts as #{constraint.id}, longer than " +
                        "PostgreSQL's 63 bytes: shorten the attribute" %}
        {% end %}
        {% lines = "#{lines.id}\ncheck :#{suffix.id}, #{sql.stringify.id}" %}
      {% end %}
      {% keyed = @type < ::SweetTalk::Projection || @type < ::SweetTalk::Process %}
      {% key = @type.has_constant?("SWEETTALK_KEY") && @type.constant("SWEETTALK_KEY") %}
      {% if keyed && key == name.stringify && nilable %}
        {% decl.raise "key #{decl.var} cannot be optional: every row has its key" %}
      {% end %}
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
                      parts, nilable && !default ? "nil" : default, nilable, base} %}
      SWEETTALK_HAS_{{ name.upcase }} = {{ attribute }}

      {% if kind == "reference" || kind == "record" %}
        {% target = kind == "record" ? "::SweetTalk::RecordId(#{base.id})" : "#{base.id}::Id" %}
        {% accepted = "#{base.id} | #{target.id}" %}
        {% accepted = "#{accepted.id} | Nil" if nilable %}
        @{{ name }}_id : {{ raw.id }}

        # The referenced id, or nil when it is optional and not set; load what it names when
        # it is needed.
        {% if nilable %}
          def {{ name }} : {{ target.id }}?
            @{{ name }}_id.try { |raw| {{ target.id }}.new(raw) }
          end
        {% else %}
          def {{ name }} : {{ target.id }}
            {{ target.id }}.new(@{{ name }}_id)
          end
        {% end %}

        # `self.{{ name }} = other` in a command points this attribute at another row, given as
        # the aggregate, the record or its id, or as nil when the attribute is optional. It is
        # private, so only the command changes it, except in a projection, whose `whenever`
        # handler assigns the row it holds (`row.{{ name }} = other`). A key has no writer:
        # the row is found by it, and the save never writes it.
        {% unless keyed && key == name.stringify %}
          {% visibility = @type < ::SweetTalk::Projection ? "" : "private" %}
          {{ visibility.id }} def {{ name }}=(other : {{ accepted.id }})
            @{{ name }}_id = ::SweetTalk.raw_id(other)
          end
        {% end %}
      {% elsif @type < ::SweetTalk::Projection && !(keyed && key == name.stringify) %}
        property {{ decl }}
      {% else %}
        getter {{ decl }}
      {% end %}
    end

    # `the total : Cents = expression` is a derived value, never stored.
    macro the(decl)
      {% if decl.is_a?(TypeDeclaration) && !decl.value.is_a?(Nop) %}
        {% derived = {decl.var.stringify, decl.line_number, decl.type.stringify} %}
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

    # Refuses `@owner = other`, `@owner ||= other` or `@owner, @x = …` in the body of
    # *verb*, a command, factory, step, compensation or deadline, when `owner` is a
    # reference: the reference is stored in `@owner_id`, so that line would declare a stray
    # instance variable and change nothing. `self.owner = other` is the way. *text* is the
    # body's source; its string literals are dropped before the scan.
    macro __sweettalk_no_stray_writes(verb, text)
      {% scanned = text.gsub(/"(?:[^"\\]|\\.)*"/, "")
           .gsub(/(?<![@\w])(@\w+)\s*(?:\|\||&&|<<|>>|[-+*\/%&|^])?=(?![=~])/, "\\1 = ")
           .gsub(/(?<![@\w])(@\w+)\s*,(?=[^\n=]*=(?![=~]))/, "\\1 = ,") %}
      {% for constant in @type.constants.select(&.starts_with?("SWEETTALK_HAS_")) %}
        {% attribute = @type.constant(constant) %}
        {% if %w[reference record].includes?(attribute[2]) &&
                scanned.includes?("@#{attribute[0].id} = ") %}
          {% raise "#{verb.id} assigns @#{attribute[0].id}, but #{attribute[0].id} is a " +
                   "reference stored as #{attribute[4].id}: use self.#{attribute[0].id} = ..., " +
                   "which takes the aggregate, the record or its id" %}
        {% end %}
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

    macro specification(name, on = nil, where = nil, means = nil, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% name.raise "specification belongs in a context, after its aggregate, not in #{owner.id}" %}
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
