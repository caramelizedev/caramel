# Money: `currencies %w[USD EUR], means: "…"` and `quote Rate, rounding: :half_up, means:
# "…"` in a context or a kernel, and `allocation` in a context (ADR 0063). Opt-in, a module
# under ADR 0061: it requires caramel/sweet_talk/decimal, and a program that declares no
# currency holds none of this file.
require "./decimal"
require "./money/iso4217"
require "./money/allocation"

module SweetTalk
  # The words every currency, amount and rate shares.
  module Money
    # The ways a quotient becomes a whole count of minor units: to the nearest, a half away
    # from zero (`half_up`) or to the even neighbour (`half_even`), or toward zero (`down`)
    # or away from it (`up`).
    ROUNDINGS = %w[half_up half_even down up]

    # The most minor-unit digits a currency outside ISO 4217 may declare.
    MOST_DIGITS = 9

    # *numerator* / *denominator* as a whole count, rounded as *rounding* says; refuses a
    # count beyond `Int64`.
    def self.round(numerator : BigInt, denominator : BigInt, rounding : Symbol) : Int64
      negative = (numerator < 0) != (denominator < 0)
      whole, rest = numerator.abs.divmod(denominator.abs)
      whole += 1 if away?(whole, rest, denominator.abs, rounding)
      fit(negative ? -whole : whole)
    end

    # Whether the magnitude *whole*, with *rest* left over *denominator*, moves away from
    # zero.
    private def self.away?(whole : BigInt, rest : BigInt, denominator : BigInt,
                           rounding : Symbol) : Bool
      half = rest * 2 <=> denominator
      case rounding
      when :half_up   then half >= 0
      when :half_even then half > 0 || (half == 0 && whole.odd?)
      when :down      then false
      when :up        then rest > 0
      else                 raise ArgumentError.new("rounding #{rounding} is not #{ROUNDINGS}")
      end
    end

    # Refuses two amounts of different currencies, for `same`.
    def self.mismatch(first : Units, second : Units) : NoReturn
      raise Refusal.new("An amount in #{first.code} and one in #{second.code} cannot be " \
                        "combined")
    end

    # *count* as an `Int64`, or a refusal: no amount counts beyond it.
    def self.fit(count : BigInt) : Int64
      unless Int64::MIN <= count <= Int64::MAX
        raise Refusal.new("An amount of #{count} minor units is beyond what can be counted")
      end
      count.to_i64
    end

    # The minor units *text* writes in a currency of *exponent* digits, refusing more
    # decimals than it has.
    def self.units(code : String, exponent : Int32, text : String) : Int64
      digits, decimals = split(code, text)
      if decimals.size > exponent
        raise Refusal.new("#{code} keeps #{exponent} decimals, not #{text}")
      end
      fit(BigInt.new(digits + decimals.ljust(exponent, '0')))
    end

    # The minor units *text* writes, rounded to *exponent* digits as *rounding* says.
    def self.rounded(code : String, exponent : Int32, text : String, rounding : Symbol) : Int64
      digits, decimals = split(code, text)
      numerator = BigInt.new(digits + decimals)
      round(numerator * BigInt.new(10) ** exponent, BigInt.new(10) ** decimals.size, rounding)
    end

    # The sign and whole digits of *text*, and its decimals, or a refusal.
    private def self.split(code : String, text : String) : {String, String}
      unless text.matches?(::SugarORM::Decimal::TEXT)
        raise Refusal.new("#{code} must be a decimal written with digits and a point, as " \
                          "in 12.50, not #{text}")
      end
      point = text.index('.')
      return {text, ""} unless point
      {text[0, point], text[point + 1..]}
    end

    # *raw* minor units as plain digits with *exponent* decimals: `-12.05`.
    def self.text(raw : Int64, exponent : Int32) : String
      digits = raw.abs.to_s.rjust(exponent + 1, '0')
      sign = raw < 0 ? "-" : ""
      return "#{sign}#{digits}" if exponent == 0
      "#{sign}#{digits[0, digits.size - exponent]}.#{digits[-exponent..]}"
    end

    # A rate's exact fraction from decimal text, `1.0851`, or a refusal.
    def self.fraction(name : String, text : String) : BigRational
      unless text.matches?(::SugarORM::Decimal::TEXT)
        raise Refusal.new("#{name} must be a decimal written with digits and a point, as " \
                          "in 1.0851, not #{text}")
      end
      decimals = text.index('.').try { |point| text.size - point - 1 } || 0
      BigRational.new(BigInt.new(text.delete('.')), BigInt.new(10) ** decimals)
    end

    # What every `Minor(C)` holds and shows: a signed count of the minor units of the
    # currency C stands for.
    module Units
      getter raw : Int64

      abstract def code : String
      abstract def exponent : Int32

      def zero? : Bool
        raw == 0
      end

      def positive? : Bool
        raw > 0
      end

      def negative? : Bool
        raw < 0
      end

      # The amount as a decimal of its currency's units: 1234 cents is 12.34.
      def to_decimal : BigDecimal
        BigDecimal.new(raw.to_big_i, exponent.to_u64)
      end

      # Plain digits with the currency's decimals, `12.30`, without the code.
      def text : String
        Money.text(raw, exponent)
      end

      # `12.30 USD`.
      def to_s(io : IO) : Nil
        io << text << ' ' << code
      end

      # The amount *rate* gives for this one, rounded as its quote declares.
      def convert(rate)
        rate.__sweettalk_convert(self)
      end

      # Written as one JSON fact: `{"currency": "USD", "raw": 1230}`.
      def __sweettalk_pack(json : JSON::Builder) : Nil
        json.object do
          json.field("currency", code)
          json.field("raw", raw)
        end
      end

      def to_json(json : JSON::Builder) : Nil
        __sweettalk_pack(json)
      end
    end
  end

  def self.pack(json : JSON::Builder, value : Money::Units) : Nil
    value.__sweettalk_pack(json)
  end

  module BoundedContext
    # `currencies %w[USD EUR UZS], means: "…"` is the closed set of currencies a domain
    # holds. It declares the value `Currency`, a code of the list checked as ADR 0040's
    # closed sets are, with a marker type for each member, `Currency::USD`; `Minor(C)`, a
    # signed count of C's minor units that adds and subtracts only its own currency;
    # `Amount`, the union of every member's `Minor`; and `Amounts`, which builds the member
    # a currency names from its count. Each code's minor units come from ISO 4217 list one;
    # a code outside it, or one it marks N.A., takes `exponent: {XAU: 4}`. `same(a, b) { |x,
    # y| … }` runs the block on two amounts of one currency or refuses, and `by_currency`
    # totals amounts per currency.
    macro currencies(codes, exponent = nil, means = nil)
      {% here = "#{@type.name.id}" %}
      {% shape = "currencies takes a list of ISO 4217 codes, as in currencies %w[USD EUR], " +
                 "not #{codes}" %}
      {% unless codes.is_a?(ArrayLiteral) && codes.size > 0 &&
                  codes.all? { |code| code.is_a?(StringLiteral) && code =~ /\A[A-Z]{3}\z/ } %}
        {% codes.raise shape %}
      {% end %}
      {% names = codes.map(&.id.stringify) %}
      {% unless names.uniq.size == names.size %}
        {% codes.raise "currencies lists a code twice in #{codes}: list each once" %}
      {% end %}
      {% means.raise "currencies needs a meaning: add means: \"…\", the line Currency's " +
                     "glossary entry shows" if means.is_a?(NilLiteral) %}
      {% @type.raise "#{here.id} declares currencies twice: list every code in one " +
                     "currencies" if @type.has_constant?("Currency") %}
      {% given = {} of Nil => Nil %}
      {% unless exponent.is_a?(NilLiteral) %}
        {% unless exponent.is_a?(NamedTupleLiteral) || exponent.is_a?(HashLiteral) %}
          {% exponent.raise "currencies takes exponent: the minor units of each code ISO " +
                            "4217 does not give, as in exponent: {XAU: 4}, not #{exponent}" %}
        {% end %}
        {% for key, digits in exponent %}
          {% code = key.id.stringify %}
          {% unless names.includes?(code) %}
            {% exponent.raise "currencies gives exponent: for #{code.id}, which it does not " +
                              "list: add #{code.id} to the list or drop its exponent" %}
          {% end %}
          {% unless digits.is_a?(NumberLiteral) && digits >= 0 &&
                      digits <= ::SweetTalk::Money::MOST_DIGITS %}
            {% exponent.raise "currencies gives #{code.id} #{digits} minor-unit digits: " +
                              "give a whole number from 0 to " +
                              "#{::SweetTalk::Money::MOST_DIGITS}" %}
          {% end %}
          {% if ::SweetTalk::Money::ISO4217[code] %}
            {% exponent.raise "currencies gives exponent: for #{code.id}, which ISO 4217 " +
                              "counts in #{::SweetTalk::Money::ISO4217[code]} minor-unit " +
                              "digits: drop its exponent" %}
          {% end %}
          {% given[code] = digits %}
        {% end %}
      {% end %}
      {% exponents = {} of Nil => Nil %}
      {% for code in names %}
        {% digits = ::SweetTalk::Money::ISO4217[code] %}
        {% digits = given[code] if digits.is_a?(NilLiteral) %}
        {% if digits.is_a?(NilLiteral) %}
          {% marked = ::SweetTalk::Money::ISO4217_WITHOUT_UNITS.includes?(code) %}
          {% said = "does not list #{code.id}" %}
          {% said = "marks #{code.id} N.A., with no minor unit" if marked %}
          {% codes.raise "currencies lists #{code.id}, but ISO 4217 #{said.id}: give its " +
                         "minor-unit digits, as in exponent: {#{code.id}: 2}" %}
        {% end %}
        {% exponents[code] = digits %}
      {% end %}
      # A code becomes `Currency.usd` and `usd?` unless that would hide a method every
      # value or object has, as `all` and `try` would for ALL and TRY.
      {% taken = %w[all new allocate includes zero from_field name hash class inspect] %}
      {% taken = taken + %w[to_s object_id itself dup clone tap try not_nil pretty_inspect] %}
      {% taken = taken + %w[nil same equal is_a responds_to in unsafe_as of exponent] %}
      {% quoted = names.map { |code| "'#{code.id}'" } %}
      {% members = names.map { |code| "Minor(Currency::#{code.id})" } %}

      struct Currency < ::SweetTalk::Value
        include Comparable(Currency)
        include ::Caramel::FieldValue(String)

        SWEETTALK_MEANS = {{ means }}
        SWEETTALK_WRAPS = "String"
        SWEETTALK_CODEC = nil
        ::SweetTalk.__sweettalk_hashed(SWEETTALK_CHECK,
          {"column", "one_of_@digest", {{ "IN (#{quoted.join(", ").id})" }}},
          {{ names.sort.join(",") }})
        SWEETTALK_ONE_OF = {{ names }}
        # Each code's minor-unit digits.
        SWEETTALK_EXPONENTS = {{ exponents }}

        {% for code in names %}
          # The marker type of {{ code.id }}, the C of `Minor(Currency::{{ code.id }})`.
          abstract struct {{ code.id }}
            CODE     = {{ code }}
            EXPONENT = {{ exponents[code] }}
            # {what builds any amount of these currencies, the currency value}, which
            # `has` and event fields read to store and load a `Minor` of this currency.
            SWEETTALK_LOADER = { {{ "::#{here.id}::Amounts" }}, {{ "::#{here.id}::Currency" }} }
          end
        {% end %}

        getter raw : String

        def initialize(@raw : String)
          unless SWEETTALK_ONE_OF.includes?(@raw)
            raise ::SweetTalk::Refusal.new({{ "Currency must be one of #{names.join(", ").id}" }})
          end
        end

        # Every currency, in the order the list gives.
        def self.all : Array(self)
          SWEETTALK_ONE_OF.map { |code| new(code) }
        end

        # Whether *raw* is one of the codes.
        def self.includes?(raw : String) : Bool
          SWEETTALK_ONE_OF.includes?(raw)
        end

        {% for code in names %}
          {% unless taken.includes?(code.downcase) %}
            def self.{{ code.downcase.id }} : self
              new({{ code }})
            end

            def {{ code.downcase.id }}? : Bool
              @raw == {{ code }}
            end
          {% end %}
        {% end %}

        # The digits after the point this currency counts in.
        def exponent : Int32
          SWEETTALK_EXPONENTS[@raw]
        end

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

      # A signed count of the minor units of the currency C marks, such as
      # `Minor(Currency::USD)`. `+`, `-` and `<=>` take the same currency only.
      struct Minor(C)
        include ::SweetTalk::Money::Units
        include Comparable(self)

        def initialize(@raw : Int64)
        end

        def self.zero : self
          new(0_i64)
        end

        # The count *text* writes in C's units, `12.30`; refuses more decimals than C has.
        def self.parse(text : String) : self
          new(::SweetTalk::Money.units(C::CODE, C::EXPONENT, text))
        end

        # The count *text* writes, rounded to C's units as *rounding* says, for imports.
        def self.round(text : String, *, rounding : Symbol) : self
          new(::SweetTalk::Money.rounded(C::CODE, C::EXPONENT, text, rounding))
        end

        # The member a stored currency and count give; refuses another currency.
        def self.new(*, currency : Currency, raw : Int64) : self
          unless currency.raw == C::CODE
            raise ::SweetTalk::Refusal.new("#{currency} is not #{C::CODE}")
          end
          new(raw)
        end

        # The amount an optional attribute stores: nil when both columns are nil.
        def self.__sweettalk_from_columns(*, currency : String?, raw : Int64?) : self?
          return nil if currency.nil? && raw.nil?
          new(currency: Currency.new(currency.not_nil!), raw: raw.not_nil!)
        end

        def self.__sweettalk_from_json(any : JSON::Any) : self
          new(currency: Currency.new(any["currency"].as_s), raw: any["raw"].as_i64)
        end

        def code : String
          C::CODE
        end

        def exponent : Int32
          C::EXPONENT
        end

        def currency : Currency
          Currency.new(C::CODE)
        end

        def +(other : self) : self
          self.class.new(raw + other.raw)
        end

        def -(other : self) : self
          self.class.new(raw - other.raw)
        end

        def - : self
          self.class.new(-raw)
        end

        def *(times : Int::Primitive) : self
          self.class.new(raw * times)
        end

        def abs : self
          self.class.new(raw.abs)
        end

        def <=>(other : self)
          raw <=> other.raw
        end
      end

      # An amount in any of the currencies: the union of their `Minor`s.
      alias Amount = {{ members.join(" | ").id }}

      # Builds the `Minor` a currency names, for amounts whose currency is data.
      module Amounts
        # The member *currency* names, holding *raw* minor units.
        def self.new(*, currency : Currency, raw : Int64) : Amount
          case currency.raw
          {% for code in names %}
          when {{ code }} then Minor(Currency::{{ code.id }}).new(raw)
          {% end %}
          else raise ::SweetTalk::Refusal.new("Currency must be one of {{ names.join(", ").id }}")
          end
        end

        # The amount *text* writes in *currency*; refuses more decimals than it has.
        def self.parse(text : String, currency : Currency) : Amount
          new(currency: currency,
            raw: ::SweetTalk::Money.units(currency.raw, currency.exponent, text))
        end

        # The amount *text* writes, rounded to *currency*'s units as *rounding* says.
        def self.round(text : String, currency : Currency, *, rounding : Symbol) : Amount
          new(currency: currency,
            raw: ::SweetTalk::Money.rounded(currency.raw, currency.exponent, text, rounding))
        end

        # The amount an optional attribute stores: nil when both columns are nil.
        def self.__sweettalk_from_columns(*, currency : String?, raw : Int64?) : Amount?
          return nil if currency.nil? && raw.nil?
          new(currency: Currency.new(currency.not_nil!), raw: raw.not_nil!)
        end

        def self.__sweettalk_from_json(any : JSON::Any) : Amount
          new(currency: Currency.new(any["currency"].as_s), raw: any["raw"].as_i64)
        end
      end

      # Runs the block on *first* and *second* as one currency's `Minor`, and returns what it
      # returns; refuses two currencies.
      macro same(first, second, &block)
        \{% unless block && block.args.size == 2 %}
          \{% raise "same takes a block of two amounts, as in same(a, b) { |x, y| x + y }" %}
        \{% end %}
        \%first = \{{ first }}
        \%second = \{{ second }}
        case \%first
        {% for code in names %}
        when ::{{ here.id }}::Minor(::{{ here.id }}::Currency::{{ code.id }})
          unless \%second.is_a?(::{{ here.id }}::Minor(::{{ here.id }}::Currency::{{ code.id }}))
            ::SweetTalk::Money.mismatch(\%first, \%second)
          end
          \{{ block.args[0] }} = \%first
          \{{ block.args[1] }} = \%second
          \{{ block.body }}
        {% end %}
        else
          raise ArgumentError.new({{ "same takes two amounts of #{here.id}" }})
        end
      end

      # The total of each currency among *amounts*.
      def self.by_currency(amounts : Enumerable) : Hash(Currency, Amount)
        totals = {} of Currency => Amount
        amounts.each do |amount|
          held = totals[amount.currency]?
          total = held ? same(held, amount) { |x, y| (x + y).as(Amount) } : amount
          totals[amount.currency] = total
        end
        totals
      end
    end

    # `quote Rate, rounding: :half_up, means: "…"` is a rate of exchange between two of the
    # currencies declared before it: an exact fraction, the day it was quoted for, and its
    # source, stored one column per part. `Rate.parse("1.0851", from:, to:, day:, source:)`
    # reads it exactly, `amount.convert(rate)` gives the amount in the other currency
    # rounded as `rounding:` says (`half_up`, `half_even`, `down` or `up`), and `inverse`
    # and `through` give exact cross rates. A day's window, a fallback and an override are
    # the application's.
    macro quote(name, rounding = nil, means = nil)
      {% unless name.is_a?(Path) && name.names.size == 1 %}
        {% name.raise "quote takes the name of a rate, as in quote Rate, rounding: :half_up, " +
                      "means: \"…\", not #{name}" %}
      {% end %}
      {% rounds = ::SweetTalk::Money::ROUNDINGS %}
      {% unless rounding.is_a?(SymbolLiteral) && rounds.includes?(rounding.id.stringify) %}
        {% target = rounding.is_a?(NilLiteral) ? name : rounding %}
        {% target.raise "quote #{name} takes rounding: :half_up, :half_even, :down or :up, how " +
                        "a converted amount becomes whole minor units, not #{rounding}" %}
      {% end %}
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", the line " +
                    "its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% unless @type.has_constant?("Currency") &&
                  @type.constant("Currency").has_constant?("SWEETTALK_EXPONENTS") %}
        {% name.raise "quote #{name} converts between currencies: declare currencies " +
                      "%w[…] before it in #{@type.name.id}" %}
      {% end %}
      {% day = "#{name.id}Day".id %}
      value {{ day }}, Date, means: {{ "the day a #{name.id} was quoted for" }}

      value {{ name }}, means: {{ means }} do
        part from : Currency
        part to : Currency
        part numerator : Int64
        part denominator : Int64
        part day : {{ day }}
        part source : String

        never {{ "A #{name.id} converts between two currencies at a fraction above zero" }} do
          from == to || numerator <= 0 || denominator <= 0
        end
      end

      struct {{ name }}
        SWEETTALK_ROUNDING = {{ rounding }}

        # The rate *text* writes, `1.0851` units of *to* for one of *from*, kept exact.
        def self.parse(text : String, *, from : Currency, to : Currency, day : {{ day }},
                       source : String) : self
          fraction = ::SweetTalk::Money.fraction({{ name.stringify }}, text)
          of(fraction, from: from, to: to, day: day, source: source)
        end

        # The rate *fraction* gives, in lowest terms; refuses one too large to store.
        def self.of(fraction : BigRational, *, from : Currency, to : Currency,
                    day : {{ day }}, source : String) : self
          unless fraction.numerator.abs <= Int64::MAX && fraction.denominator <= Int64::MAX
            raise ::SweetTalk::Refusal.new(
              {{ "A #{name.id} is kept as two 64-bit whole numbers, and " }} \
              "#{fraction} needs more")
          end
          new(from: from, to: to, numerator: fraction.numerator.to_i64,
            denominator: fraction.denominator.to_i64, day: day, source: source)
        end

        # Units of `to` for one unit of `from`, exactly.
        def fraction : BigRational
          BigRational.new(numerator, denominator)
        end

        # The same quote read the other way.
        def inverse : self
          self.class.of(1 / fraction, from: to, to: from, day: day, source: source)
        end

        # The cross rate from `from` to *other*'s `to`, through this rate's `to`: exact, of
        # one day, and from both sources.
        def through(other : self) : self
          unless to == other.from
            raise ::SweetTalk::Refusal.new(
              "A #{from} to #{to} rate does not lead through one from #{other.from}")
          end
          unless day == other.day
            raise ::SweetTalk::Refusal.new(
              "A cross rate joins rates of one day, not #{day} and #{other.day}")
          end
          joined = source == other.source ? source : "#{source}, #{other.source}"
          self.class.of(fraction * other.fraction, from: from, to: other.to, day: day,
            source: joined)
        end

        # *amount* in `to`, rounded as the quote declares; refuses an amount in another
        # currency than `from`.
        def __sweettalk_convert(amount : ::SweetTalk::Money::Units) : Amount
          unless amount.code == from.raw
            raise ::SweetTalk::Refusal.new(
              {{ "This #{name.id} converts " }} + "#{from}, not #{amount.code}")
          end
          ten = BigInt.new(10)
          numerator = amount.raw.to_big_i * self.numerator * ten ** to.exponent
          denominator = self.denominator.to_big_i * ten ** from.exponent
          raw = ::SweetTalk::Money.round(numerator, denominator, SWEETTALK_ROUNDING)
          Amounts.new(currency: to, raw: raw)
        end
      end
    end
  end
end
