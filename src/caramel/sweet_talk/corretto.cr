# What `Corretto.property` draws SweetTalk's types from, and how it reads their errors
# (ADR 0062 decision 7). A spec requires this file, after the domain, to run a property on
# a calculation: it gives each value declared before it its generator, the `corretto_draw`
# of ADR 0010 decision 11, names `SweetTalk::Refusal` as outside the domain, and lets
# `SweetTalk::Broken` say what failed.
require "../corretto/property"
require "../sweet_talk"

module SweetTalk
  # How far the drawn values reach, and the raw types they wrap.
  module Drawn
    # Whole digits a decimal reaches past an open side, at most: up to 999,999.99…
    DECIMAL_DIGITS = 6
    # Days drawn after FIRST_DAY, 2000-01-01 to 2040-12-31
    DAYS      = 14_975
    FIRST_DAY = {2000, 1, 1}
    # The raw types whose values are drawn: a whole number, text, a day or a decimal
    WRAPS = ["Int32", "Int64", "String", "::SugarORM::Date", "::BigDecimal"]
  end

  abstract struct Value
    # A value of this type, drawn from what it declares: its bounds, its `one_of:` members,
    # its day, or its decimal precision, scale and bounds.
    def self.__sweettalk_draw(random : ::Random) : self
      {% begin %}
        {% wraps = @type.constant("SWEETTALK_WRAPS") %}
        {% if wraps == "Int32" || wraps == "Int64" %}
          {% bounds = @type.constant("SWEETTALK_BOUNDS") %}
          {% least = bounds[0].is_a?(NilLiteral) ? "nil" : "(#{bounds[0].id}).to_i64" %}
          {% most = bounds[1].is_a?(NilLiteral) ? "nil" : "(#{bounds[1].id}).to_i64" %}
          new(::Corretto::Property.whole(random, {{ least.id }}, {{ most.id }}))
        {% elsif wraps == "String" && @type.has_constant?("SWEETTALK_ONE_OF") %}
          new(::{{ @type }}::SWEETTALK_ONE_OF.sample(random))
        {% elsif wraps == "String" %}
          new(::Corretto::Property.text(random))
        {% elsif wraps == "::SugarORM::Date" %}
          new(::SugarORM::Date.new(*Drawn::FIRST_DAY).plus_days(random.rand(0..Drawn::DAYS)))
        {% elsif wraps == "::BigDecimal" %}
          scale = ::{{ @type }}::SWEETTALK_SCALE
          unit = ::BigInt.new(10) ** scale
          digits = {::{{ @type }}::SWEETTALK_PRECISION - scale, Drawn::DECIMAL_DIGITS}.min
          reach = ::BigInt.new(10) ** digits * unit - 1
          {% if @type.has_constant?("SWEETTALK_LEAST") %}
            least = (::{{ @type }}::SWEETTALK_LEAST * unit).to_big_i
          {% else %}
            least = nil
          {% end %}
          {% if @type.has_constant?("SWEETTALK_MOST") %}
            most = (::{{ @type }}::SWEETTALK_MOST * unit).to_big_i
          {% else %}
            most = nil
          {% end %}
          low = least || (most ? most - reach : -reach)
          high = most || (least ? least + reach : reach)
          span = {high - low, ::BigInt.new(Int64::MAX)}.min.to_i64
          units = low + ::BigInt.new(::Corretto::Property.edge(random, 0_i64, span))
          new(::BigDecimal.new(units, scale.to_u64))
        {% else %}
          {% raise "Corretto.property cannot draw #{@type}, a value that wraps #{wraps.id}" %}
        {% end %}
      {% end %}
    end
  end

  abstract struct Composite
    # A value of this type, each part drawn from its own type.
    def self.__sweettalk_draw(random : ::Random) : self
      {% begin %}
        {% parts = @type.constants.select(&.starts_with?("SWEETTALK_PART_"))
             .map { |constant| @type.constant(constant) } %}
        new(
          {% for part in parts %}
            {{ part[0].id }}: ::Corretto::Property.draw({{ parse_type(part[2]) }}, random),
          {% end %}
        )
      {% end %}
    end
  end

  {% if ::SweetTalk::BoundedContext.includers.empty? %}
    {% raise "require \"caramel/sweet_talk/corretto\" after the domain: it gives the " +
             "values declared before it their generators, and no context is declared yet" %}
  {% end %}

  # Each value that wraps a raw type in `Drawn::WRAPS` gets its generator. A value that
  # defines `corretto_draw` itself keeps its own.
  {% for value in ::SweetTalk::Value.all_subclasses %}
    {% own = value.class.methods.any? { |method| method.name == "corretto_draw" } %}
    {% if !own && ::SweetTalk::Drawn::WRAPS.includes?(value.constant("SWEETTALK_WRAPS")) %}
      struct ::{{ value }}
        def self.corretto_draw(random : ::Random) : self
          __sweettalk_draw(random)
        end
      end
    {% end %}
  {% end %}

  # Each amount of `caramel/sweet_talk/money`, when the program required it, is drawn as a
  # whole number of minor units.
  {% if @type.has_constant?("Money") %}
    {% for minor in ::SweetTalk::Money::Units.includers %}
      struct ::{{ minor }}
        def self.corretto_draw(random : ::Random) : self
          new(::Corretto::Property.whole(random, nil, nil))
        end
      end
    {% end %}
  {% end %}

  # Each value with parts gets its generator when every part is drawn: a plain type, or a
  # value that has its generator by now.
  {% for composite in ::SweetTalk::Composite.all_subclasses %}
    {% own = composite.class.methods.any? { |method| method.name == "corretto_draw" } %}
    {% parts = composite.constants.select(&.starts_with?("SWEETTALK_PART_"))
         .map { |constant| parse_type(composite.constant(constant)[2]).resolve } %}
    {% drawn = parts.all? do |part|
         ::Corretto::Property::PLAIN.includes?(part.stringify) ||
           part.class.has_method?("corretto_draw")
       end %}
    {% if !own && drawn %}
      struct ::{{ composite }}
        def self.corretto_draw(random : ::Random) : self
          __sweettalk_draw(random)
        end
      end
    {% end %}
  {% end %}
end

Corretto::Property.outside(SweetTalk::Refusal)
Corretto::Property.message_only(SweetTalk::Broken)
