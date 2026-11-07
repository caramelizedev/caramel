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
  # declaration already stores its rows in, or one over PostgreSQL's 63 bytes, which it
  # would truncate silently, is refused here, in the domain's words.
  macro __sweettalk_table(singular, owner)
    {% plural = singular + "s" %}
    {% plural = singular[0..-2] + "ies" if singular =~ /[^aeiou]y\z/ %}
    {% plural = singular + "es" if singular =~ /(x|z|ch|sh)\z/ %}
    {% plural = singular if singular.ends_with?("s") %}
    {% if plural.size > 63 %}
      {% singular.raise "#{owner.id} would store its rows in #{plural.id}, longer than " +
                        "PostgreSQL's 63 bytes: shorten its name or the names it is built from" %}
    {% end %}
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
    SWEETTALK_TABLE = {{ plural }}
  end

  # Included by every `context` and `kernel`: the words their bodies may use.
  module BoundedContext
    # `value Tins, Int32, at_least: 0, means: "…"` is a value object. `+` and `-` take the
    # same value or an integer, `*` an integer, and `times: Quantity` lets `*` take a
    # quantity too. `value Email, String, matches: /…/, length: 3..254, means: "…"`
    # wraps a string, `value Kind, String, one_of: %w[payment receipt], means: "…"` a string
    # that is one of a closed list, `value Day, Date, means: "…"` a real calendar day (a
    # `SugarORM::Date`, stored in a `date` column through `SugarORM::DateCodec`), `value
    # Rate, Decimal(20, 8), at_least: "0", means: "…"` a `BigDecimal` kept in a
    # `numeric(20,8)` column through `SugarORM::DecimalCodec` (with `caramel/sweet_talk/
    # decimal` required), `value Evidence, Json(Snapshot), means: "…"` a JSON document, a
    # `JSON::Serializable` type or `JSON::Any` for `Json` alone, kept in a `jsonb` column
    # through `SugarORM::JSONB`, and `value Address, means: "…" do part street : String; …
    # end` is a value of several parts. Bounds, lengths and lists are also CHECK constraints
    # on every column that stores the value, and so are literals, integers or, for a
    # decimal, decimal text; `database_check: false` keeps them in Crystal only. A pattern
    # is checked in Crystal only, because PostgreSQL reads regular expressions differently.
    # `otherwise: "A balance cannot go below zero."` is the sentence a value outside its
    # bounds, length, pattern or list is refused with, in place of the generated one
    # (ADR 0045); the database check is unchanged.
    # `SWEETTALK_CHECK` records {"range", "lo..hi"}, {"length", name suffix, SQL condition}
    # or {"column", name suffix, SQL condition}, or nil. A whole number or decimal value also
    # records `SWEETTALK_BOUNDS = {least, most}`, each its source text or nil.
    # `SWEETTALK_WRAPS` is the raw type's name and `SWEETTALK_CODEC` the codec that stores
    # it, or nil for a type a column holds as it is.
    #
    # @word noun | A value object: a bounded number, string, day, decimal or JSON, or parts.
    # @usage value NAME, TYPE[, at_least: N][, at_most: N][, within: RANGE][, times: TYPE]
    #   [, matches: REGEXP][, length: RANGE][, one_of: LIST][, database_check: false]
    #   [, otherwise: TEXT], means: TEXT
    # @guide c-sweettalk-values
    # @option wraps positional | Int32, Int64, String, Date, Decimal(P, S) or Json(T) | - | The
    #   type the value wraps. Leave it out and give a block of `part` lines for a value with parts.
    # @option at_least | integer literal; decimal text for a Decimal | - | The smallest number
    #   the value takes. PostgreSQL checks it too.
    # @option at_most | integer literal; decimal text for a Decimal | - | The largest number the
    #   value takes. PostgreSQL checks it too.
    # @option within | range of integer literals, as 1..10 | - | Both bounds at once; 1...10
    #   leaves the end out.
    # @option times | a value type, or a list of them | - | A type `*` takes as its factor, as
    #   `Quantity` lets a price multiply by a quantity. Whole-number values only.
    # @option matches | a regular expression literal | - | The pattern a string must match.
    #   Checked in Crystal only, because PostgreSQL reads patterns differently.
    # @option length | range of integer literals, as 3..254 | - | How many characters a string
    #   holds. PostgreSQL checks it too.
    # @option one_of | list of words, as %w[payment receipt] | - | The closed list a string is one
    #   of. Each word starts with a letter. The value takes neither matches: nor length:.
    # @option database_check | false | checked in PostgreSQL | false keeps bounds, lengths and
    #   lists in Crystal only.
    # @option otherwise | text | the generated sentence | The sentence a value outside its
    #   bounds, length, pattern or list is refused with. Needs one of them.
    # @option means | text | - | What the value is, in a line the glossary shows. Required.
    # @example
    #   context Shelf, means: "the teas we keep" do
    #     value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"
    #   end
    macro value(name, wraps = nil, at_least = nil, at_most = nil, within = nil, times = nil,
                matches = nil, length = nil, one_of = nil, database_check = nil,
                otherwise = nil, means = nil, &block)
      {% if block && !wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} takes parts or a type to wrap, not both" %}
      {% elsif !block && wraps.is_a?(NilLiteral) %}
        {% name.raise "value #{name} needs parts, as in part street : String" %}
      {% elsif !block && !["Int32", "Int64", "String", "Date"].includes?(wraps.stringify) &&
                 !(wraps.is_a?(Generic) && %w[Decimal Json].includes?(wraps.name.stringify)) &&
                 wraps.stringify != "Json" %}
        {% wraps.raise "value #{name} wraps Int32, Int64, String, Date, Decimal(P, S) or " +
                       "Json(T), or takes parts, not #{wraps}" %}
      {% end %}
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% unless database_check.is_a?(NilLiteral) ||
                  (database_check.is_a?(BoolLiteral) && !database_check) %}
        {% database_check.raise "value #{name} takes database_check: false, which keeps its " +
                                "bounds in Crystal only, not database_check: #{database_check}" %}
      {% end %}
      {% checked = database_check.is_a?(NilLiteral) %}
      {% unless otherwise.is_a?(NilLiteral) || otherwise.is_a?(StringLiteral) %}
        {% otherwise.raise "value #{name} takes otherwise: the sentence a value outside its " +
                           "bounds is refused with, as in otherwise: \"A balance cannot go " +
                           "below zero.\", not #{otherwise}" %}
      {% end %}
      {% literal = "value #{name} checks its bounds in the database too, so each is an " +
                   "integer literal, as in at_least: 0 or length: 3..254, not " %}
      {% literally = ": write the number, or add database_check: false" %}
      {% if block %}
        {% unless checked %}
          {% database_check.raise "value #{name} has parts, so database_check: false " +
                                  "belongs on the values its parts wrap" %}
        {% end %}
        {% unless otherwise.is_a?(NilLiteral) %}
          {% otherwise.raise "value #{name} has parts, so otherwise: belongs on the values " +
                             "its parts wrap" %}
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
        {% bounded = !one_of.is_a?(NilLiteral) || !matches.is_a?(NilLiteral) ||
                     !length.is_a?(NilLiteral) %}
        {% if !otherwise.is_a?(NilLiteral) && !bounded %}
          {% otherwise.raise "value #{name} takes otherwise: only with matches:, length: or " +
                             "one_of:, whose sentences it replaces" %}
        {% end %}
        {% worded = !otherwise.is_a?(NilLiteral) %}
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

            __sweettalk_members({{ methods }})
          {% end %}

          getter raw : String

          def initialize(@raw : String)
            {% if listed %}
              unless SWEETTALK_ONE_OF.includes?(@raw)
                raise ::SweetTalk::Refusal.new(
                  {{ worded ? otherwise : "#{name} must be one of #{members.join(", ").id}" }})
              end
            {% end %}
            {% unless matches.is_a?(NilLiteral) %}
              unless {{ matches }}.matches?(@raw)
                raise ::SweetTalk::Refusal.new(
                  {{ worded ? otherwise : "#{name} must match #{matches}" }})
              end
            {% end %}
            {% unless length.is_a?(NilLiteral) %}
              unless ({{ length }}).includes?(@raw.size)
                {% if worded %}
                  raise ::SweetTalk::Refusal.new({{ otherwise }})
                {% else %}
                  short = {{ name.stringify }}
                  raise ::SweetTalk::Refusal.new(
                    ::SweetTalk::Value.__sweettalk_length_refusal(short, {{ length }}))
                {% end %}
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
                      {"one_of", one_of}, {"database_check", database_check},
                      {"otherwise", otherwise}] %}
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
      {% elsif wraps.is_a?(Generic) && wraps.name.stringify == "Decimal" %}
        {% unless ::SugarORM.has_constant?("DecimalCodec") %}
          {% wraps.raise "value #{name} wraps Decimal, which needs require " +
                         "\"caramel/sweet_talk/decimal\" before this domain: a program that " +
                         "declares no decimal value never links GMP" %}
        {% end %}
        {% digits = wraps.type_vars %}
        {% whole = digits.size == 2 && digits.all? do |digit|
             digit.is_a?(NumberLiteral) && digit.kind.stringify =~ /\A:[iu]/
           end %}
        {% shape = "value #{name} takes Decimal(P, S), the digits in all and the digits " +
                   "after the point, as in Decimal(20, 8), with S at most P and P at most " +
                   "1000, not #{wraps}" %}
        {% wraps.raise shape unless whole %}
        {% precision = digits[0] %}
        {% scale = digits[1] %}
        {% wraps.raise shape unless scale >= 0 && scale <= precision && precision <= 1000 &&
                                    precision >= 1 %}
        {% options = [{"within", within}, {"times", times}, {"matches", matches},
                      {"length", length}, {"one_of", one_of}] %}
        {% for option in options %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps Decimal, so it takes at_least: and at_most:, " +
                          "each a decimal written as text, not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% bounded = !at_least.is_a?(NilLiteral) || !at_most.is_a?(NilLiteral) %}
        {% if !otherwise.is_a?(NilLiteral) && !bounded %}
          {% otherwise.raise "value #{name} takes otherwise: only with at_least: or at_most:, " +
                             "whose sentences it replaces" %}
        {% end %}
        {% worded = !otherwise.is_a?(NilLiteral) %}
        {% texts = [] of Nil %}
        {% bounds = [] of Nil %}
        {% for option in [{"at_least", at_least}, {"at_most", at_most}] %}
          {% bound = option[1] %}
          {% bounds << (bound.is_a?(StringLiteral) ? bound : bound.stringify) %}
          {% bounds[-1] = nil if bound.is_a?(NilLiteral) %}
          {% if bound.is_a?(NilLiteral) %}
            {% texts << nil %}
          {% elsif !bound.is_a?(StringLiteral) && checked %}
            {% bound.raise "value #{name} checks its bounds in the database too, so each is " +
                           "a decimal written as text, as in at_least: \"0\" or at_most: " +
                           "\"1.5\", not #{bound}: write it in quotes, or add " +
                           "database_check: false" %}
          {% elsif !bound.is_a?(StringLiteral) %}
            {% texts << nil %}
          {% elsif !(bound =~ /\A-?\d+(\.\d+)?\z/) %}
            {% bound.raise "value #{name} takes #{option[0].id}: a decimal written with " +
                           "digits and a point, as in #{option[0].id}: \"0.25\", not #{bound}" %}
          {% elsif bound.split(".").size == 2 && bound.split(".")[1].size > scale %}
            {% bound.raise "value #{name} takes #{option[0].id}: #{bound}, which has more " +
                           "than #{scale} decimals: Decimal(#{precision}, #{scale}) keeps " +
                           "#{scale}, so a bound written past them would never hold" %}
          {% elsif bound.split(".")[0].gsub(/\A-?0*/, "").size > precision - scale %}
            {% bound.raise "value #{name} takes #{option[0].id}: #{bound}, which has more " +
                           "than #{precision - scale} digits before the point, all that " +
                           "Decimal(#{precision}, #{scale}) holds" %}
          {% else %}
            {% texts << bound %}
          {% end %}
        {% end %}
        {% check = nil %}
        {% if checked && (texts[0] || texts[1]) %}
          # The bounds join the constraint's name, as a length's do, so a changed bound is a
          # new constraint; `.` becomes `_` and a leading `-` `minus`.
          {% lo = texts[0] && texts[0].gsub(/\./, "_").gsub(/\A-/, "minus") %}
          {% hi = texts[1] && texts[1].gsub(/\./, "_").gsub(/\A-/, "minus") %}
          {% if texts[0] && texts[1] %}
            {% check = {"column", "between_#{lo.id}_and_#{hi.id}",
                        "BETWEEN #{texts[0].id} AND #{texts[1].id}"} %}
          {% elsif texts[0] %}
            {% check = {"column", "from_#{lo.id}", ">= #{texts[0].id}"} %}
          {% else %}
            {% check = {"column", "to_#{hi.id}", "<= #{texts[1].id}"} %}
          {% end %}
        {% end %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})
          include ::Caramel::FieldValue(String)

          SWEETTALK_MEANS     = {{ means }}
          SWEETTALK_WRAPS     = "::BigDecimal"
          SWEETTALK_CODEC     = {{ "::SugarORM::DecimalCodec(#{precision}, #{scale})" }}
          SWEETTALK_CHECK     = {{ check }}
          SWEETTALK_BOUNDS    = {{ {bounds[0], bounds[1]} }}
          SWEETTALK_PRECISION = {{ precision }}
          SWEETTALK_SCALE     = {{ scale }}
          SWEETTALK_REFUSAL   = ::SweetTalk::Decimal.refusal({{ name.stringify }})
          {% unless at_least.is_a?(NilLiteral) %}
            SWEETTALK_LEAST = ::BigDecimal.new({{ at_least }})
          {% end %}
          {% unless at_most.is_a?(NilLiteral) %}
            SWEETTALK_MOST = ::BigDecimal.new({{ at_most }})
          {% end %}

          getter raw : ::BigDecimal

          # Refuses a decimal the column would round or overflow, then one outside the
          # bounds.
          def initialize(@raw : ::BigDecimal)
            text = ::SugarORM::Decimal.plain(@raw)
            unless ::SugarORM::Decimal.fits(text, SWEETTALK_PRECISION, SWEETTALK_SCALE)
              raise ::SweetTalk::Refusal.new(
                "{{ name }} keeps #{SWEETTALK_SCALE} decimals and " \
                "#{SWEETTALK_PRECISION - SWEETTALK_SCALE} digits before the point, " \
                "not #{text}")
            end
            {% unless at_least.is_a?(NilLiteral) %}
              if @raw < SWEETTALK_LEAST
                {% if worded %}
                  raise ::SweetTalk::Refusal.new({{ otherwise }})
                {% else %}
                  raise ::SweetTalk::Refusal.new(
                    "{{ name }} must be at least #{ {{ at_least }} }")
                {% end %}
              end
            {% end %}
            {% unless at_most.is_a?(NilLiteral) %}
              if @raw > SWEETTALK_MOST
                {% if worded %}
                  raise ::SweetTalk::Refusal.new({{ otherwise }})
                {% else %}
                  raise ::SweetTalk::Refusal.new(
                    "{{ name }} must be at most #{ {{ at_most }} }")
                {% end %}
              end
            {% end %}
          end

          # Reads digits with at most one point, `12.50`, and refuses any other text.
          def self.new(text : String) : self
            new(::SweetTalk::Decimal.parse({{ name.stringify }}, text))
          end

          def self.new(raw : Int) : self
            new(::BigDecimal.new(raw))
          end

          def self.__sweettalk_from_json(any : JSON::Any) : self
            new(any.as_s)
          end

          def self.new(pull : JSON::PullParser) : self
            text = pull.read_string
            pull.raise(SWEETTALK_REFUSAL) unless text.matches?(::SugarORM::Decimal::TEXT)
            new(text)
          end

          # Builds the value a contract field binds, or yields the refusal's message.
          def self.from_field(raw : String, & : String ->) : self?
            new(raw)
          rescue error : ::SweetTalk::Refusal
            yield error.message || ""
            nil
          end

          def self.zero : self
            new(0)
          end

          def +(other : self) : {{ name }}
            {{ name }}.new(raw + other.raw)
          end

          def -(other : self) : {{ name }}
            {{ name }}.new(raw - other.raw)
          end

          def *(other : Int::Primitive) : {{ name }}
            {{ name }}.new(raw * other)
          end

          def <=>(other : self)
            raw <=> other.raw
          end

          # Plain digits, `-12.5`, with no exponent and no trailing zeros after the point.
          def to_s(io : IO) : Nil
            io << ::SugarORM::Decimal.plain(raw)
          end

          def to_json(json : JSON::Builder) : Nil
            json.string(to_s)
          end

          def __sweettalk_pack(json : JSON::Builder) : Nil
            json.string(to_s)
          end
        end
      {% elsif wraps.stringify == "Json" ||
                 (wraps.is_a?(Generic) && wraps.name.stringify == "Json") %}
        {% options = [{"at_least", at_least}, {"at_most", at_most}, {"within", within},
                      {"times", times}, {"matches", matches}, {"length", length},
                      {"one_of", one_of}, {"database_check", database_check},
                      {"otherwise", otherwise}] %}
        {% for option in options %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps Json, a document PostgreSQL keeps whole, so it " +
                          "takes no #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% if wraps.is_a?(Generic) %}
          {% unless wraps.type_vars.size == 1 && wraps.type_vars[0].is_a?(Path) &&
                      wraps.type_vars[0].resolve? %}
            {% wraps.raise "value #{name} takes Json(T), T a JSON::Serializable type declared " +
                           "before it, or Json alone for any document, not #{wraps}" %}
          {% end %}
          {% document = wraps.type_vars[0].resolve %}
          {% unless document <= ::JSON::Serializable || document == ::JSON::Any %}
            {% wraps.raise "value #{name} takes Json(T), T a JSON::Serializable type or " +
                           "JSON::Any, not #{document}, which includes neither" %}
          {% end %}
          {% document = "::#{document}" %}
        {% else %}
          {% document = "::JSON::Any" %}
        {% end %}
        struct {{ name }} < ::SweetTalk::Value
          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = {{ document }}
          SWEETTALK_CODEC = {{ "::SugarORM::JSONB(#{document.id})" }}
          SWEETTALK_CHECK = nil

          getter raw : {{ document.id }}

          def initialize(@raw : {{ document.id }})
          end

          # Reads the document from its JSON text.
          def self.parse(text : String) : self
            new({{ document.id }}.from_json(text))
          end

          def self.__sweettalk_from_json(any : JSON::Any) : self
            {% if document == "::JSON::Any" %}
              new(any)
            {% else %}
              new({{ document.id }}.from_json(any.to_json))
            {% end %}
          end

          def self.new(pull : JSON::PullParser) : self
            new({{ document.id }}.new(pull))
          end

          def to_json(json : JSON::Builder) : Nil
            raw.to_json(json)
          end

          def to_s(io : IO) : Nil
            raw.to_json(io)
          end
        end
      {% else %}
        {% for option in [{"matches", matches}, {"length", length}, {"one_of", one_of}] %}
          {% unless option[1].is_a?(NilLiteral) %}
            {% name.raise "value #{name} wraps #{wraps}, so it takes at_least:, at_most:, " +
                          "within: and times:, not #{option[0].id}:" %}
          {% end %}
        {% end %}
        {% bounded = !at_least.is_a?(NilLiteral) || !at_most.is_a?(NilLiteral) ||
                     !within.is_a?(NilLiteral) %}
        {% if !otherwise.is_a?(NilLiteral) && !bounded %}
          {% otherwise.raise "value #{name} takes otherwise: only with at_least:, at_most: or " +
                             "within:, whose sentences it replaces" %}
        {% end %}
        {% worded = !otherwise.is_a?(NilLiteral) %}
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
        {% least_text = least.is_a?(NilLiteral) || least.is_a?(Nop) ? nil : least.stringify %}
        {% most_text = most.is_a?(NilLiteral) || most.is_a?(Nop) ? nil : most.stringify %}
        {% factors = [] of Nil %}
        {% factors = times.is_a?(TupleLiteral) ? times : [times] unless times.is_a?(NilLiteral) %}
        struct {{ name }} < ::SweetTalk::Value
          include Comparable({{ name }})
          include ::Caramel::FieldValue({{ wraps }})

          SWEETTALK_MEANS = {{ means }}
          SWEETTALK_WRAPS = {{ wraps.stringify }}
          SWEETTALK_CODEC = nil
          SWEETTALK_CHECK = {{ check }}
          SWEETTALK_BOUNDS = {{ {least_text, most_text} }}

          getter raw : {{ wraps }}

          def initialize(@raw : {{ wraps }})
            {% if within %}
              if @raw < {{ least }} || @raw > {{ most }}
                {% if worded %}
                  raise ::SweetTalk::Refusal.new({{ otherwise }})
                {% else %}
                  raise ::SweetTalk::Refusal.new(
                    "{{ name }} must be between #{ {{ least }} } and #{ {{ most }} }")
                {% end %}
              end
            {% else %}
              {% unless least.is_a?(NilLiteral) %}
                if @raw < {{ least }}
                  {% if worded %}
                    raise ::SweetTalk::Refusal.new({{ otherwise }})
                  {% else %}
                    raise ::SweetTalk::Refusal.new("{{ name }} must be at least #{ {{ least }} }")
                  {% end %}
                end
              {% end %}
              {% unless most.is_a?(NilLiteral) %}
                if @raw > {{ most }}
                  {% if worded %}
                    raise ::SweetTalk::Refusal.new({{ otherwise }})
                  {% else %}
                    raise ::SweetTalk::Refusal.new("{{ name }} must be at most #{ {{ most }} }")
                  {% end %}
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
    #
    # @word noun | Declares an aggregate: a root with an id, attributes, commands and events.
    # @usage aggregate NAME, means: TEXT[, renamed_from: OLD] do ... end
    # @guide c-sweettalk-aggregates
    # @option means | text | - | What the aggregate is, in a line the glossary shows. Required.
    # @option renamed_from | the old name, as a constant | - | Keeps the table and channels of the
    #   old name, so no data moves. Naming the aggregate itself is refused.
    # @example
    #   context Quayside, means: "where ships tie up" do
    #     aggregate Berth, means: "one place a ship can tie up" do
    #       has metres : Int32
    #     end
    #   end
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
        ::SweetTalk.__sweettalk_table({{ base }}, {{ "aggregate #{name}" }})

        {{ block ? block.body : nil }}

        __sweettalk_storage
      end
    end

    # `projection Sales, means: "…" do key …; has …; whenever … end` is a read model:
    # a table with one row per key.
    #
    # @word noun | Declares a projection: a read model with one table row per key.
    # @usage projection NAME, means: TEXT[, renamed_from: OLD] do ... end
    # @in in a context
    # @guide c-sweettalk-projections
    # @option means | text | - | What the projection shows, in a line the glossary shows. Required.
    # @option renamed_from | the old name, as a constant | - | Keeps the table and channels of the
    #   old name, so no data moves. Naming the projection itself is refused.
    # @example
    #   context Dockyard, means: "ships built and launched" do
    #     aggregate Ship, means: "one ship on the slip" do
    #       has name : String
    #       event Launched, means: "a ship left the slip"
    #
    #       to launch do
    #         emit Launched
    #       end
    #     end
    #
    #     projection Launches, means: "how many times one ship left the slip" do
    #       key ship : Ship
    #       has total : Int32 = 0
    #
    #       whenever Ship::Launched do |launched|
    #         row = Launches[launched.ship_id]
    #         row.total += 1
    #       end
    #     end
    #   end
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
        ::SweetTalk.__sweettalk_table({{ table }}, {{ "projection #{name}" }})

        {{ body }}

        __sweettalk_storage
      end
    end

    # `process Hold, means: "…" do key …; has …; moves …; whenever …; compensate …;
    # deadline … end` is a process manager: a table with one row per key, which follows
    # events, runs commands and keeps deadlines.
    #
    # @word noun | Declares a process: a row per key that follows events and keeps deadlines.
    # @usage process NAME, means: TEXT[, renamed_from: OLD] do ... end
    # @in in a context
    # @guide c-sweettalk-processes
    # @option means | text | - | What the process is, in a line the glossary shows. Required.
    # @option renamed_from | the old name, as a constant | - | Keeps the table and channels of the
    #   old name, so no data moves. Naming the process itself is refused.
    # @example
    #   context Granary, means: "grain waiting for the mill" do
    #     aggregate Sack, means: "one sack of grain" do
    #       has kilos : Int32
    #       event Filled, means: "a sack was filled"
    #
    #       factory fill(kilos : Int32) do
    #         emit Filled
    #       end
    #     end
    #
    #     process Wait, means: "the wait of one filled sack for the mill" do
    #       key sack : Int64
    #       has days : Int32 = 0
    #       moves waiting >> milling
    #
    #       whenever Sack::Filled, key: filled.sack_id.raw do |filled|
    #         @days = 1
    #         milling!
    #       end
    #     end
    #   end
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
        ::SweetTalk.__sweettalk_table({{ table }}, {{ "process #{name}" }})

        {{ body }}

        __sweettalk_storage
      end
    end

    # `service requote(order : Order::Id), returns: Cents, means: "…" do … end` is a
    # domain service: an operation that belongs to no one aggregate. It runs in one
    # transaction and may change one aggregate, timed as a domain span named
    # `Ordering.requote`.
    #
    # @word noun | Declares a domain service: an operation that belongs to no one aggregate.
    # @usage service VERB[(ARG : TYPE, ...)][, returns: TYPE], means: TEXT do ... end
    # @in in a context
    # @guide c-sweettalk-services
    # @option returns | a type | Nil | What the service answers, its body's last expression.
    # @option means | text | - | What the service does, in a line the glossary shows. Required.
    # @example
    #   context Pantry, means: "what the kitchen keeps" do
    #     aggregate Jar, means: "one jar on the shelf" do
    #       has label : String
    #     end
    #
    #     service label_of(jar : Jar::Id), returns: String, means: "the label a jar carries" do
    #       Jar.find(jar).label
    #     end
    #   end
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
                __sweettalk_events = [] of ::SweetTalk::Event
                {{ block.body }}
                __sweettalk_events.each { |event| ::SweetTalk.dispatch(event) }
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
                __sweettalk_events = [] of ::SweetTalk::Event
                %result = begin
                  {{ block.body }}
                end
                __sweettalk_events.each { |event| ::SweetTalk.dispatch(event) }
              end
              %result.as({{ returns }})
            end
          end
        end
      {% end %}

      # Typed by `SweetTalk.boot`, so the body compiles whether or not anything calls it.
      def self.__sweettalk_touch_{{ call.name }} : Nil
        {% params = call.args.map { |arg| "#{arg.var} : #{arg.type}" } %}
        ->({{ params.join(", ").id }}) { {{ call.name }}({{ call.args.map(&.var).splat }}) }
        nil
      end
    end

    # `unit post(journal : Journal::Id, segments : Array(Segment::Id)), changes: [Journal,
    # Position, Segment], locks: [journal, segments], returns: Nil, means: "…" do … end`
    # is a unit (ADR 0046): one transaction whose commands change the aggregates named in
    # `changes:`, each existing row locked first through `SweetTalk.lock` on the arguments
    # `locks:` names, in table then id order. A `never` or `always` line in its body is a
    # rule over the set, checked after the body; a `warn "…" { … }` line, checked with them,
    # refuses a plain call and is listed by `SweetTalk.preview` (ADR 0060). It is a glossary
    # entry, timed as a domain span named `Ledger.post`. `once_by: key` makes it run once
    # per operation key: the first run keeps the key, a fingerprint of the other arguments
    # and what it returned in the context's `<context>_operations` table; a repeat with the
    # same arguments answers the first outcome without running, and one with other
    # arguments is refused with `otherwise:` (ADR 0055).
    #
    # @word noun | Declares a unit: one transaction that changes several aggregates, their rows
    #   locked first.
    # @usage unit VERB(ARG : TYPE, ...), changes: [AGGREGATE, ...][, locks: [ARG, ...]]
    #   [, returns: TYPE][, once_by: ARG][, otherwise: TEXT][, assures: IDS], means: TEXT do ... end
    # @in in a context
    # @guide c-sweettalk-units
    # @option changes | list of aggregates, as [Journal, Position] | - | The aggregates its
    #   commands may change, declared before the unit. Required.
    # @option locks | an argument name, or a list of them | - | The arguments whose rows are
    #   locked before the body runs: ids, aggregates, or arrays of either. A command on an
    #   existing row it does not lock raises SweetTalk::Boundary.
    # @option returns | a type | Nil | What the unit answers.
    # @option once_by | name of a String argument, or of one that wraps String | - | Runs the unit
    #   once per key. Its other arguments and returns: take ids, not aggregates.
    # @option otherwise | text | the generated sentence | The sentence a key used again with
    #   other arguments is refused with. Needs once_by:.
    # @option assures | requirement id or list of ids, as "AC-12" | - | The requirement ids the
    #   unit answers, which the module lists in requirements.
    # @option means | text | - | What the unit does, in a line the glossary shows. Required.
    # @example
    #   context Bakehouse, means: "loaves baked and racked" do
    #     value Loaves, Int32, means: "a count of loaves"
    #
    #     aggregate Rack, means: "one rack of loaves" do
    #       has loaves : Loaves
    #
    #       to take(count : Loaves) do
    #         refuse "The rack holds fewer loaves." if count > loaves
    #         @loaves -= count
    #       end
    #
    #       to add(count : Loaves) do
    #         @loaves += count
    #       end
    #     end
    #
    #     unit move(source : Rack, target : Rack, count : Loaves), changes: [Rack],
    #       locks: [source, target], means: "moves loaves from one rack to another" do
    #       source.take count
    #       target.add count
    #       never "A rack holds at most 90 loaves." { target.loaves.raw > 90 }
    #     end
    #   end
    #
    # @word warn rule | Refuses a plain call of the unit with a sentence a person can confirm.
    # @usage warn MESSAGE { CONDITION }
    # @in in a unit
    # @guide c-sweettalk-preview
    # @example
    #   context Tollgate, means: "the price of crossing the gate" do
    #     value Cents, Int64, means: "an amount of money"
    #
    #     aggregate Toll, means: "what one crossing costs" do
    #       has price : Cents
    #
    #       to reprice(price : Cents) do
    #         @price = price
    #       end
    #     end
    #
    #     unit discount(toll : Toll::Id, price : Cents), changes: [Toll], locks: [toll],
    #       means: "lowers the price of one crossing" do
    #       found = Toll.find(toll)
    #       was = found.price
    #       found.reprice price
    #       warn "The new price is less than half the old one." { price.raw * 2 < was.raw }
    #     end
    #   end
    macro unit(call, changes = nil, locks = nil, returns = nil, once_by = nil, otherwise = nil,
               assures = nil, means = nil, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "unit takes a verb and typed arguments, " +
                      "as in unit post(journal : Journal::Id) do … end" %}
      {% end %}
      {% short = @type.name.split("::").last %}
      {% call.raise "#{@type.name.id}.#{call.name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% named = changes.is_a?(ArrayLiteral) ? changes : [changes] %}
      {% unless named.size > 0 && named.all?(&.is_a?(Path)) %}
        {% call.raise "unit #{call.name} takes changes: [Journal, Position], the aggregates " +
                      "its commands change, declared before it, not changes: #{changes}" %}
      {% end %}
      {% allowed = [] of Nil %}
      {% for path in named %}
        {% found = path.resolve? %}
        {% unless found && found.is_a?(TypeNode) && found < ::SweetTalk::Aggregate %}
          {% path.raise "unit #{call.name} changes #{path}, which is no aggregate declared " +
                        "before it: declare aggregate #{path} above the unit, or take it " +
                        "out of changes:" %}
        {% end %}
        {% if @type.constant("SWEETTALK_CENTRAL") %}
          {% home = ::SweetTalk::BoundedContext.includers
               .find { |context| found.name.starts_with?("#{context.name}::") } %}
          {% if home && home.constant("SWEETTALK_TENANT") %}
            {% path.raise "unit #{call.name} in #{short.id}, a central context, changes " +
                          "#{path}, whose rows belong to a tenant: a central context's unit " +
                          "changes the aggregates of central contexts alone" %}
          {% end %}
        {% end %}
        {% allowed << found.name %}
      {% end %}
      {% held = [] of Nil %}
      {% held = [locks] unless locks.is_a?(NilLiteral) %}
      {% held = locks if locks.is_a?(ArrayLiteral) %}
      {% arguments = call.args.map(&.var.stringify) %}
      {% for name in held %}
        {% known = (name.is_a?(Var) || (name.is_a?(Call) && name.args.empty?)) &&
                   arguments.includes?(name.stringify) %}
        {% unless known %}
          {% name.raise "unit #{call.name} locks #{name}, which is not one of its arguments: " +
                        "locks: names the arguments whose rows it changes, as in locks: " +
                        "[#{arguments.join(", ").id}]" %}
        {% end %}
      {% end %}
      {% once = nil %}
      {% once_text = nil %}
      {% others = call.args %}
      {% if once_by.is_a?(NilLiteral) %}
        {% unless otherwise.is_a?(NilLiteral) %}
          {% otherwise.raise "unit #{call.name} takes otherwise: only with once_by:, the " +
                             "sentence a key used again with other arguments is refused with" %}
        {% end %}
      {% else %}
        {% known = (once_by.is_a?(Var) ||
                    (once_by.is_a?(Call) && once_by.args.empty? && once_by.receiver.is_a?(Nop))) &&
                   arguments.includes?(once_by.stringify) %}
        {% unless known %}
          {% once_by.raise "unit #{call.name} runs once by #{once_by}, which is not one of its " +
                           "arguments: once_by: names the argument that names the operation, " +
                           "one of #{arguments.join(", ").id}" %}
        {% end %}
        {% once = once_by.stringify %}
        {% key_arg = call.args.find { |arg| arg.var.stringify == once } %}
        {% key_type = key_arg.type.resolve? %}
        {% once_text = key_type == String %}
        {% wraps_text = key_type && key_type < ::SweetTalk::Value &&
                        key_type.constant("SWEETTALK_WRAPS") == "String" %}
        {% unless once_text || wraps_text %}
          {% once_by.raise "unit #{call.name} runs once by #{once.id} : #{key_arg.type}, which " +
                           "is no text: once_by: names a String argument or a value that " +
                           "wraps String" %}
        {% end %}
        {% unless otherwise.is_a?(NilLiteral) || otherwise.is_a?(StringLiteral) %}
          {% otherwise.raise "unit #{call.name} takes otherwise: the sentence a key used " +
                             "again with other arguments is refused with, as in otherwise: " +
                             "\"That transfer was already recorded differently.\", not " +
                             "#{otherwise}" %}
        {% end %}
        {% others = call.args.reject { |arg| arg.var.stringify == once } %}
        {% for arg in others %}
          {% candidates = arg.type.is_a?(Union) ? arg.type.types : [arg.type] %}
          {% for candidate in candidates %}
            {% element = candidate %}
            {% if candidate.is_a?(Generic) && candidate.name.stringify == "Array" %}
              {% element = candidate.type_vars[0] %}
            {% end %}
            {% held_type = element.is_a?(Path) ? element.resolve? : nil %}
            {% if held_type && held_type < ::SweetTalk::Aggregate %}
              {% fixed = arg.type.stringify.split(element.id.stringify)
                   .join("#{element.id}::Id") %}
              {% arg.raise "unit #{call.name} runs once by #{once.id}, so it keeps its other " +
                           "arguments to tell a retry from another request: take " +
                           "#{arg.var} : #{fixed.id}, not #{arg.var} : #{arg.type}" %}
            {% end %}
          {% end %}
        {% end %}
        {% unless returns.is_a?(NilLiteral) %}
          {% candidates = returns.is_a?(Union) ? returns.types : [returns] %}
          {% for candidate in candidates %}
            {% element = candidate %}
            {% if candidate.is_a?(Generic) && candidate.name.stringify == "Array" %}
              {% element = candidate.type_vars[0] %}
            {% end %}
            {% held_type = element.is_a?(Path) ? element.resolve? : nil %}
            {% if held_type && held_type < ::SweetTalk::Aggregate %}
              {% fixed = returns.stringify.split(element.id.stringify)
                   .join("#{element.id}::Id") %}
              {% returns.raise "unit #{call.name} runs once by #{once.id}, so it keeps what it " +
                               "returns for a retry: return #{fixed.id}, not #{returns}" %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      {% body = block.body %}
      {% steps = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% rules = steps.select do |step|
           step.is_a?(Call) && %w[never always warn].includes?(step.name.stringify) &&
             step.args.size == 1 && step.args[0].is_a?(StringLiteral) && !step.block.is_a?(Nop)
         end %}
      {% work = steps.reject { |step| rules.includes?(step) } %}
      {% what = "unit #{short.id}.#{call.name}" %}
      {% span = "#{short.id}.#{call.name}" %}
      {% unit = {call.name.stringify, means, call.line_number, once,
                 named.map(&.stringify).join(", "), held.map(&.stringify).join(", ")} %}
      {% kinds = allowed.map { |name| "::#{name.id}" }.join(", ") %}
      {% refusal = "#{short.id}.#{call.name} already ran under this key with other arguments" %}
      {% refusal = otherwise unless otherwise.is_a?(NilLiteral) %}
      SWEETTALK_UNIT_{{ call.name.upcase }} = {{ unit }}
      ::SweetTalk.__sweettalk_assures("unit", {{ "unit #{short.id}.#{call.name}" }}, {{ means }},
        {{ assures }}, {{ @type.name.stringify }}, {{ "#{@type.name}.#{call.name}" }},
        {{ "SWEETTALK_ASSURES_UNIT_#{call.name.upcase}" }})
      {% for rule in rules %}
        {% said = (rule.named_args || [] of Nil).find { |arg| arg.name.stringify == "assures" } %}
        {% field = (rule.named_args || [] of Nil).find { |arg| arg.name.stringify == "on" } %}
        {% if field %}
          ::SweetTalk.__sweettalk_refusal_field({{ rule.name.stringify }}, {{ field.value }})
        {% end %}
        {% if said && rule.name == "warn" %}
          {% said.raise "warn in unit #{short.id}.#{call.name} takes no assures:: a warning " +
                        "that a person confirms lets the change through, so it assures nothing; " +
                        "make it a never to assure the requirement" %}
        {% end %}
        {% if said %}
          ::SweetTalk.__sweettalk_assures({{ rule.name.stringify }},
            {{ "#{rule.name} in unit #{short.id}.#{call.name}" }}, {{ rule.args[0] }},
            {{ said.value }}, {{ @type.name.stringify }}, {{ "#{@type.name}.#{call.name}" }},
            {{ "SWEETTALK_ASSURES_UNIT_#{call.name.upcase}_#{rule.args[0].line_number}" }})
        {% end %}
      {% end %}

      {% result = returns.is_a?(NilLiteral) ? Nil : returns %}
      def self.{{ call.name }}({{ call.args.splat }}) : {{ result }}
        ::Caramel::Crema.measure(::Caramel::Crema::SpanKind::Domain, {{ span }}) do
          %allowed = [{{ kinds.id }}] of ::SweetTalk::Aggregate.class
          %result = nil
          ::SweetTalk.__sweettalk_unit({{ what }}, %allowed) do
            {% if once %}
              %payload = ::JSON.build do |json|
                json.object do
                  {% for arg in others %}
                    json.field({{ arg.var.stringify }}) { ::SweetTalk.pack(json, {{ arg.var }}) }
                  {% end %}
                end
              end
              %fingerprint = ::Digest::SHA256.hexdigest(%payload)
              %key = {{ once_text ? once.id : "#{once.id}.raw".id }}
              # The claim is a savepoint: a key already claimed rolls back the insert alone, and
              # a concurrent first run holds this one on its uncommitted row.
              %claim = begin
                ::SugarORM::Repo.transaction do
                  Rows::Operations.create!(unit: {{ call.name.stringify }}, key: %key,
                    fingerprint: %fingerprint, outcome: ::JSON::Any.new(nil),
                    created_at: Time.utc)
                end
              rescue ::SugarORM::UniqueViolation | ::SugarORM::Invalid
                nil
              end
              unless %claim
                %earlier = Rows::Operations.query
                  .where(unit: {{ call.name.stringify }}, key: %key).first!
                unless %earlier.fingerprint == %fingerprint
                  raise ::SweetTalk::Refusal.new({{ refusal }})
                end
                {% unless returns.is_a?(NilLiteral) %}
                  %result = ::SweetTalk.unpack({{ returns }}, %earlier.outcome)
                {% end %}
                next
              end
            {% end %}
            {% unless held.empty? %}
              ::SweetTalk.lock({{ held.splat }})
            {% end %}
            %result = begin
              {% for step in work %}
                {{ step }}
              {% end %}
            end
            {% for rule in rules %}
              {% named = rule.named_args || [] of Nil %}
              {% field = named.find { |arg| arg.name.stringify == "on" } %}
              {% on = field ? field.value : nil %}
              {% if rule.name == "never" %}
                if ({{ rule.block.body }})
                  raise ::SweetTalk::Refusal.new({{ rule.args[0] }}, on: {{ on }})
                end
              {% elsif rule.name == "warn" %}
                ::SweetTalk.__sweettalk_warn({{ rule.args[0] }}) if ({{ rule.block.body }})
              {% else %}
                unless ({{ rule.block.body }})
                  raise ::SweetTalk::Refusal.new({{ rule.args[0] }}, on: {{ on }})
                end
              {% end %}
            {% end %}
            {% if once && !returns.is_a?(NilLiteral) %}
              %claim.update!(outcome: ::JSON.parse(::JSON.build do |json|
                ::SweetTalk.pack(json, %result.as({{ returns }}))
              end))
            {% end %}
          end
          {% unless returns.is_a?(NilLiteral) %}
            %result.as({{ returns }})
          {% end %}
        end
      end

      # Typed by `SweetTalk.boot`, so the body compiles whether or not anything calls it.
      def self.__sweettalk_touch_{{ call.name }} : Nil
        {% params = call.args.map { |arg| "#{arg.var} : #{arg.type}" } %}
        ->({{ params.join(", ").id }}) { {{ call.name }}({{ call.args.map(&.var).splat }}) }
        nil
      end
    end

    # `event Renamed, name : String, means: "…"` is one of this context's events: what a
    # service records when it changes what no aggregate holds, such as the tenant's own
    # settings. A context holds no attributes, so it takes no `carries:`. Its channel is
    # `sweettalk.<context>.<event>`, within the limits an aggregate's event keeps.
    # `older: {till: "front"}` gives the value a queued job or a logged row without that
    # field reads.
    #
    # @word noun | Declares an event the context records itself, with the fields it carries.
    # @usage event NAME[, FIELD : TYPE ...], means: TEXT[, renamed_from: OLD]
    #   [, older: {FIELD: VALUE}]
    # @in in a context
    # @internal carries
    # @guide c-sweettalk-events
    # @option means | text | - | What happened, in a line the glossary shows. Required.
    # @option renamed_from | the old name, as a constant | - | Keeps the channel and the job names
    #   of the old name, so no data moves.
    # @option older | named tuple of field to value, as {total: Cents.new(0)} | - | What a queued
    #   job or a logged row written before a required field existed reads for it.
    # @example
    #   context Parlour, means: "the shop front" do
    #     event Renamed, name : String, means: "the parlour was given a new name"
    #
    #     service rename(name : String), means: "gives the parlour a new name" do
    #       emit Renamed, name: name
    #     end
    #   end
    macro event(name, *fields, carries = nil, means = nil, renamed_from = nil, older = nil)
      {% short = @type.name.split("::").last %}
      {% unless carries.is_a?(NilLiteral) %}
        {% carries.raise "event #{name} in #{short.id} takes no carries:: a context holds no " +
                         "attributes to carry; declare the fields it records, as in " +
                         "event #{name}, name : String" %}
      {% end %}
      {% stored = (renamed_from || name).stringify.underscore %}
      {% channel = "sweettalk.#{@type.constant("SWEETTALK_STORED").id}.#{stored.id}" %}
      {% tenanted = @type.constant("SWEETTALK_TENANT") ? true : false %}
      ::SweetTalk.__sweettalk_event({{ name }}{% for field in fields %}, {{ field }}{% end %},
        carried: [] of Nil, channel: {{ channel }}, means: {{ means }},
        renamed_from: {{ renamed_from }}, subject: nil, tenanted: {{ tenanted }},
        older: {{ older }})
    end

    # `emit Renamed, name: name` in a service body records one of this context's events;
    # the service dispatches it when its transaction commits.
    #
    # @word behaviour | Records an event of the context from a service, dispatched on commit.
    # @usage emit EVENT[, FIELD: VALUE ...]
    # @in in the body of a service of a context
    # @guide c-sweettalk-services
    # @example
    #   context Dairy, means: "milk and its bottling" do
    #     event Opened, branch : String, means: "the dairy opened a new branch"
    #
    #     service open_branch(branch : String), means: "opens a branch and records it" do
    #       emit Opened, branch: branch
    #     end
    #   end
    macro emit(event, **fields)
      {% short = @type.name.split("::").last %}
      {% service = @def.is_a?(Def) && @def.name.stringify %}
      {% unless service && @type.has_constant?("SWEETTALK_SERVICE_#{service.upcase.id}") %}
        {% event.raise "emit belongs in a service body: a context emits #{event} from a " +
                       "service, as in service rename(name : String), means: \"…\" do … end, " +
                       "and an aggregate from a command" %}
      {% end %}
      {% found = event.is_a?(Path) && event.names.size == 1 && event.resolve? %}
      {% own = found && found.is_a?(TypeNode) && found < ::SweetTalk::Event &&
               found.name.stringify == "#{@type.name}::#{event}" %}
      {% unless own %}
        {% event.raise "#{short.id} emits only its own events, and #{event} is not one of " +
                       "them: an aggregate's event is emitted by its commands" %}
      {% end %}
      {% given = fields.map { |key, value| "#{key}: #{value}" }.join(", ") %}
      __sweettalk_events << {{ event }}.new({{ given.id }})
    end

    # `specification Dispatchable, on: Order, where: {state: :placed}, means: "…"` is a
    # rule an aggregate declared before it satisfies or not, stated once. `where:` takes
    # what `finds` takes, or specifications on the same aggregate joined by `&`, `|` and
    # `!`. It adds `Order#dispatchable?`, read in Crystal, and the same rule as a SugarORM
    # condition, read by PostgreSQL in `Order.all(satisfying: Dispatchable)` and in
    # `finds …, satisfying: Dispatchable`. `!` reads as `IS NOT TRUE`, so a NULL column
    # fails a rule and passes its negation in both readings.
    #
    # @word noun | Names a rule an aggregate satisfies or not, read in Crystal and in PostgreSQL.
    # @usage specification NAME, on: AGGREGATE, where: CONDITION[, assures: IDS], means: TEXT
    # @in in a context
    # @guide c-sweettalk-specifications
    # @option on | an aggregate of this context | - | The aggregate the rule is about, declared
    #   before the specification. Required.
    # @option where | a hash as finds takes, or specifications combined as and, or, not | - | The
    #   rule. Adds `NAME?` to the aggregate and a condition for `satisfying:`. Required.
    # @option means | text | - | What the rule says, in a line the glossary shows. Required.
    # @option assures | requirement id or list of ids, as "AC-12" | - | The requirement ids the
    #   specification answers, which the module lists in requirements.
    # @example
    #   context Cellar, means: "bottles laid down" do
    #     aggregate Bottle, means: "one bottle in the cellar" do
    #       has vintage : Int32
    #       moves laid >> opened
    #     end
    #
    #     specification Drunk, on: Bottle, where: {state: :opened},
    #       means: "a bottle that has been opened"
    #   end
    macro specification(name, on = nil, where = nil, means = nil, assures = nil, &block)
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
      ::SweetTalk.__sweettalk_assures("specification", {{ "specification #{name}" }}, {{ means }},
        {{ assures }}, {{ @type.name.stringify }}, {{ "#{@type.name}::#{name}" }},
        {{ "SWEETTALK_ASSURES_SPECIFICATION_#{name.stringify.upcase.id}" }})
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

    # Checks every `finds` and `counts` of this context's aggregates, projections and
    # processes when the context closes, whether or not anything calls them: each key
    # names a stored attribute or `state:` a declared state, each `order:` key `id` or an
    # attribute stored in one column, and `satisfying:` a specification on the same
    # aggregate.
    macro __sweettalk_check_queries
      {% depth = @type.name.split("::").size + 1 %}
      {% owners = ::SweetTalk::Aggregate.all_subclasses + ::SweetTalk::Projection.all_subclasses +
                  ::SweetTalk::Process.all_subclasses %}
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
            {% document = attribute && attribute[11] &&
                          attribute[11].starts_with?("::SugarORM::JSONB") %}
            {% if document %}
              {% raise "#{word.id} orders by #{key.id}, a JSON value, which #{short.id} cannot " +
                       "sort by: a document has no order; order by id, or by an attribute " +
                       "stored in one column" + at %}
            {% elsif !sortable %}
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
    #
    # @word boundary | Marks the one place where a context names another context or an outside
    #   system.
    # @usage border NAME[, outside: TEXT] do ... end
    # @in in a context
    # @guide c-sweettalk-contexts
    # @option outside | text | - | Says what an outside system is to this context, and makes the
    #   border a module that may name Caramel::Outbound and HTTP::Client. Without it, NAME is a
    #   context and the border holds the whenever and compensate lines that react to its events.
    # @example
    #   context Orchard, means: "the fruit we pick" do
    #     aggregate Crate, means: "one crate of fruit" do
    #       has fruit : String
    #       event Packed, means: "a crate was packed"
    #
    #       factory pack(fruit : String) do
    #         emit Packed
    #       end
    #     end
    #   end
    #
    #   context Cidery, means: "pressing fruit into cider" do
    #     aggregate Batch, means: "one pressing" do
    #       has crates : Int32
    #     end
    #
    #     border Orchard do
    #       whenever Orchard::Crate::Packed do |packed|
    #         Batch.create(crates: 1)
    #       end
    #     end
    #
    #     border Courier, outside: "the courier we ship cider with" do
    #       def self.book(batch : Int64) : Int32
    #         url = "https://courier.example/v1/bookings"
    #         Caramel::Outbound.post(url, HTTP::Headers.new, batch.to_s).status_code
    #       end
    #     end
    #   end
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
          {% attempts = nil %}
          {% backoff = nil %}
          {% base = nil %}
          {% after = nil %}
          {% for argument in (expression.named_args || [] of Nil) %}
            {% each = argument.value if argument.name.stringify == "each" %}
            {% attempts = argument.value if argument.name.stringify == "attempts" %}
            {% backoff = argument.value if argument.name.stringify == "backoff" %}
            {% base = argument.value if argument.name.stringify == "base" %}
            {% after = argument.value if argument.name.stringify == "after" %}
          {% end %}
          ::SweetTalk.__sweettalk_policy({{ @type }}, {{ expression.args[0] }}, {{ each }},
            {{ other }}, "context", nil, {{ attempts }}, {{ backoff }}, {{ base }}, {{ after }},
            {{ expression.block.args.splat }}) do
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
    # command that emitted the event commits. `attempts:`, `backoff:` and `base:` set its
    # retry rule for errors other than a refusal. `after: Sales` runs it once the named
    # projection's, process's or context's handler of the same event has committed.
    #
    # @word behaviour | Runs a block as a job after the command that emitted an event commits.
    # @usage whenever EVENT[, each: LIST][, attempts: N][, backoff: KIND][, base: SPAN]
    #   [, after: OWNER] do |EVENT_VAR| ... end
    # @in in a context or in a border of a context
    # @internal border
    # @guide c-sweettalk-events
    # @option each | symbol naming an Array field of the event | - | Runs one job per element of
    #   the list; the block takes the element as a second argument.
    # @option attempts | integer literal | Cold Brew's default rule | How many runs the job gets,
    #   the first included, for an error other than a refusal.
    # @option backoff | :exponential or :linear | Cold Brew's default rule | How the wait between
    #   runs grows.
    # @option base | a span, as 2.seconds | Cold Brew's default rule | The wait the backoff starts
    #   from.
    # @option after | name of a projection, process or context | - | Runs the job once that
    #   owner's handler of the same event has committed.
    # @example
    #   context Bistro, means: "tables in a dining room" do
    #     aggregate Table, means: "one table and its guests" do
    #       has party : Int32
    #       has greetings : Int32 = 0
    #       event Seated, means: "a party sat down"
    #
    #       factory seat(party : Int32) do
    #         emit Seated
    #       end
    #
    #       to greet do
    #         @greetings += 1
    #       end
    #     end
    #
    #     whenever Table::Seated, attempts: 3, backoff: :linear, base: 2.seconds do |seated|
    #       Table.find(seated.table_id).greet
    #     end
    #   end
    macro whenever(event, border = nil, each = nil, attempts = nil, backoff = nil, base = nil,
                   after = nil, &block)
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, {{ border }}, "context",
        nil, {{ attempts }}, {{ backoff }}, {{ base }}, {{ after }}, {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # `compensate Event do |event, refusal| … end` runs when the `whenever` before it for
    # the same event is refused.
    #
    # @word behaviour | Undoes the work of a context's policy when the handler is refused.
    # @usage compensate EVENT do |EVENT_VAR, REFUSAL_VAR| ... end
    # @in in a context or in a border of a context
    # @guide c-sweettalk-events
    # @example
    #   context Hatchery, means: "eggs and their hatching" do
    #     aggregate Clutch, means: "one clutch of eggs" do
    #       has eggs : Int32
    #       moves laid >> hatched, laid >> lost
    #       event Laid, means: "a clutch was laid"
    #
    #       factory lay(eggs : Int32) do
    #         emit Laid
    #       end
    #
    #       to hatch do
    #         hatched!
    #       end
    #
    #       to lose do
    #         lost!
    #       end
    #     end
    #
    #     whenever Clutch::Laid do |laid|
    #       Clutch.find(laid.clutch_id).hatch
    #     end
    #
    #     compensate Clutch::Laid do |laid, refusal|
    #       Clutch.find(laid.clutch_id).lose
    #     end
    #   end
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
    # types, services, units and calculations another context may name. Once a context
    # publishes, every other context names only those, and the events it reacts to.
    # `context` reads the list; this checks that each name is declared before it.
    #
    # @word boundary | Lists the types, services, units and calculations other contexts may name.
    # @usage publishes NAME[, NAME ...]
    # @in in a context
    # @guide c-sweettalk-published
    # @example
    #   context Greenhouse, means: "plants and their prices" do
    #     aggregate Plant, means: "one plant we grow" do
    #       has price : Int32
    #     end
    #
    #     service price_of(plant : Plant::Id), returns: Int32, means: "what one plant costs" do
    #       Plant.find(plant).price
    #     end
    #
    #     publishes Plant::Id, price_of
    #   end
    macro publishes(*names)
      {% short = @type.name.split("::").last %}
      {% for name in names %}
        {% if name.is_a?(Path) %}
          {% found = name.resolve? %}
          {% declared = found && found.name.starts_with?("#{@type.name}::") %}
        {% elsif name.is_a?(Call) && name.receiver.is_a?(Nop) && name.args.empty? %}
          {% declared = %w[SERVICE UNIT CALCULATION].any? do |kind|
               @type.has_constant?("SWEETTALK_#{kind.id}_#{name.name.upcase}")
             end %}
        {% else %}
          {% name.raise "publishes takes the context's types, services, units and " +
                        "calculations, as in publishes Cents, Tea::Id, price_of, not #{name}" %}
        {% end %}
        {% unless declared %}
          {% name.raise "#{short.id} publishes #{name}, which it does not declare: declare " +
                        "a type, a service, a unit or a calculation of that name before " +
                        "publishes" %}
        {% end %}
      {% end %}
    end
  end

  # `requirements "AC-01", "AC-02"`, before the first context, lists the requirement ids this
  # domain module answers to (ADR 0057). `SWEETTALK_REQUIREMENTS` records them; every
  # context and kernel copies the list, or nil, as it copies `SWEETTALK_TENANT`.
  #
  # @word setup | Lists the requirement ids a domain module answers to, before its first context.
  # @usage requirements ID[, ID ...]
  # @guide c-sweettalk-requirements
  # @example
  #   requirements "AC-21", "AC-22"
  #
  #   context Mintage, means: "coins struck at the mint" do
  #     aggregate Coin, means: "one coin struck" do
  #       has weight : Int32
  #       never "A coin has a weight.", assures: "AC-21" { weight <= 0 }
  #     end
  #   end
  macro requirements(*ids)
    {% if ids.empty? %}
      {% raise "requirements takes at least one requirement id, as in requirements \"AC-01\"" %}
    {% end %}
    {% seen = [] of Nil %}
    {% for id in ids %}
      {% unless id.is_a?(StringLiteral) %}
        {% id.raise "requirements takes requirement ids as text, as in requirements " +
                    "\"AC-01\", \"AC-02\", not #{id}" %}
      {% end %}
      {% unless id =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ %}
        {% id.raise "requirements takes ids of letters, digits, '.', '_' and '-', starting " +
                    "with a letter or a digit, not \"#{id.id}\"" %}
      {% end %}
      {% if seen.includes?(id) %}
        {% id.raise "requirements lists #{id.id} twice" %}
      {% end %}
      {% seen << id %}
    {% end %}
    {% if @type.has_constant?("SWEETTALK_REQUIREMENTS") %}
      {% ids[0].raise "requirements is declared twice in #{@type.name.id}: keep one" %}
    {% end %}
    {% earlier = ::SweetTalk::BoundedContext.includers
         .find(&.name.starts_with?("#{@type.name}::")) %}
    {% if earlier %}
      {% ids[0].raise "requirements comes after context #{earlier.name.split("::").last.id}: " +
                      "list the requirements before the contexts" %}
    {% end %}
    SWEETTALK_REQUIREMENTS = [{{ ids.splat }}]
  end

  # Checks `assures:` of a `never`, an `always`, a specification or a unit against the
  # requirements of the module that holds the context *home*, and records
  # `{kind, text, [ids], owner}` as the constant *constant* (ADR 0057). *what* names the
  # declaration in a refusal.
  macro __sweettalk_assures(kind, what, text, ids, home, owner, constant)
    {% unless ids.is_a?(NilLiteral) %}
      {% shaped = ids.is_a?(StringLiteral) ||
                  (ids.is_a?(ArrayLiteral) && ids.size > 0 && ids.all?(&.is_a?(StringLiteral))) %}
      {% unless shaped %}
        {% ids.raise "#{what.id} takes assures: a requirement id or a list of them, as in " +
                     "assures: \"AC-12\" or assures: [\"AC-12\", \"D04\"], not #{ids}" %}
      {% end %}
      {% listed = ids.is_a?(ArrayLiteral) ? ids : [ids] %}
      {% holder = ::SweetTalk::BoundedContext.includers.find do |context|
           home == context.name.stringify || home.starts_with?("#{context.name}::")
         end %}
      {% key = "SWEETTALK_REQUIREMENTS" %}
      {% declared = holder && holder.has_constant?(key) ? holder.constant(key) : nil %}
      {% parts = holder ? holder.name.split("::")[0..-2] : [] of Nil %}
      {% module_name = parts.empty? ? "the program" : parts.join("::") %}
      {% for id in listed %}
        {% if !declared %}
          {% ids.raise "#{what.id} assures #{id.id}, but #{module_name.id} declares no " +
                       "requirements: add requirements \"#{id.id}\" before its first context" %}
        {% elsif !declared.includes?(id) %}
          {% ids.raise "#{what.id} assures #{id.id}, which #{module_name.id} does not list " +
                       "in requirements; it lists #{declared.join(", ").id}: add #{id.id} " +
                       "there, or correct the id" %}
        {% end %}
      {% end %}
      {{ constant.id }} = { {{ kind }}, {{ text }}, [{{ listed.splat }}], {{ owner }} }
    {% end %}
  end

  # `tenant App::Account`, before the first context, names the tenant model of a program
  # that requires caramel/tenancy: the model the routes' `tenant` block names.
  # `SWEETTALK_TENANT` records {the model's path, the attribute named after its last
  # segment}; every context copies it unless it says `central: true`.
  #
  # @word setup | Names the tenant model of a program that requires caramel/tenancy.
  # @usage tenant MODEL
  # @guide c-sweettalk-tenancy
  # @example requires caramel/tenancy
  #   struct Account < SugarORM::Schema
  #     schema "accounts" do
  #       field id : Int64, primary: true
  #       field slug : String
  #       index :slug, unique: true
  #     end
  #   end
  #
  #   struct Home < Caramel::Action
  #     ingress open: true
  #
  #     contract do
  #     end
  #
  #     def handle(contract : Contract)
  #       page "Home", "<p>Home</p>"
  #     end
  #   end
  #
  #   Caramel::Router.draw do
  #     tenant Account, by: :slug do
  #       get "/", Home
  #     end
  #   end
  #
  #   tenant Account
  #
  #   context Greengrocer, means: "produce each tenant sells" do
  #     aggregate Crate, means: "one crate of produce on a tenant's shelf" do
  #       has fruit : String
  #     end
  #   end
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
  # `shares: Money` names the kernels it shares, declared before it. `event_log: true`
  # keeps every event of the context, and of the kernels it shares, in `<context>_events`.
  # `event_log: 90.days` keeps an event that many days, pruned hourly by Cold Brew's
  # scheduler.
  #
  # @word noun | Declares a bounded context: a module with its own vocabulary, its aggregates and
  #   its rules.
  # @usage context NAME[, follows: CONTEXT][, shares: KERNEL][, central: true]
  #   [, subdomain: KIND][, event_log: LOG][, renamed_from: OLD], means: TEXT do ... end
  # @guide c-sweettalk-contexts
  # @option follows | a context name, or a tuple of them, as {Catalogue, Pricing} | - | Adopts
  #   the types of the named contexts as they are. Each must be named outside a border.
  # @option shares | a kernel name, or a list of them | - | The kernels this context shares,
  #   declared before it and listing it in their shared_by:.
  # @option means | text | - | What the context is, in a line the glossary shows. Required.
  # @option renamed_from | the old name, as a constant | - | Keeps the tables and channels of the
  #   old name, so no data moves. Naming the context itself is refused.
  # @option central | true | the rows belong to the tenant | Shares the context's rows between
  #   every tenant. Only in a program that requires caramel/tenancy.
  # @option subdomain | :core, :supporting or :generic | - | Which part of the business the
  #   context serves, shown on every glossary term. It changes no rule.
  # @option event_log | true, or a number of days or weeks, as 90.days | no log | Keeps every
  #   event of the context, and of the kernels it shares, in `<context>_events`; a number of
  #   days or weeks prunes the rows older than that.
  # @example
  #   context Fishmonger, subdomain: :core, event_log: true,
  #     means: "fish sold at the counter" do
  #     aggregate Catch, means: "one catch landed on the quay" do
  #       has species : String
  #     end
  #   end
  macro context(name, follows = nil, shares = nil, means = nil, renamed_from = nil,
                central = nil, subdomain = nil, event_log = nil, &block)
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
    {% days = nil %}
    {% if event_log.is_a?(Call) && event_log.receiver.is_a?(NumberLiteral) &&
            event_log.args.empty? && event_log.receiver.stringify =~ /\A[1-9]\d*\z/ %}
      {% count = event_log.receiver.stringify.to_i %}
      {% days = count if %w[day days].includes?(event_log.name.stringify) %}
      {% days = count * 7 if %w[week weeks].includes?(event_log.name.stringify) %}
    {% end %}
    {% unless event_log.is_a?(NilLiteral) || (event_log.is_a?(BoolLiteral) && event_log) || days %}
      {% event_log.raise "context #{name} takes event_log: true, which keeps every event in " +
                         "#{name.stringify.underscore.id}_events, or a whole number of days or " +
                         "weeks to keep each, as in event_log: 90.days, not event_log: " +
                         "#{event_log}" %}
    {% end %}
    {% subdomains = %w[core supporting generic] %}
    {% unless subdomain.is_a?(NilLiteral) ||
                (subdomain.is_a?(SymbolLiteral) && subdomains.includes?(subdomain.id.stringify)) %}
      {% subdomain.raise "context #{name} takes subdomain: :core, :supporting or :generic, " +
                         "not subdomain: #{subdomain}" %}
    {% end %}
    {% tenant = @type.has_constant?("SWEETTALK_TENANT") && !central &&
                @type.constant("SWEETTALK_TENANT") %}
    __sweettalk_shared("context", {{ name }}, {{ shares }})
    ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
    {% body = block ? block.body : nil %}
    {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
    {% followed = [] of Nil %}
    {% followed = [follows] unless follows.is_a?(NilLiteral) %}
    {% followed = follows if follows.is_a?(TupleLiteral) %}
    {% shared = [] of Nil %}
    {% shared = [shares] unless shares.is_a?(NilLiteral) %}
    {% shared = shares if shares.is_a?(ArrayLiteral) %}
    {% shared = shared.select { |path| path.is_a?(Path) } %}
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
    # A command, a factory or a unit may run dry in a preview that rolls back, and a call to
    # an outside system cannot be taken back, so none names an outside border (ADR 0060).
    {% systems = outsides.map(&.args[0].names.last.stringify) %}
    {% bodies = [] of Nil %}
    {% for node in (systems.empty? ? [] of Nil : expressions) %}
      {% if node.is_a?(Call) && node.name == "unit" && !node.block.is_a?(Nop) &&
              node.args[0].is_a?(Call) %}
        {% bodies << {"unit #{name}.#{node.args[0].name}", node.block.body} %}
      {% elsif node.is_a?(Call) && node.name == "aggregate" && !node.block.is_a?(Nop) %}
        {% inner = node.block.body %}
        {% for step in (inner.is_a?(Expressions) ? inner.expressions : [inner]) %}
          {% if step.is_a?(Call) && %w[to factory].includes?(step.name.stringify) &&
                  !step.block.is_a?(Nop) && step.args[0].is_a?(Call) %}
            {% joint = step.name == "to" ? "#" : "." %}
            {% what = step.name == "to" ? "command" : "factory" %}
            {% bodies << {"#{what.id} #{node.args[0]}#{joint.id}#{step.args[0].name}",
                          step.block.body} %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    {% for checked in bodies %}
      {% inner = checked[1] %}
      {% for statement in (inner.is_a?(Expressions) ? inner.expressions : [inner]) %}
        {% padded = " " + statement.stringify.gsub(/[^\w:.]/, " ") %}
        {% for system in systems %}
          {% if padded.includes?(" #{system.id}.") || padded.includes?(" #{system.id}::") %}
            {% statement.raise "#{checked[0].id} names #{system.id}, a border with an outside " +
                               "system: a preview runs it and rolls back, and a call outside " +
                               "cannot be taken back; call #{system.id} from a whenever on its " +
                               "event, or before the change" %}
          {% end %}
        {% end %}
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
      # The requirement ids the module that holds this context lists, or nil (ADR 0057)
      {% key = "SWEETTALK_REQUIREMENTS" %}
      SWEETTALK_REQUIREMENTS = {{ @type.has_constant?(key) ? @type.constant(key) : nil }}
      SWEETTALK_CENTRAL = {{ central ? true : false }}
      # Whether `<context>_events` keeps every event of this context (ADR 0048)
      SWEETTALK_EVENT_LOG = {{ event_log ? true : false }}
      # How many days the log keeps an event, or nil to keep every event (ADR 0051)
      SWEETTALK_EVENT_DAYS = {{ days }}
      SWEETTALK_SUBDOMAIN = {{ subdomain.is_a?(NilLiteral) ? nil : subdomain.id.stringify }}
      SWEETTALK_FOLLOWS = [{{ followed.map(&.names.last.stringify).splat }}] of String
      SWEETTALK_SHARES  = [{{ shared.map(&.names.last.stringify).splat }}] of String
      # The contexts and kernels that share this module when it is a kernel; nil for a context
      SWEETTALK_SHARED_BY = nil
      SWEETTALK_TEXT    = {{ pieces.join("\n") }}
      # Where the context is declared, for the context map's refusals
      SWEETTALK_AT      = {{ "#{name.filename.id}:#{name.line_number}:#{name.column_number}" }}
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

      ::SweetTalk.__sweettalk_event_log(::{{ prefix.id }}{{ name }})
      ::SweetTalk.__sweettalk_operations(::{{ prefix.id }}{{ name }})
      __sweettalk_check_queries
    end
  end
end
