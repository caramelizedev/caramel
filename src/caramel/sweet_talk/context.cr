# Bounded contexts and the words their bodies may use.
module SweetTalk
  # Refuses `renamed_from:` naming the current name.
  macro __sweettalk_renamed(name, renamed_from)
    {% if renamed_from && renamed_from.stringify == name.stringify %}
      {% renamed_from.raise "#{name} is renamed_from: #{renamed_from}, its own name: " +
                            "name the one it used to have, or remove renamed_from:" %}
    {% end %}
  end

  # `SWEETTALK_TABLE`, the plural of *singular* by English rules: unchanged when it ends
  # in s, -ies for a consonant and y, -es after x, z, ch and sh, and -s otherwise.
  macro __sweettalk_table(singular)
    {% plural = singular + "s" %}
    {% plural = singular[0..-2] + "ies" if singular =~ /[^aeiou]y\z/ %}
    {% plural = singular + "es" if singular =~ /(x|z|ch|sh)\z/ %}
    {% plural = singular if singular.ends_with?("s") %}
    SWEETTALK_TABLE = {{ plural }}
  end

  # Included by every `context`: the words a context's body may use.
  module BoundedContext
    # `value Tins, Int32, at_least: 0, means: "…"` is a value object. `+` and `-` take the
    # same value or an integer, `*` an integer, and `times: Quantity` lets `*` take a
    # quantity too. `value Email, String, matches: /…/, length: 3..254, means: "…"`
    # wraps a string, and `value Address, means: "…" do part street : String; … end` is a
    # value of several parts.
    macro value(name, wraps = nil, at_least = nil, at_most = nil, within = nil, times = nil,
                matches = nil, length = nil, means = nil, &block)
      {% if block && !wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} takes parts or a type to wrap, not both" %}
      {% elsif !block && wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} needs parts, as in part street : String" %}
      {% elsif !block && !["Int32", "Int64", "String"].includes?(wraps.stringify) %}
        {% wraps.raise "value #{name} wraps Int32, Int64 or String, or takes parts, not #{wraps}" %}
      {% end %}
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% if block %}
        {% body = block.body %}
        {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
        {% unless expressions.any? { |node| node.is_a?(Call) && node.name == "part" } %}
          {% name.raise "value #{name} needs parts, as in part street : String" %}
        {% end %}
        struct {{ name }} < ::SweetTalk::Composite
          SWEETTALK_MEANS = {{ means }}

          {{ body }}

          __sweettalk_storage
        end
      {% elsif wraps.stringify == "String" %}
        {% options = [{"at_least", at_least}, {"at_most", at_most}, {"within", within},
                      {"times", times}] %}
        {% for option in options %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps String, so it takes matches: and length:, " +
                          "not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% sized = length.is_a?(NilLiteral) ? nil : "#{name} must be between #{length.begin} " +
                                                    "and #{length.end} characters" %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})

          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = "String"

          getter raw : String

          def initialize(@raw : String)
            {% unless matches.is_a?(NilLiteral) %}
              unless {{ matches }}.matches?(@raw)
                raise ::SweetTalk::Refusal.new({{ "#{name} must match #{matches}" }})
              end
            {% end %}
            {% unless length.is_a?(NilLiteral) %}
              unless ({{ length }}).includes?(@raw.size)
                raise ::SweetTalk::Refusal.new({{ sized }})
              end
            {% end %}
          end

          def self.__sweettalk_from_json(any : JSON::Any) : self
            new(any.as_s)
          end

          def <=>(other : self)
            raw <=> other.raw
          end

          def to_s(io : IO) : Nil
            io << raw
          end
        end
      {% else %}
        {% for option in [{"matches", matches}, {"length", length}] %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps #{wraps}, so it takes at_least:, at_most:, " +
                          "within: and times:, not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% least = within ? within.begin : at_least %}
        {% most = within ? (within.excludes_end? ? within.end - 1 : within.end) : at_most %}
        {% factors = [] of Nil %}
        {% factors = times.is_a?(TupleLiteral) ? times : [times] unless times.is_a?(NilLiteral) %}
        {% between = "#{name} must be between #{least} and #{most}" %}
        {% above = "#{name} must be at least #{least}" %}
        {% below = "#{name} must be at most #{most}" %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})

          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = {{ wraps.stringify }}

          getter raw : {{ wraps }}

          def initialize(@raw : {{ wraps }})
            {% if within %}
              if @raw < {{ least }} || @raw > {{ most }}
                raise ::SweetTalk::Refusal.new({{ between }})
              end
            {% else %}
              {% unless least.is_a?(NilLiteral) %}
                raise ::SweetTalk::Refusal.new({{ above }}) if @raw < {{ least }}
              {% end %}
              {% unless most.is_a?(NilLiteral) %}
                raise ::SweetTalk::Refusal.new({{ below }}) if @raw > {{ most }}
              {% end %}
            {% end %}
          end

          def self.new(raw : Int) : self
            new({{ wraps }}.new(raw))
          end

          def self.new(other : ::SweetTalk::Value) : self
            new(other.raw)
          end

          def self.__sweettalk_from_json(any : JSON::Any) : self
            new(any.as_i64)
          end

          def self.zero : self
            new(0)
          end

          def self.additive_identity : self
            new(0)
          end

          def +(other : self | Int::Primitive) : {{ name }}
            {{ name }}.new(raw + ::SweetTalk::Value.raw_of(other))
          end

          def -(other : self | Int::Primitive) : {{ name }}
            {{ name }}.new(raw - ::SweetTalk::Value.raw_of(other))
          end

          def *(other : Int::Primitive) : {{ name }}
            {{ name }}.new(raw * other)
          end

          {% for factor in factors %}
            def *(other : {{ factor }}) : {{ name }}
              {{ name }}.new(raw * other.raw)
            end
          {% end %}

          def <=>(other : self)
            raw <=> other.raw
          end

          def to_i : Int32
            raw.to_i
          end

          def to_s(io : IO) : Nil
            io << raw
          end
        end
      {% end %}
    end

    # `aggregate Tea, means: "…" do … end` is an aggregate root, its table and its
    # repository. `renamed_from: Old` keeps the table and channels of its old name.
    macro aggregate(name, means = nil, renamed_from = nil, &block)
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
      {% context = @type.constant("SWEETTALK_STORED") %}
      {% stored = (renamed_from || name).stringify.underscore %}
      {% base = "#{context.id}_#{stored.id}" %}
      class {{ name }} < ::SweetTalk::Aggregate
        SWEETTALK_KIND    = "aggregate"
        SWEETTALK_MEANS   = {{ means }}
        SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
        SWEETTALK_CONTEXT = {{ context }}
        SWEETTALK_STORED  = {{ stored }}
        SWEETTALK_ROW     = {{ "::#{@type}::Rows::#{name}" }}
        SWEETTALK_BASE    = {{ base }}
        ::SweetTalk.__sweettalk_table({{ base }})

        {{ block ? block.body : nil }}

        __sweettalk_storage
      end
    end

    # `projection Sales, means: "…" do key …; has …; whenever … end` is a read model:
    # a table with one row per key.
    macro projection(name, means = nil, renamed_from = nil, &block)
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
      {% body = block ? block.body : nil %}
      {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% unless expressions.any? { |node| node.is_a?(Call) && node.name == "key" } %}
        {% name.raise "projection #{name} needs a key, as in key tea : Catalogue::Tea, " +
                      "the attribute that picks its row" %}
      {% end %}
      {% context = @type.constant("SWEETTALK_STORED") %}
      {% table = "#{context.id}_#{(renamed_from || name).stringify.underscore.id}" %}
      class {{ name }} < ::SweetTalk::Projection
        SWEETTALK_KIND    = "projection"
        SWEETTALK_MEANS   = {{ means }}
        SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
        SWEETTALK_CONTEXT = {{ context }}
        SWEETTALK_ROW     = {{ "::#{@type}::Rows::#{name}" }}
        ::SweetTalk.__sweettalk_table({{ table }})

        {{ body }}

        __sweettalk_storage
      end
    end

    # `process Hold, means: "…" do key …; has …; moves …; whenever …; compensate …;
    # deadline … end` is a process manager: a table with one row per key, which follows
    # events, runs commands and keeps deadlines.
    macro process(name, means = nil, renamed_from = nil, &block)
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
      {% body = block ? block.body : nil %}
      {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% unless expressions.any? { |node| node.is_a?(Call) && node.name == "key" } %}
        {% name.raise "process #{name} needs a key, as in key slot : Slot, " +
                      "the attribute that picks its row" %}
      {% end %}
      {% context = @type.constant("SWEETTALK_STORED") %}
      {% table = "#{context.id}_#{(renamed_from || name).stringify.underscore.id}" %}
      class {{ name }} < ::SweetTalk::Process
        SWEETTALK_KIND    = "process"
        SWEETTALK_MEANS   = {{ means }}
        SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
        SWEETTALK_CONTEXT = {{ context }}
        SWEETTALK_ROW     = {{ "::#{@type}::Rows::#{name}" }}
        ::SweetTalk.__sweettalk_table({{ table }})

        {{ body }}

        __sweettalk_storage
      end
    end

    # `service requote(order : Order::Id), returns: Cents, means: "…" do … end` is a
    # domain service: an operation that belongs to no one aggregate. It runs in one
    # transaction and may change one aggregate.
    macro service(call, returns = nil, means = nil, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "service takes a verb and typed arguments, " +
                      "as in service requote(order : Order::Id) do … end" %}
      {% end %}
      {% short = @type.name.split("::").last %}
      {% call.raise "#{@type.name.id}.#{call.name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% what = "service #{short.id}.#{call.name}" %}
      {% service = {call.name.stringify, means, call.line_number} %}
      SWEETTALK_SERVICE_{{ call.name.upcase }} = {{ service }}

      {% if returns.is_a?(NilLiteral) %}
        def self.{{ call.name }}({{ call.args.splat }}) : Nil
          ::SweetTalk.__sweettalk_handling({{ what }}, ::SweetTalk::INSTEAD) do
            ::SugarORM::Repo.transaction do
              {{ block.body }}
            end
          end
        end
      {% else %}
        def self.{{ call.name }}({{ call.args.splat }}) : {{ returns }}
          ::SweetTalk.__sweettalk_handling({{ what }}, ::SweetTalk::INSTEAD) do
            %result = nil
            ::SugarORM::Repo.transaction do
              %result = begin
                {{ block.body }}
              end
            end
            %result.as({{ returns }})
          end
        end
      {% end %}
    end

    # `border Other do … end`: the only code in this context that may name `Other::`.
    # Each `whenever` and `compensate` in it carries the border's name, which names its
    # job.
    macro border(other, &block)
      {% body = block.body %}
      {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% for expression in expressions %}
        {% handler = expression.is_a?(Call) && !expression.block.is_a?(Nop) %}
        {% if handler && expression.name == "whenever" %}
          {% each = nil %}
          {% for argument in (expression.named_args || [] of Nil) %}
            {% each = argument.value if argument.name.stringify == "each" %}
          {% end %}
          ::SweetTalk.__sweettalk_policy({{ @type }}, {{ expression.args[0] }}, {{ each }},
            {{ other }}, "context", nil, {{ expression.block.args.splat }}) do
            {{ expression.block.body }}
          end
        {% elsif handler && expression.name == "compensate" %}
          ::SweetTalk.__sweettalk_compensation({{ @type }}, {{ expression.args[0] }}, {{ other }},
            "context", {{ expression.block.args.splat }}) do
            {{ expression.block.body }}
          end
        {% else %}
          {{ expression }}
        {% end %}
      {% end %}
    end

    # `whenever Event do |event| … end` is a policy, run as a Cold Brew job after the
    # command that emitted the event commits.
    macro whenever(event, border = nil, each = nil, &block)
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, {{ border }}, "context",
        nil, {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # `compensate Event do |event, refusal| … end` runs when the `whenever` before it for
    # the same event is refused.
    macro compensate(event, &block)
      ::SweetTalk.__sweettalk_compensation({{ @type }}, {{ event }}, nil, "context",
        {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    macro deadline(name, after = nil, &block)
      {% name.raise "deadline belongs in a process, " +
                    "not in context #{@type.name.split("::").last.id}" %}
    end
  end

  # `context Ordering, follows: Catalogue, means: "…" do … end` is a bounded context. Its
  # source text is kept so the context map can find foreign names, and each border's
  # text apart from the events its `whenever`s name, so reacting to an event is not a
  # dependency.
  macro context(name, follows = nil, means = nil, renamed_from = nil, &block)
    {% prefix = @type == @top_level ? "" : "#{@type.name.id}::" %}
    {% name.raise "#{prefix.id}#{name} needs a meaning: add means: \"…\", " +
                  "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
    ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
    {% body = block ? block.body : nil %}
    {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
    {% followed = [] of Nil %}
    {% followed = [follows] unless follows.is_a?(NilLiteral) %}
    {% followed = follows if follows.is_a?(TupleLiteral) %}
    {% borders = expressions.select { |node| node.is_a?(Call) && node.name == "border" } %}
    {% kinds = %w[value aggregate projection process] %}
    {% own = expressions.select do |node|
         node.is_a?(Call) && kinds.includes?(node.name.stringify) && !node.args.empty?
       end.map(&.args[0].stringify) %}
    {% reacts = [] of Nil %}
    {% pieces = [] of Nil %}
    {% for node in expressions %}
      {% if node.is_a?(Call) && node.name == "border" %}
      {% elsif node.is_a?(Call) && node.name == "process" && !node.block.is_a?(Nop) %}
        {% inner = node.block.body %}
        {% steps = inner.is_a?(Expressions) ? inner.expressions : [inner] %}
        {% for step in steps %}
          {% handler = step.is_a?(Call) && %w[whenever compensate].includes?(step.name.stringify) &&
                       !step.block.is_a?(Nop) %}
          {% if handler %}
            {% path = step.args[0] %}
            {% react = path.is_a?(Path) && {path.names[0].stringify, path.stringify} %}
            {% if react && !own.includes?(react[0]) && !reacts.includes?(react) %}
              {% reacts << react %}
            {% end %}
            {% for argument in (step.named_args || [] of Nil) %}
              {% pieces << argument.value.stringify %}
            {% end %}
            {% pieces << step.block.body.stringify %}
          {% else %}
            {% pieces << step.stringify %}
          {% end %}
        {% end %}
      {% else %}
        {% pieces << node.stringify %}
      {% end %}
    {% end %}
    {% listed = reacts.map { |react| "{#{react[0]}, #{react[1]}}" } %}
    module {{ name }}
      include ::SweetTalk::BoundedContext

      SWEETTALK_MEANS   = {{ means }}
      SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
      SWEETTALK_STORED  = {{ (renamed_from || name).stringify.underscore }}
      SWEETTALK_FOLLOWS = [{{ followed.map(&.names.last.stringify).splat }}] of String
      SWEETTALK_TEXT    = {{ pieces.join("\n") }}
      # {first segment, path} of each event of another context a process follows
      SWEETTALK_REACTS = [{{ listed.join(", ").id }}] of {String, String}
      {% for border in borders %}
        {% inner = border.block.body %}
        {% parts = inner.is_a?(Expressions) ? inner.expressions : [inner] %}
        {% reacting = parts.any? { |part| part.is_a?(Call) && part.name == "whenever" } %}
        {% rest = parts.map do |part|
             handler = part.is_a?(Call) && %w[whenever compensate].includes?(part.name.stringify) &&
                       !part.block.is_a?(Nop)
             handler ? part.block.body.stringify : part.stringify
           end.join("\n") %}
        {% other = border.args[0].names.last %}
        {% entry = {other.stringify, inner.stringify, rest, reacting} %}
        # {other context, its whole text, its text without the events it reacts to, reacts?}
        SWEETTALK_BORDER_{{ other.upcase }} = {{ entry }}
      {% end %}

      # This context's SugarORM schemas, one per aggregate, entity and projection.
      module Rows
      end

      {{ body }}
    end
  end
end
