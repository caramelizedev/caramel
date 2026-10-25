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
  # in s, -ies for a consonant and y, -es after x, z, ch and sh, and -s otherwise. A
  # declaration, *owner* as in "aggregate TeaTin", whose name gives a table another
  # declaration already stores its rows in is refused here, in the domain's words, and
  # so is one whose tenant index would pass PostgreSQL's 63 bytes; *scope* is the context,
  # or the aggregate of an entity.
  macro __sweettalk_table(singular, owner, scope)
    {% plural = singular + "s" %}
    {% plural = singular[0..-2] + "ies" if singular =~ /[^aeiou]y\z/ %}
    {% plural = singular + "es" if singular =~ /(x|z|ch|sh)\z/ %}
    {% plural = singular if singular.ends_with?("s") %}
    {% for other in ::SweetTalk::Model.all_subclasses %}
      {% if other.has_constant?("SWEETTALK_TABLE") &&
              other.constant("SWEETTALK_TABLE") == plural %}
        {% kind = other.constant("SWEETTALK_KIND") %}
        {% path = other.name.split("::") %}
        {% held = kind == "entity" ? "#{path[-2].id}::#{path[-1].id}" : path[-1] %}
        {% singular.raise "#{owner.id} would store its rows in #{plural.id}, already the " +
                          "table of #{kind.id} #{held.id}: rename one of them" %}
      {% end %}
    {% end %}
    {% within = "#{scope.resolve.name}::" %}
    {% home = ::SweetTalk::BoundedContext.includers
         .find { |context| within.starts_with?("#{context.name}::") } %}
    {% tenant = home && home.constant("SWEETTALK_TENANT") %}
    {% index = tenant && "index_#{plural.id}_on_#{tenant[1].id}_id_and_id" %}
    {% if index && index.size > 63 %}
      {% singular.raise "#{owner.id} would store its rows in #{plural.id}, whose tenant index " +
                        "#{index.id} is longer than PostgreSQL's 63 bytes: shorten the " +
                        "context's or the #{owner.split(" ")[0].id}'s name" %}
    {% end %}
    SWEETTALK_TABLE = {{ plural }}
  end

  # Included by every `context`: the words a context's body may use.
  module BoundedContext
    # `value Tins, Int32, at_least: 0, means: "…"` is a value object. `+` and `-` take the
    # same value or an integer, `*` an integer, and `times: Quantity` lets `*` take a
    # quantity too. `value Email, String, matches: /…/, length: 3..254, means: "…"`
    # wraps a string, `value Kind, String, one_of: %w[payment receipt], means: "…"` a string
    # that is one of a closed list, `value Day, Date, means: "…"` a real calendar day (a
    # `SugarORM::Date`, stored in a `date` column through `SugarORM::DateCodec`), and `value
    # Address, means: "…" do part street : String; … end` is a value of several parts.
    # Bounds, lengths and lists are also CHECK constraints
    # on every column that stores the value, and so are integer literals; `database_check:
    # false` keeps them in Crystal only. A pattern is checked in Crystal only, because
    # PostgreSQL reads regular expressions differently. `SWEETTALK_CHECK` records {"range",
    # "lo..hi"}, {"length", name suffix, SQL condition} or {"column", name suffix, SQL
    # condition}, or nil. `SWEETTALK_WRAPS` is the raw type's name and `SWEETTALK_CODEC` the
    # codec that stores it, or nil for a type a column holds as it is.
    macro value(name, wraps = nil, at_least = nil, at_most = nil, within = nil, times = nil,
                matches = nil, length = nil, one_of = nil, database_check = nil, means = nil,
                &block)
      {% if block && !wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} takes parts or a type to wrap, not both" %}
      {% elsif !block && wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} needs parts, as in part street : String" %}
      {% elsif !block && !["Int32", "Int64", "String", "Date"].includes?(wraps.stringify) %}
        {% wraps.raise "value #{name} wraps Int32, Int64, String or Date, or takes parts, " +
                       "not #{wraps}" %}
      {% end %}
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% unless database_check.is_a?(NilLiteral) ||
                  (database_check.is_a?(BoolLiteral) && !database_check) %}
        {% database_check.raise "value #{name} takes database_check: false, which keeps its " +
                                "bounds in Crystal only, not database_check: #{database_check}" %}
      {% end %}
      {% checked = database_check.is_a?(NilLiteral) %}
      {% literal = "value #{name} checks its bounds in the database too, so each is an " +
                   "integer literal, as in at_least: 0 or length: 3..254, not " %}
      {% literally = ": write the number, or add database_check: false" %}
      {% if block %}
        {% unless checked %}
          {% database_check.raise "value #{name} has parts, so database_check: false " +
                                  "belongs on the values its parts wrap" %}
        {% end %}
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
            {% name.raise "value #{name} wraps String, so it takes matches:, length: and " +
                          "one_of:, not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% listed = !one_of.is_a?(NilLiteral) %}
        {% members = [] of Nil %}
        {% if listed %}
          {% unless matches.is_a?(NilLiteral) && length.is_a?(NilLiteral) %}
            {% name.raise "value #{name} lists its members with one_of:, so it takes neither " +
                          "matches: nor length:" %}
          {% end %}
          {% unless one_of.is_a?(ArrayLiteral) && one_of.size > 0 &&
                      one_of.all?(&.is_a?(StringLiteral)) %}
            {% one_of.raise "value #{name} takes one_of: a list of words, as in one_of: " +
                            "%w[payment receipt], not #{one_of}" %}
          {% end %}
          {% members = one_of.map(&.id.stringify) %}
          {% methods = [] of Nil %}
          # A member `receipt` defines `Kind.receipt` and `kind.receipt?`, so it may not be a
          # class method the value has (or every Class and Object has), a predicate every
          # Object has, or a keyword.
          {% taken = %w[all new allocate includes zero from_field name hash class inspect] %}
          {% taken = taken + %w[to_s object_id itself dup clone tap try not_nil pretty_inspect] %}
          {% taken = taken + %w[crystal_type_id instance_sizeof to_json from_json to_yaml] %}
          {% taken = taken + %w[nil same equal is_a responds_to in unsafe_as] %}
          {% taken = taken + %w[abstract alias annotation as asm begin break case def do else] %}
          {% taken = taken + %w[elsif end ensure enum extend false for fun if include lib] %}
          {% taken = taken + %w[macro module next of out pointerof private protected require] %}
          {% taken = taken + %w[rescue return select self sizeof struct super then true] %}
          {% taken = taken + %w[typeof uninitialized union unless until verbatim when while] %}
          {% taken = taken + %w[yield offsetof] %}
          {% for member in members %}
            {% unless member =~ /\A[A-Za-z][A-Za-z0-9_]*\z/ %}
              {% name.raise "value #{name} lists #{member.id} in one_of:, which is not a word of " +
                            "letters, digits and underscores that starts with a letter" %}
            {% end %}
            {% method = member.underscore %}
            {% if methods.includes?(method) %}
              {% name.raise "value #{name} lists #{method.id} twice in one_of:, and each member " +
                            "names #{name}.#{method.id} and #{name}##{method.id}?" %}
            {% elsif taken.includes?(method) %}
              {% name.raise "value #{name} lists #{method.id} in one_of:, which would define " +
                            "#{name}.#{method.id} and #{name}##{method.id}?, names #{name} " +
                            "already has: choose another word" %}
            {% end %}
            {% methods << method %}
          {% end %}
        {% end %}
        {% check = nil %}
        {% if checked && listed %}
          # The check's name carries the hash of the members, so a changed list is a new
          # constraint, as a lifecycle's states are (`__sweettalk_hashed` defines it).
          {% quoted = members.map { |member| "'#{member.id}'" } %}
          {% check = {"column", "one_of_@digest", "IN (#{quoted.join(", ").id})"} %}
        {% elsif checked && !length.is_a?(NilLiteral) %}
          {% unless length.is_a?(RangeLiteral) %}
            {% length.raise literal + length.stringify + literally %}
          {% end %}
          {% for bound in [length.begin, length.end] %}
            {% unless bound.is_a?(Nop) ||
                        (bound.is_a?(NumberLiteral) && bound.kind.stringify =~ /\A:[iu]/) %}
              {% bound.raise literal + bound.stringify + literally %}
            {% end %}
          {% end %}
          {% lo = length.begin.is_a?(Nop) ? nil : length.begin %}
          {% hi = length.end.is_a?(Nop) ? nil : length.end %}
          {% hi = hi - 1 if hi && length.excludes_end? %}
          {% lo = lo.stringify.gsub(/_?[iu](8|16|32|64|128)\z/, "").gsub(/_/, "") if lo %}
          {% hi = hi.stringify.gsub(/_?[iu](8|16|32|64|128)\z/, "").gsub(/_/, "") if hi %}
          {% if lo && hi %}
            {% check = {"length", "length_#{lo.id}_#{hi.id}", "BETWEEN #{lo.id} AND #{hi.id}"} %}
          {% elsif lo %}
            {% check = {"length", "length_from_#{lo.id}", ">= #{lo.id}"} %}
          {% elsif hi %}
            {% check = {"length", "length_to_#{hi.id}", "<= #{hi.id}"} %}
          {% end %}
        {% end %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})
          include ::Caramel::FieldValue(String)

          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = "String"
          SWEETTALK_CODEC = nil
          {% if check && check[1] =~ /@digest/ %}
            ::SweetTalk.__sweettalk_hashed(SWEETTALK_CHECK, {{ check }},
              {{ members.sort.join(",") }})
          {% else %}
            SWEETTALK_CHECK = {{ check }}
          {% end %}
          {% if listed %}
            SWEETTALK_ONE_OF = {{ members }}
          {% end %}

          getter raw : String

          def initialize(@raw : String)
            {% if listed %}
              unless SWEETTALK_ONE_OF.includes?(@raw)
                raise ::SweetTalk::Refusal.new(
                  {{ "#{name} must be one of #{members.join(", ").id}" }})
              end
            {% end %}
            {% unless matches.is_a?(NilLiteral) %}
              unless {{ matches }}.matches?(@raw)
                raise ::SweetTalk::Refusal.new({{ "#{name} must match #{matches}" }})
              end
            {% end %}
            {% unless length.is_a?(NilLiteral) %}
              unless ({{ length }}).includes?(@raw.size)
                raise ::SweetTalk::Refusal.new(
                  ::SweetTalk::Value.__sweettalk_length_refusal({{ name.stringify }}, {{ length }}))
              end
            {% end %}
          end

          {% if listed %}
            # Every member, in the order one_of: lists them.
            def self.all : Array(self)
              SWEETTALK_ONE_OF.map { |member| new(member) }
            end

            # Whether *raw* is one of the members.
            def self.includes?(raw : String) : Bool
              SWEETTALK_ONE_OF.includes?(raw)
            end

            {% for member, index in members %}
              def self.{{ methods[index].id }} : self
                new({{ member }})
              end

              def {{ methods[index].id }}? : Bool
                @raw == {{ member }}
              end
            {% end %}
          {% end %}

          def self.__sweettalk_from_json(any : JSON::Any) : self
            new(any.as_s)
          end

          # Builds the value a contract field binds, or yields the refusal's message.
          def self.from_field(raw : String, & : String ->) : self?
            new(raw)
          rescue error : ::SweetTalk::Refusal
            yield error.message || ""
            nil
          end

          def <=>(other : self)
            raw <=> other.raw
          end

          def to_s(io : IO) : Nil
            io << raw
          end
        end
      {% elsif wraps.stringify == "Date" %}
        {% options = [{"at_least", at_least}, {"at_most", at_most}, {"within", within},
                      {"times", times}, {"matches", matches}, {"length", length},
                      {"one_of", one_of}, {"database_check", database_check}] %}
        {% for option in options %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps Date, a real calendar day, so it takes no " +
                          "#{option[0].id}:" %}
          {% end %}
        {% end %}
        {% refusal = "#{name} must be a calendar day written YYYY-MM-DD, as in 2026-02-28" %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})
          include ::Caramel::FieldValue(String)

          SWEETTALK_MEANS   = {{ means }}
          SWEETTALK_WRAPS   = "::SugarORM::Date"
          SWEETTALK_CODEC   = "::SugarORM::DateCodec"
          SWEETTALK_CHECK   = nil
          SWEETTALK_REFUSAL = {{ refusal }}

          getter raw : ::SugarORM::Date

          def initialize(@raw : ::SugarORM::Date)
          end

          # Reads `YYYY-MM-DD`, and refuses any other text or a day the calendar lacks.
          def self.new(text : String) : self
            date = ::SugarORM::Date.parse?(text)
            raise ::SweetTalk::Refusal.new(SWEETTALK_REFUSAL) unless date
            new(date)
          end

          def self.new(year : Int, month : Int, day : Int) : self
            new(::SugarORM::Date.new(year.to_i32, month.to_i32, day.to_i32))
          rescue ArgumentError | OverflowError
            raise ::SweetTalk::Refusal.new(SWEETTALK_REFUSAL)
          end

          # The calendar day *time* shows in its own zone, with no conversion.
          def self.of(time : Time) : self
            new(::SugarORM::Date.of(time))
          end

          def self.__sweettalk_from_json(any : JSON::Any) : self
            new(any.as_s)
          end

          def self.new(pull : JSON::PullParser) : self
            text = pull.read_string
            date = ::SugarORM::Date.parse?(text)
            pull.raise(SWEETTALK_REFUSAL) unless date
            new(date)
          end

          # Builds the value a contract field binds, or yields the refusal's message.
          def self.from_field(raw : String, & : String ->) : self?
            new(raw)
          rescue error : ::SweetTalk::Refusal
            yield error.message || ""
            nil
          end

          def year : Int32
            raw.year
          end

          def month : Int32
            raw.month
          end

          def day : Int32
            raw.day
          end

          # Midnight UTC of this day.
          def to_time : Time
            raw.to_time
          end

          # The day *days* after this one.
          def +(days : Int) : {{ name }}
            moved(days, 1)
          end

          # The day *days* before this one.
          def -(days : Int) : {{ name }}
            moved(days, -1)
          end

          # How many days this one is after *other*, negative when before it.
          def -(other : self) : Int32
            other.raw.days_until(raw)
          end

          private def moved(days : Int, direction : Int32) : {{ name }}
            count = days.to_i64.clamp(-4_000_000_i64, 4_000_000_i64) * direction
            {{ name }}.new(raw.plus_days(count))
          rescue ArgumentError | OverflowError
            raise ::SweetTalk::Refusal.new(SWEETTALK_REFUSAL)
          end

          def <=>(other : self)
            raw <=> other.raw
          end

          def to_s(io : IO) : Nil
            raw.to_s(io)
          end

          def to_json(json : JSON::Builder) : Nil
            json.string(to_s)
          end
        end
      {% else %}
        {% for option in [{"matches", matches}, {"length", length}, {"one_of", one_of}] %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps #{wraps}, so it takes at_least:, at_most:, " +
                          "within: and times:, not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% if checked %}
          {% if within && !within.is_a?(RangeLiteral) %}
            {% within.raise literal + within.stringify + literally %}
          {% end %}
          {% for bound in (within ? [within.begin, within.end] : [at_least, at_most]) %}
            {% unless bound.is_a?(NilLiteral) || bound.is_a?(Nop) ||
                        (bound.is_a?(NumberLiteral) && bound.kind.stringify =~ /\A:[iu]/) %}
              {% bound.raise literal + bound.stringify + literally %}
            {% end %}
          {% end %}
        {% end %}
        {% least = within ? within.begin : at_least %}
        {% most = within ? (within.excludes_end? ? within.end - 1 : within.end) : at_most %}
        {% check = nil %}
        {% if checked && !(least.is_a?(NilLiteral) && most.is_a?(NilLiteral)) %}
          {% lo = least.is_a?(NilLiteral) || least.is_a?(Nop) ? "" : least.stringify %}
          {% hi = most.is_a?(NilLiteral) || most.is_a?(Nop) ? "" : most.stringify %}
          {% lo = lo.gsub(/_?[iu](8|16|32|64|128)\z/, "").gsub(/_/, "") %}
          {% hi = hi.gsub(/_?[iu](8|16|32|64|128)\z/, "").gsub(/_/, "") %}
          {% check = {"range", "#{lo.id}..#{hi.id}"} %}
        {% end %}
        {% factors = [] of Nil %}
        {% factors = times.is_a?(TupleLiteral) ? times : [times] unless times.is_a?(NilLiteral) %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})
          include ::Caramel::FieldValue({{ wraps }})

          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = {{ wraps.stringify }}
          SWEETTALK_CODEC = nil
          SWEETTALK_CHECK = {{ check }}

          getter raw : {{ wraps }}

          def initialize(@raw : {{ wraps }})
            {% if within %}
              if @raw < {{ least }} || @raw > {{ most }}
                raise ::SweetTalk::Refusal.new(
                  "{{ name }} must be between #{ {{ least }} } and #{ {{ most }} }")
              end
            {% else %}
              {% unless least.is_a?(NilLiteral) %}
                if @raw < {{ least }}
                  raise ::SweetTalk::Refusal.new("{{ name }} must be at least #{ {{ least }} }")
                end
              {% end %}
              {% unless most.is_a?(NilLiteral) %}
                if @raw > {{ most }}
                  raise ::SweetTalk::Refusal.new("{{ name }} must be at most #{ {{ most }} }")
                end
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

          # Builds the value a contract field binds, or yields the refusal's message.
          def self.from_field(raw : {{ wraps }}, & : String ->) : self?
            new(raw)
          rescue error : ::SweetTalk::Refusal
            yield error.message || ""
            nil
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
        ::SweetTalk.__sweettalk_table({{ base }}, {{ "aggregate #{name}" }}, ::{{ @type }})

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
        ::SweetTalk.__sweettalk_table({{ table }}, {{ "projection #{name}" }}, ::{{ @type }})

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
        ::SweetTalk.__sweettalk_table({{ table }}, {{ "process #{name}" }}, ::{{ @type }})

        {{ body }}

        __sweettalk_storage
      end
    end

    # `service requote(order : Order::Id), returns: Cents, means: "…" do … end` is a
    # domain service: an operation that belongs to no one aggregate. It runs in one
    # transaction and may change one aggregate, timed as a domain span named
    # `Ordering.requote`.
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
      {% span = "#{short.id}.#{call.name}" %}
      {% service = {call.name.stringify, means, call.line_number} %}
      SWEETTALK_SERVICE_{{ call.name.upcase }} = {{ service }}

      {% if returns.is_a?(NilLiteral) %}
        def self.{{ call.name }}({{ call.args.splat }}) : Nil
          ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
            ::SweetTalk.__sweettalk_handling({{ what }}, ::SweetTalk::INSTEAD) do
              ::SugarORM::Repo.transaction do
                {{ block.body }}
              end
            end
          end
        end
      {% else %}
        def self.{{ call.name }}({{ call.args.splat }}) : {{ returns }}
          ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
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
        end
      {% end %}
    end

    # `specification Dispatchable, on: Order, where: {state: :placed}, means: "…"` is a
    # rule an aggregate declared before it satisfies or not, stated once. `where:` takes
    # what `finds` takes, or specifications on the same aggregate joined by `&`, `|` and
    # `!`. It adds `Order#dispatchable?`, read in Crystal, and the same rule as a SugarORM
    # condition, read by PostgreSQL in `Order.all(satisfying: Dispatchable)` and in
    # `finds …, satisfying: Dispatchable`. `!` reads as `IS NOT TRUE`, so a NULL column
    # fails a rule and passes its negation in both readings.
    macro specification(name, on = nil, where = nil, means = nil, &block)
      {% context = @type.name.split("::").last %}
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% if block %}
        {% name.raise "specification #{name} takes where:, which SweetTalk reads in Crystal " +
                      "and in PostgreSQL alike, not a block: keep a rule PostgreSQL cannot " +
                      "read in a never, an always or a method" %}
      {% end %}
      {% target = on.is_a?(Path) && on.resolve? %}
      {% unless target && target < ::SweetTalk::Aggregate &&
                  target.name.starts_with?("#{@type.name}::") %}
        {% name.raise "specification #{name} needs on: an aggregate of #{context.id} declared " +
                      "before it, as in specification Dispatchable, on: Order, where: " +
                      "{state: :placed}" %}
      {% end %}
      {% short = target.name.split("::").last %}
      {% predicate = "#{name.stringify.underscore.id}?" %}
      {% if target.has_method?(predicate) %}
        {% name.raise "specification #{name} would define #{short.id}##{predicate.id}, which " +
                      "#{short.id} already has: name the rule for what it means" %}
      {% end %}
      {% attributes = target.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| target.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      {% moves = target.has_constant?("SWEETTALK_MOVES") && target.constant("SWEETTALK_MOVES") %}
      {% names = attributes.reject { |attribute| attribute[2] == "entities" }
           .map { |attribute| attribute[0] } %}
      {% names << "state" if moves %}
      {% grammar = "specification #{name} takes where: {attribute: value}, or specifications " +
                   "on #{short.id} joined by &, | and !, as in where: Dispatchable & !Rushed" %}
      # Flattens the where: tree breadth first with an explicit list, since a macro cannot
      # recurse: `kids[i]` holds the positions of node i's operands, 128 nodes at most.
      {% nodes = [where] %}
      {% kids = [] of Nil %}
      {% index = 0 %}
      {% for step in 0..127 %}
        {% if index < nodes.size %}
          {% node = nodes[index] %}
          {% if node.is_a?(Expressions) && node.expressions.size == 1 %}
            {% node = node.expressions[0] %}
            {% nodes[index] = node %}
          {% end %}
          {% joins = node.is_a?(Call) && %w[& |].includes?(node.name.stringify) &&
                     node.args.size == 1 %}
          {% if joins %}
            {% kids << [nodes.size, nodes.size + 1] %}
            {% nodes << node.receiver %}
            {% nodes << node.args[0] %}
          {% elsif node.is_a?(Not) %}
            {% kids << [nodes.size] %}
            {% nodes << node.exp %}
          {% else %}
            {% kids << [] of Nil %}
          {% end %}
          {% index = index + 1 %}
        {% end %}
      {% end %}
      # Then reads it leaves first: each node's Crystal predicate and SugarORM condition.
      {% preds = {} of Nil => Nil %}
      {% conds = {} of Nil => Nil %}
      {% row = target.constant("SWEETTALK_ROW").id %}
      {% typings = [] of Nil %}
      {% for offset in 0...nodes.size %}
        {% position = nodes.size - 1 - offset %}
        {% node = nodes[position] %}
        {% children = kids[position] %}
        {% if node.is_a?(Call) && node.name.stringify == "&" %}
          {% preds[position] = "(#{preds[children[0]].id} && #{preds[children[1]].id})" %}
          {% conds[position] = "::SweetTalk.__sweettalk_all([#{conds[children[0]].id}, " +
                               "#{conds[children[1]].id}])" %}
        {% elsif node.is_a?(Call) && node.name.stringify == "|" %}
          {% preds[position] = "(#{preds[children[0]].id} || #{preds[children[1]].id})" %}
          {% conds[position] = "::SweetTalk.__sweettalk_any([#{conds[children[0]].id}, " +
                               "#{conds[children[1]].id}])" %}
        {% elsif node.is_a?(Not) %}
          {% preds[position] = "!(#{preds[children[0]].id})" %}
          {% conds[position] = "::SweetTalk.__sweettalk_none(#{conds[children[0]].id})" %}
        {% elsif node.is_a?(Path) %}
          {% other = node.resolve? %}
          {% unless other && other < ::SweetTalk::Specification &&
                      other.constant("SWEETTALK_ON") == target.name.stringify %}
            {% node.raise "specification #{name} joins #{node}, which is not a specification " +
                          "on #{short.id} declared before it" %}
          {% end %}
          {% preds[position] = "#{other.name.split("::").last.underscore.id}?" %}
          {% conds[position] = "::#{other}.__sweettalk_condition" %}
        {% elsif node.is_a?(NamedTupleLiteral) %}
          {% checks = [] of Nil %}
          {% wheres = [] of Nil %}
          {% for key, value in node %}
            {% if key.stringify == "state" %}
              {% unless moves %}
                {% value.raise "specification #{name} filters on state, which #{short.id} does " +
                               "not have; it has #{names.join(", ").id}" %}
              {% end %}
              {% states = value.is_a?(ArrayLiteral) ? value : [value] %}
              {% for state in states %}
                {% unless moves.includes?(state.id.stringify) %}
                  {% state.raise "specification #{name} asks for state #{state.id}, which " +
                                 "#{short.id} does not have; states: #{moves.join(", ").id}" %}
                {% end %}
              {% end %}
              {% wanted = states.map(&.id.stringify) %}
              {% wanted = wanted[0] unless value.is_a?(ArrayLiteral) %}
              {% checks << "::SweetTalk.__sweettalk_holds?(__sweettalk_state, #{wanted})" %}
              {% wheres << "::SugarORM::Condition.column(\"state\", #{wanted})" %}
            {% else %}
              {% attribute = attributes.find { |attribute| attribute[0] == key.stringify } %}
              {% if !attribute %}
                {% value.raise "specification #{name} filters on #{key.id}, which #{short.id} " +
                               "does not have; it has #{names.join(", ").id}" %}
              {% elsif attribute[2] == "entities" %}
                {% value.raise "specification #{name} cannot filter on #{key.id}, a list of " +
                               "entities: PostgreSQL reads one #{short.id} row; keep a rule " +
                               "over #{key.id} in a never, an always or a method" %}
              {% elsif value.is_a?(NilLiteral) && !attribute[9] %}
                {% value.raise "specification #{name} asks for #{key.id}: nil, but #{key.id} is " +
                               "not optional: nil is a value of an optional attribute, as in " +
                               "has #{key.id} : #{attribute[3].id}?" %}
              {% elsif attribute[2] == "composite" && attribute[9] && value.is_a?(NilLiteral) %}
                {% checks << "@#{attribute[0].id}.nil?" %}
                {% wheres << "::SugarORM::Condition.column(#{attribute[7][0][1]}, nil)" %}
                {% typings << "typeof(#{row}.query.where(#{attribute[7][0][1].id}: nil))" %}
              {% elsif attribute[2] == "composite" %}
                {% for part in attribute[7] %}
                  {% raw = part[4] == "value" ? ".raw" : "" %}
                  {% have = "@#{attribute[0].id}.#{part[0].id}#{raw.id}" %}
                  {% have = "@#{attribute[0].id}.try(&.#{part[0].id}#{raw.id})" if attribute[9] %}
                  {% want = "::SweetTalk.column((#{value}).#{part[0].id})" %}
                  {% checks << "::SweetTalk.__sweettalk_holds?(#{have.id}, #{want.id})" %}
                  {% if part[6] %}
                    {% encoded = "#{row}.__sugar_encode_#{part[1].id}(#{want.id})" %}
                    {% wheres << "::SweetTalk.__sweettalk_coded(#{part[1]}, #{encoded.id})" %}
                  {% else %}
                    {% wheres << "::SugarORM::Condition.column(#{part[1]}, #{want.id})" %}
                  {% end %}
                  {% typings << "typeof(#{row}.query.where(#{part[1].id}: #{want.id}))" %}
                {% end %}
              {% else %}
                {% have = "@#{attribute[4].id}" %}
                {% have = "@#{attribute[0].id}.raw" if attribute[2] == "value" %}
                {% if attribute[2] == "value" && attribute[9] %}
                  {% have = "@#{attribute[0].id}.try(&.raw)" %}
                {% end %}
                {% want = "::SweetTalk.column(#{value})" %}
                {% checks << "::SweetTalk.__sweettalk_holds?(#{have.id}, #{want.id})" %}
                {% if attribute[11] %}
                  {% encoded = "#{row}.__sugar_encode_#{attribute[4].id}(#{want.id})" %}
                  {% wheres << "::SweetTalk.__sweettalk_coded(#{attribute[4]}, #{encoded.id})" %}
                {% else %}
                  {% wheres << "::SugarORM::Condition.column(#{attribute[4]}, #{want.id})" %}
                {% end %}
                {% typings << "typeof(#{row}.query.where(#{attribute[4].id}: #{want.id}))" %}
              {% end %}
            {% end %}
          {% end %}
          {% preds[position] = "(#{checks.join(" && ").id})" %}
          {% conds[position] = "::SweetTalk.__sweettalk_all([#{wheres.join(", ").id}])" %}
        {% else %}
          {% (node.is_a?(Nop) || node.is_a?(NilLiteral) ? name : node).raise grammar %}
        {% end %}
      {% end %}
      struct {{ name }} < ::SweetTalk::Specification
        SWEETTALK_KIND  = "specification"
        SWEETTALK_MEANS = {{ means }}
        SWEETTALK_ON    = {{ target.name.stringify }}

        # Whether *candidate* satisfies this rule, read in Crystal.
        def self.satisfied_by?(candidate : ::{{ target }}) : Bool
          candidate.{{ predicate.id }}
        end

        # The same rule as a SugarORM condition, read by PostgreSQL.
        def self.__sweettalk_condition : ::SugarORM::Condition
          # Types each value against its column as finds does, without running a query.
          {{ typings.join("\n").id }}
          {{ conds[0].id }}
        end
      end

      class ::{{ target }}
        # Whether this {{ short.id }} satisfies `specification {{ name }}`: {{ means.id }}
        def {{ predicate.id }} : Bool
          {{ preds[0].id }}
        end
      end

      # Types the condition now, so a value of the wrong type does not compile even when no
      # query asks for this rule; typeof runs nothing.
      typeof({{ name }}.__sweettalk_condition)
    end

    # Checks every `finds` and `counts` of this context's aggregates and projections when
    # the context closes, whether or not anything calls them: each key names a stored
    # attribute or `state:` a declared state, each `order:` key `id` or an attribute stored
    # in one column, and `satisfying:` a specification on the same aggregate.
    macro __sweettalk_check_queries
      {% depth = @type.name.split("::").size + 1 %}
      {% owners = ::SweetTalk::Aggregate.all_subclasses + ::SweetTalk::Projection.all_subclasses %}
      {% owners = owners.select do |owner|
           owner.name.starts_with?("#{@type.name}::") && owner.name.split("::").size == depth
         end %}
      {% for target in owners %}
        {% short = target.name.split("::").last %}
        {% attributes = target.constants.select(&.starts_with?("SWEETTALK_HAS_"))
             .map { |constant| target.constant(constant) }.sort_by { |attribute| attribute[1] } %}
        {% moves = target.has_constant?("SWEETTALK_MOVES") && target.constant("SWEETTALK_MOVES") %}
        {% names = attributes.reject { |attribute| attribute[2] == "entities" }
             .map { |attribute| attribute[0] } %}
        {% names << "state" if moves %}
        {% for constant in target.constants.select(&.starts_with?("SWEETTALK_QUERY_")) %}
          {% query = target.constant(constant) %}
          {% word = "#{query[0].id} #{query[1].id}" %}
          {% at = "\n  --> #{query[6].id}" %}
          {% for key in query[2] %}
            {% attribute = attributes.find { |attribute| attribute[0] == key } %}
            {% if key == "state" && !moves %}
              {% raise "#{word.id} filters on state, which #{short.id} does not have; it has " +
                       "#{names.join(", ").id}" + at %}
            {% elsif key != "state" && !attribute %}
              {% raise "#{word.id} filters on #{key.id}, which #{short.id} does not have; it " +
                       "has #{names.join(", ").id}" + at %}
            {% elsif attribute && attribute[2] == "entities" %}
              {% raise "#{word.id} cannot filter on #{key.id}, a list of entities" + at %}
            {% end %}
          {% end %}
          {% for state in query[3] %}
            {% unless moves.includes?(state) %}
              {% raise "#{word.id} asks for state #{state.id}, which #{short.id} does not " +
                       "have; states: #{moves.join(", ").id}" + at %}
            {% end %}
          {% end %}
          {% for key in query[4] %}
            {% attribute = attributes.find { |attribute| attribute[0] == key } %}
            {% sortable = key == "id" ||
                          (attribute && !%w[entities composite].includes?(attribute[2])) %}
            {% unless sortable %}
              {% raise "#{word.id} orders by #{key.id}, which #{short.id} cannot sort by: " +
                       "order by id, or by an attribute stored in one column" + at %}
            {% end %}
          {% end %}
          {% if query[5] %}
            {% rule = parse_type(query[5]).resolve? %}
            {% unless rule && rule < ::SweetTalk::Specification &&
                        rule.constant("SWEETTALK_ON") == target.name.stringify %}
              {% raise "#{word.id} takes satisfying: a specification on #{short.id}, not " +
                       "#{query[5].id}" + at %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    # `border Other do … end`: the only code in this context that may name `Other::`.
    # Each `whenever` and `compensate` in it carries the border's name, which names its
    # job. `border Cards, outside: "…" do … end` is the border with a system outside the
    # program, a module `Cards` in this context: the only code that may name
    # `Caramel::Outbound` or `HTTP::Client`, a check on the text as written, and that turns
    # its answers into this context's values.
    macro border(other, outside = nil, &block)
      {% body = block.body %}
      {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
      # The context refuses an outside: that is not text, so text is what marks it.
      {% if outside.is_a?(StringLiteral) %}
        {% for expression in expressions %}
          {% if expression.is_a?(Call) &&
                  %w[whenever compensate].includes?(expression.name.stringify) %}
            {% expression.raise "#{expression.name} belongs in a border with a context: " +
                                "#{other} is outside the program and emits no events" %}
          {% end %}
        {% end %}
        module {{ other }}
          {{ body }}
        end
        {% expressions = [] of Nil %}
      {% end %}
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

    # `publishes Cents, Tea::Id, price_of` is this context's published language: the
    # types and services another context may name. Once a context publishes, every other
    # context names only those, and the events it reacts to. `context` reads the list;
    # this checks that each name is declared before it.
    macro publishes(*names)
      {% short = @type.name.split("::").last %}
      {% for name in names %}
        {% if name.is_a?(Path) %}
          {% found = name.resolve? %}
          {% declared = found && found.name.starts_with?("#{@type.name}::") %}
        {% elsif name.is_a?(Call) && name.receiver.is_a?(Nop) && name.args.empty? %}
          {% declared = @type.has_constant?("SWEETTALK_SERVICE_#{name.name.upcase}") %}
        {% else %}
          {% name.raise "publishes takes the context's types and services, as in " +
                        "publishes Cents, Tea::Id, price_of, not #{name}" %}
        {% end %}
        {% unless declared %}
          {% name.raise "#{short.id} publishes #{name}, which it does not declare: declare " +
                        "a type or a service of that name before publishes" %}
        {% end %}
      {% end %}
    end
  end

  # `tenant App::Account`, before the first context, names the tenant model of a program
  # that requires caramel/tenancy: the model the routes' `tenant` block names.
  # `SWEETTALK_TENANT` records {the model's path, the attribute named after its last
  # segment}; every context copies it unless it says `central: true`.
  macro tenant(model)
    {% unless ::Caramel.has_constant?("Tenancy") %}
      {% model.raise "tenant #{model} needs require \"caramel/tenancy\" before this domain" %}
    {% end %}
    {% if @type.has_constant?("SWEETTALK_TENANT") %}
      {% model.raise "tenant #{model} is named twice in #{@type}: keep one" %}
    {% end %}
    {% earlier = ::SweetTalk::BoundedContext.includers
         .find(&.name.starts_with?("#{@type.name}::")) %}
    {% if earlier %}
      {% model.raise "tenant #{model} comes after context #{earlier.name.split("::").last.id}: " +
                     "name the tenant before the contexts" %}
    {% end %}
    {% resolved = model.resolve? %}
    {% unless resolved && resolved < ::SugarORM::Schema %}
      {% model.raise "tenant #{model} must name a SugarORM schema declared before it" %}
    {% end %}
    {% entry = {resolved.name.stringify, resolved.name.split("::").last.underscore} %}
    SWEETTALK_TENANT = {{ entry }}
  end

  # `context Ordering, follows: Catalogue, means: "…" do … end` is a bounded context. Its
  # source text is kept so the context map can find foreign names, and each border's
  # text apart from the events its `whenever`s name, so reacting to an event is not a
  # dependency. In a program that requires caramel/tenancy its rows belong to one tenant,
  # unless it says `central: true`, which shares them between every tenant.
  # `subdomain: :core`, `:supporting` or `:generic` says what part of the domain it is.
  # `publishes` lists the names other contexts may use, and `border X, outside: "…"`
  # faces a system outside the program.
  macro context(name, follows = nil, means = nil, renamed_from = nil, central = nil,
                subdomain = nil, &block)
    {% prefix = @type == @top_level ? "" : "#{@type.name.id}::" %}
    {% name.raise "#{prefix.id}#{name} needs a meaning: add means: \"…\", " +
                  "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
    {% unless central.is_a?(NilLiteral) || (central.is_a?(BoolLiteral) && central) %}
      {% central.raise "context #{name} takes central: true, which shares its rows between " +
                       "tenants, not central: #{central}" %}
    {% end %}
    {% if central && !::Caramel.has_constant?("Tenancy") %}
      {% central.raise "context #{name} takes central: true only in a program that requires " +
                       "caramel/tenancy" %}
    {% end %}
    {% subdomains = %w[core supporting generic] %}
    {% unless subdomain.is_a?(NilLiteral) ||
                (subdomain.is_a?(SymbolLiteral) && subdomains.includes?(subdomain.id.stringify)) %}
      {% subdomain.raise "context #{name} takes subdomain: :core, :supporting or :generic, " +
                         "not subdomain: #{subdomain}" %}
    {% end %}
    {% tenant = @type.has_constant?("SWEETTALK_TENANT") && !central &&
                @type.constant("SWEETTALK_TENANT") %}
    ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
    {% body = block ? block.body : nil %}
    {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
    {% followed = [] of Nil %}
    {% followed = [follows] unless follows.is_a?(NilLiteral) %}
    {% followed = follows if follows.is_a?(TupleLiteral) %}
    # A border is outside when its outside: is text, as in the border macro; any other
    # outside:, nil included, is refused at the border's line.
    {% for node in expressions %}
      {% if node.is_a?(Call) && node.name == "border" %}
        {% said = (node.named_args || [] of Nil).find { |arg| arg.name.stringify == "outside" } %}
        {% if said && !said.value.is_a?(StringLiteral) %}
          {% node.raise "border #{node.args[0]} takes outside: \"…\", what the system is to " +
                        "this context, the line its glossary entry shows" %}
        {% end %}
      {% end %}
    {% end %}
    {% outsides = expressions.select do |node|
         node.is_a?(Call) && node.name == "border" &&
           (node.named_args || [] of Nil).any? do |arg|
             arg.name.stringify == "outside" && arg.value.is_a?(StringLiteral)
           end
       end %}
    {% borders = expressions.select do |node|
         node.is_a?(Call) && node.name == "border" && !outsides.includes?(node)
       end %}
    {% published = nil %}
    {% for node in expressions %}
      {% if node.is_a?(Call) && node.name == "publishes" %}
        {% published = [] of Nil unless published %}
        {% for argument in node.args %}
          {% published << argument.stringify %}
        {% end %}
      {% end %}
    {% end %}
    # {statement, its text, in an outside border?} for each statement a check may refuse,
    # so the refusal names its line; a handler's text leaves out the event it reacts to.
    {% handlers = %w[whenever compensate] %}
    {% checks = [] of Nil %}
    {% for node in expressions %}
      {% block = node.is_a?(Call) && !node.block.is_a?(Nop) %}
      {% outside = outsides.includes?(node) %}
      {% if block && handlers.includes?(node.name.stringify) %}
        {% extra = (node.named_args || [] of Nil).map(&.value.stringify).join("\n") %}
        {% checks << {node, node.block.body.stringify + "\n" + extra, false} %}
      {% elsif block %}
        {% extra = (node.named_args || [] of Nil).map(&.value.stringify).join("\n") %}
        {% checks << {node, node.args.map(&.stringify).join("\n") + "\n" + extra, false} %}
        {% inner = node.block.body %}
        {% for step in (inner.is_a?(Expressions) ? inner.expressions : [inner]) %}
          {% nested = step.is_a?(Call) && !step.block.is_a?(Nop) &&
                      handlers.includes?(step.name.stringify) %}
          {% if nested %}
            {% extra = (step.named_args || [] of Nil).map(&.value.stringify).join("\n") %}
            {% checks << {step, step.block.body.stringify + "\n" + extra, outside} %}
          {% else %}
            {% checks << {step, step.stringify, outside} %}
          {% end %}
        {% end %}
      {% else %}
        {% checks << {node, node.stringify, false} %}
      {% end %}
    {% end %}
    # The published languages of the contexts of this domain declared before this one.
    {% for up in ::SweetTalk::BoundedContext.includers %}
      {% upname = up.name.split("::").last %}
      {% offers = up.constant("SWEETTALK_PUBLISHES") %}
      {% if offers && up.name.stringify == prefix + upname && upname != name.stringify %}
        {% offered = offers.join(", ") %}
        {% for check in checks %}
          {% for piece in check[1].split(upname + "::")[1..-1] %}
            {% path = piece.gsub(/\A([A-Z]\w*(?:::[A-Z]\w*)*)[\s\S]*\z/, "\\1") %}
            {% found = parse_type(up.name.stringify + "::" + path).resolve? %}
            {% open = offers.any? { |offer| path == offer || path.starts_with?(offer + "::") } ||
                      (found && found < ::SweetTalk::Event) %}
            {% unless open %}
              {% check[0].raise "#{prefix.id}#{name} names #{upname.id}::#{path.id}, which " +
                                "#{upname.id} does not publish; it publishes #{offered.id}: use " +
                                "one of those, or publish #{path.id} in #{upname.id}" %}
            {% end %}
          {% end %}
          {% for piece in check[1].split(upname + ".")[1..-1] %}
            {% call = piece =~ /\A[a-z_]/ && piece.gsub(/\A([a-z_]\w*[?!]?)[\s\S]*\z/, "\\1") %}
            {% if call && !offers.includes?(call) %}
              {% check[0].raise "#{prefix.id}#{name} calls #{upname.id}.#{call.id}, which " +
                                "#{upname.id} does not publish; it publishes #{offered.id}: " +
                                "use one of those, or publish #{call.id} in #{upname.id}" %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    # HTTP leaves the program only through a border with an outside system.
    {% for check in checks %}
      {% reached = nil %}
      {% reached = "Caramel::Outbound" if check[1].includes?("Caramel::Outbound") %}
      {% reached = "HTTP::Client" if check[1].includes?("HTTP::Client") %}
      {% if reached && !check[2] %}
        {% check[0].raise "#{prefix.id}#{name} reaches #{reached.id} outside a border with an " +
                          "outside system: move that call into the border with the system it " +
                          "reaches, as in border Cards, outside: \"…\" do … end" %}
      {% end %}
    {% end %}
    {% kinds = %w[value aggregate projection process] %}
    {% own = expressions.select do |node|
         node.is_a?(Call) && kinds.includes?(node.name.stringify) && !node.args.empty?
       end.map(&.args[0].stringify) %}
    {% reacts = [] of Nil %}
    {% pieces = [] of Nil %}
    {% for node in expressions %}
      {% if borders.includes?(node) %}
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
    {% offering = published ? "[#{published.map(&.stringify).join(", ").id}] of String" : "nil" %}
    module {{ name }}
      include ::SweetTalk::BoundedContext

      SWEETTALK_MEANS   = {{ means }}
      SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
      SWEETTALK_STORED  = {{ (renamed_from || name).stringify.underscore }}
      # {tenant model, attribute} when this context's rows belong to one tenant
      SWEETTALK_TENANT  = {{ tenant ? tenant : nil }}
      SWEETTALK_CENTRAL = {{ central ? true : false }}
      SWEETTALK_SUBDOMAIN = {{ subdomain.is_a?(NilLiteral) ? nil : subdomain.id.stringify }}
      SWEETTALK_FOLLOWS = [{{ followed.map(&.names.last.stringify).splat }}] of String
      SWEETTALK_TEXT    = {{ pieces.join("\n") }}
      # {first segment, path} of each event of another context a process follows
      SWEETTALK_REACTS = [{{ listed.join(", ").id }}] of {String, String}
      # The names other contexts may use, or nil when every name is open to a follower
      SWEETTALK_PUBLISHES = {{ offering.id }}
      {% for border in outsides %}
        {% system = border.args[0].names.last %}
        {% said = border.named_args.find { |argument| argument.name.stringify == "outside" } %}
        # {outside system, what it is to this context}
        SWEETTALK_OUTSIDE_{{ system.upcase }} = { {{ system.stringify }}, {{ said.value }} }
      {% end %}
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

      __sweettalk_check_queries
    end
  end
end
