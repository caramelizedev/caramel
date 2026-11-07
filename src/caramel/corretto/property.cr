require "spec"
require "random/pcg32"
require "random/secure"

module Corretto
  # `Corretto.property(Billing.share)` runs a SweetTalk calculation on 200 generated cases
  # and fails the example when one breaks a rule on its result (ADR 0010 decision 11,
  # ADR 0062). Each argument is drawn from what its type declares: a value's bounds, its
  # `one_of:` members, its decimal precision and scale, its parts; an array holds at most
  # 8 elements and a hash 8 keys, and an amount of `caramel/sweet_talk/money` is a whole
  # number of minor units. A case the calculation or a value refuses is outside the
  # domain: it is skipped and counted. A broken rule, or any other error, fails the example with the
  # case's arguments and the seed, which `CORRETTO_SEED` gives back. It needs no session
  # and no database. Returns the run's counts.
  macro property(calculation)
    {% shaped = calculation.is_a?(Call) && calculation.receiver.is_a?(Path) &&
                calculation.args.empty? && calculation.block.is_a?(Nop) %}
    {% unless shaped %}
      {% calculation.raise "Corretto.property takes a calculation, as in " +
                           "Corretto.property(Billing.share), not #{calculation}" %}
    {% end %}
    {% owner = calculation.receiver.resolve? %}
    {% key = "SWEETTALK_CALCULATION_#{calculation.name.upcase.id}" %}
    {% unless owner && owner.is_a?(TypeNode) && owner.has_constant?(key) %}
      {% calculation.raise "Corretto.property takes a calculation, and #{calculation} is " +
                           "none: declare calculation #{calculation.name} in " +
                           "#{calculation.receiver}" %}
    {% end %}
    {% entry = owner.constant(key) %}
    {% label = "#{owner.name.split("::").last.id}.#{calculation.name}" %}
    {% supported = ["Int32", "Int64", "String", "::SugarORM::Date", "::BigDecimal"] %}
    {% for pair in entry[3] %}
      # Walks the argument's type breadth first with an explicit queue, since a macro
      # cannot recurse: unions, arrays and parts hold the types drawn.
      {% queue = [parse_type(pair[1]).resolve] %}
      {% for index in 0...64 %}
        {% if index < queue.size %}
          {% type = queue[index] %}
          {% plain = %w[Nil Bool Int32 Int64 String].includes?(type.stringify) %}
          {% if type.union? %}
            {% queue = queue + type.union_types %}
          {% elsif type < ::Array %}
            {% queue << type.type_vars[0] %}
          {% elsif type < ::Hash %}
            {% queue = queue + type.type_vars %}
          {% elsif type.type_vars.size == 1 && type.type_vars[0].is_a?(TypeNode) &&
                     type.type_vars[0].has_constant?("SWEETTALK_LOADER") %}
            # An amount of caramel/sweet_talk/money, drawn as a whole number of minor units.
          {% elsif type < ::SweetTalk::Composite %}
            {% for part in type.constants.select(&.starts_with?("SWEETTALK_PART_")) %}
              {% queue << parse_type(type.constant(part)[2]).resolve %}
            {% end %}
          {% elsif !plain && !(type < ::SweetTalk::Value &&
                     supported.includes?(type.constant("SWEETTALK_WRAPS"))) %}
            {% calculation.raise "Corretto.property cannot draw #{pair[0].id} : #{type} for " +
                                 "#{label.id}: it draws Int32, Int64, Bool, String, nil, " +
                                 "arrays, hashes and unions of them, amounts of money, " +
                                 "SweetTalk values that wrap a whole number, text, a day " +
                                 "or a decimal, and values with parts of those" %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    {% names = entry[3].map_with_index { |_pair, index| "__corretto_#{index}".id } %}
    ::Corretto::Property.run({{ label }}, {{ calculation.filename }},
      {{ calculation.line_number }}) do |__corretto_random, __corretto_inputs|
      begin
        {% for pair, index in entry[3] %}
          {{ names[index] }} = ::Corretto::Property.draw({{ parse_type(pair[1]) }},
            __corretto_random)
          __corretto_inputs << "{{ pair[0].id }} = #{{{ names[index] }}.inspect}"
        {% end %}
        ::{{ owner }}.{{ calculation.name }}({{ names.splat }})
        ::Corretto::Property::Outcome::Held
      rescue ::SweetTalk::Refusal
        ::Corretto::Property::Outcome::Skipped
      end
    end
  end

  # The generated cases of `Corretto.property`.
  module Property
    # Cases per run
    CASES = 200
    # Elements in a drawn array, and keys in a drawn hash, at most
    ARRAY_MOST = 8
    # Characters in drawn text, at most
    TEXT_MOST = 12
    # How far a whole number reaches past an open side: -SPAN..SPAN with no bound
    SPAN = 1_000_000_i64
    # Whole digits a decimal reaches past an open side, at most: up to 999,999.99…
    DECIMAL_DIGITS = 6
    # Days drawn after FIRST_DAY, 2000-01-01 to 2040-12-31
    DAYS         = 14_975
    FIRST_DAY    = {2000, 1, 1}
    LETTERS      = ('a'..'z').to_a + ('A'..'Z').to_a
    SEED         = "CORRETTO_SEED"
    SEED_REFUSAL = "CORRETTO_SEED must be a whole number from 0 to 18446744073709551615, not "

    # What one case did: the calculation answered, or a refusal put it outside the domain.
    enum Outcome
      Held
      Skipped
    end

    # What a run did: its seed, and how many cases held and how many were skipped.
    record Run, calculation : String, seed : UInt64, held : Int32, skipped : Int32

    # Runs CASES cases, each drawn by the block from one random source seeded from
    # CORRETTO_SEED, or from a new seed. Fails at *file* and *line* on the first case that
    # raises, and when no case held.
    def self.run(calculation : String,
                 file : String,
                 line : Int32,
                 & : Random, Array(String) -> Outcome) : Run
      seed = self.seed
      random = Random::PCG32.new(seed)
      held = 0
      CASES.times do |index|
        inputs = [] of String
        outcome = begin
          yield random, inputs
        rescue error
          raise ::Spec::AssertionFailed.new(broken(calculation, error, index, seed, inputs),
            file, line)
        end
        held += 1 if outcome.held?
      end
      if held.zero?
        raise ::Spec::AssertionFailed.new(empty(calculation, seed), file, line)
      end
      Run.new(calculation, seed, held, CASES - held)
    end

    # The seed CORRETTO_SEED names, or a new one.
    def self.seed : UInt64
      text = ENV[SEED]? || return Random::Secure.rand(UInt64)
      text.to_u64? || raise ArgumentError.new(SEED_REFUSAL + text)
    end

    # What failed, the case and its seed, and each argument drawn, one per line. A broken
    # rule's message names its calculation; any other error is named by its class.
    private def self.broken(calculation : String,
                            error : Exception,
                            index : Int32,
                            seed : UInt64,
                            inputs : Array(String)) : String
      String.build do |text|
        if error.class.name == "SweetTalk::Broken"
          text << error.message
        else
          text << calculation << " raised " << error.class.name << ": " << error.message
        end
        text << "\n  case " << index + 1 << " of " << CASES << ", seed " << seed
        text << "; rerun with " << SEED << "=" << seed << "\n"
        inputs.each { |input| text << "  " << input << "\n" }
      end
    end

    private def self.empty(calculation : String, seed : UInt64) : String
      "#{calculation} refused every one of #{CASES} cases, so the run proved nothing: widen " \
      "the bounds of its arguments' values, or refuse less (seed #{seed})"
    end

    # A value of *type*, read from what the type declares.
    def self.draw(type : T.class, random : Random) forall T
      {% if T == Nil %}
        nil
      {% elsif T == Bool %}
        random.next_bool
      {% elsif T == Int32 || T == Int64 %}
        {{ T }}.new(whole(random, nil, nil))
      {% elsif T == String %}
        text(random)
      {% elsif T.union? %}
        {% members = T.union_types %}
        case random.rand({{ members.size }})
        {% for member, index in members %}
          when {{ index }} then draw({{ member }}, random)
        {% end %}
        else raise "unreachable"
        end
      {% elsif T < ::Array %}
        {% element = T.type_vars[0] %}
        Array({{ element }}).new(random.rand(0..ARRAY_MOST)) { draw({{ element }}, random) }
      {% elsif T < ::Hash %}
        {% key = T.type_vars[0] %}
        {% value = T.type_vars[1] %}
        Array.new(random.rand(0..ARRAY_MOST)) do
          {draw({{ key }}, random), draw({{ value }}, random)}
        end.to_h
      {% elsif T.type_vars.size == 1 && T.type_vars[0].is_a?(TypeNode) &&
                 T.type_vars[0].has_constant?("SWEETTALK_LOADER") %}
        T.new(whole(random, nil, nil))
      {% elsif T < ::SweetTalk::Composite %}
        {% parts = T.constants.select(&.starts_with?("SWEETTALK_PART_"))
             .map { |constant| T.constant(constant) } %}
        T.new(
          {% for part in parts %}
            {{ part[0].id }}: draw({{ parse_type(part[2]) }}, random),
          {% end %}
        )
      {% elsif T < ::SweetTalk::Value %}
        {% wraps = T.constant("SWEETTALK_WRAPS") %}
        {% if wraps == "Int32" || wraps == "Int64" %}
          {% bounds = T.constant("SWEETTALK_BOUNDS") %}
          {% least = bounds[0].is_a?(NilLiteral) ? "nil" : "(#{bounds[0].id}).to_i64" %}
          {% most = bounds[1].is_a?(NilLiteral) ? "nil" : "(#{bounds[1].id}).to_i64" %}
          T.new(whole(random, {{ least.id }}, {{ most.id }}))
        {% elsif wraps == "String" && T.has_constant?("SWEETTALK_ONE_OF") %}
          T.new(T::SWEETTALK_ONE_OF.sample(random))
        {% elsif wraps == "String" %}
          T.new(text(random))
        {% elsif wraps == "::SugarORM::Date" %}
          T.new(::SugarORM::Date.new(*FIRST_DAY).plus_days(random.rand(0..DAYS)))
        {% elsif wraps == "::BigDecimal" %}
          scale = T::SWEETTALK_SCALE
          unit = ::BigInt.new(10) ** scale
          digits = {T::SWEETTALK_PRECISION - scale, DECIMAL_DIGITS}.min
          reach = ::BigInt.new(10) ** digits * unit - 1
          {% if T.has_constant?("SWEETTALK_LEAST") %}
            least = (T::SWEETTALK_LEAST * unit).to_big_i
          {% else %}
            least = nil
          {% end %}
          {% if T.has_constant?("SWEETTALK_MOST") %}
            most = (T::SWEETTALK_MOST * unit).to_big_i
          {% else %}
            most = nil
          {% end %}
          low = least || (most ? most - reach : -reach)
          high = most || (least ? least + reach : reach)
          span = {high - low, ::BigInt.new(Int64::MAX)}.min.to_i64
          units = low + ::BigInt.new(edge(random, 0_i64, span))
          T.new(::BigDecimal.new(units, scale.to_u64))
        {% else %}
          {% raise "Corretto.property cannot draw #{T}, a value that wraps #{wraps.id}" %}
        {% end %}
      {% else %}
        {% raise "Corretto.property cannot draw #{T}" %}
      {% end %}
    end

    # A whole number from *least* to *most*, SPAN past an open side, an edge one time in
    # ten each: the least, the most, zero and one past the least.
    def self.whole(random : Random, least : Int64?, most : Int64?) : Int64
      low = least || (most ? most - SPAN : -SPAN)
      high = most || (least ? least + SPAN : SPAN)
      return low if high <= low
      zero = 0_i64.clamp(low, high)
      case random.rand(10)
      when 0 then low
      when 1 then high
      when 2 then zero
      when 3 then {low + 1, high}.min
      else        random.rand(low..high)
      end
    end

    # An offset from 0 to *span*, its ends one time in ten each.
    def self.edge(random : Random, low : Int64, span : Int64) : Int64
      return low if span <= 0
      case random.rand(10)
      when 0 then low
      when 1 then low + span
      else        low + random.rand(0_i64..span)
      end
    end

    # Letters, 0 to TEXT_MOST of them.
    def self.text(random : Random) : String
      String.build do |text|
        random.rand(0..TEXT_MOST).times { text << LETTERS.sample(random) }
      end
    end
  end
end
