# Allocation: a total of minor units shared in proportion to weights, exactly, with the
# units the floors leave given out as `remainder:` says (ADR 0063).
module SweetTalk
  module Money
    # Where the units left after flooring every share go: one each to the largest
    # fractions, ties by key; all to the first or the last key with a weight, in key order;
    # or all to the key the caller names.
    REMAINDERS = %w[largest_fraction first last to]

    # A weight as an exact fraction.
    def self.weight(weight : Int) : BigRational
      BigRational.new(weight.to_big_i)
    end

    def self.weight(weight : BigDecimal) : BigRational
      BigRational.new(weight.value, BigInt.new(10) ** weight.scale)
    end

    def self.weight(weight : Value) : BigRational
      weight(weight.raw)
    end

    # How a key orders, for ties and for `:first` and `:last`: an id or a value by its raw.
    def self.rank(key : Identity | Value)
      key.raw
    end

    def self.rank(key)
      key
    end

    # The minor units *amount* counts: a `Minor`'s or a whole-number value's raw.
    def self.units(amount) : Int64
      amount.raw.to_i64
    end

    # An amount like *total*, of its currency, holding *units*.
    def self.rebuild(total, units : Int64)
      total.class.new(typeof(total.raw).new(units))
    end

    # The currency code of *amount*, or nil for a count without one.
    def self.unit(amount : Units) : String?
      amount.code
    end

    def self.unit(amount) : String?
      nil
    end

    # Each key's exact share of *units*' magnitude; refuses a weight below zero, or weights
    # that sum to zero.
    def self.shares(units : Int64, weights : Hash(K, W)) : Hash(K, BigRational) forall K, W
      exact = weights.transform_values { |given| weight(given) }
      if exact.values.any?(&.negative?)
        raise Refusal.new("An allocation takes no weight below zero")
      end
      sum = exact.values.sum(BigRational.new(0))
      raise Refusal.new("An allocation needs a weight above zero") unless sum > 0
      exact.transform_values { |given| given * units.to_big_i.abs / sum }
    end

    # *units* shared in proportion to *weights*, in key order: each key gets the floor of
    # its share's magnitude, the units left go as *remainder* says, and a negative total
    # gives negative parts.
    def self.allocate(units : Int64, weights : Hash(K, W), remainder : Symbol,
                      to : K? = nil) : Hash(K, Int64) forall K, W
      exact = shares(units, weights)
      floors = exact.transform_values { |share| fit(share.numerator // share.denominator) }
      left = units.abs - floors.values.sum(0_i64)
      ordered = exact.keys.sort_by! { |key| rank(key) }
      weighted = ordered.select { |key| weight(weights[key]) > 0 }
      receiving(exact, floors, weighted, left, remainder, to).each do |key, more|
        floors[key] += more
      end
      sign = units < 0 ? -1 : 1
      ordered.to_h { |key| {key, floors[key] * sign} }
    end

    # How many more units each receiving key gets, *weighted* being the keys of a weight
    # above zero, in key order.
    private def self.receiving(exact : Hash(K, BigRational), floors : Hash(K, Int64),
                               weighted : Array(K), left : Int64, remainder : Symbol,
                               to : K?) : Hash(K, Int64) forall K
      if remainder == :to && !(to && weighted.includes?(to))
        raise Refusal.new("The remainder of an allocation goes to a key with a weight " \
                          "above zero, not #{to}")
      end
      return {} of K => Int64 if left == 0
      case remainder
      when :largest_fraction
        largest = weighted.sort_by { |key| {BigRational.new(floors[key]) - exact[key], rank(key)} }
        largest.first(left).to_h { |key| {key, 1_i64} }
      when :first then Hash(K, Int64){weighted.first => left}
      when :last  then Hash(K, Int64){weighted.last => left}
      when :to
        raise ArgumentError.new("remainder: :to needs the key the units left go to") if to.nil?
        Hash(K, Int64){to => left}
      else
        raise ArgumentError.new("remainder #{remainder} is not #{REMAINDERS}")
      end
    end

    # Whether *parts* add up to *total*, in its currency.
    def self.summed?(parts : Hash(K, V), total) : Bool forall K, V
      parts.values.all? { |part| unit(part) == unit(total) } &&
        parts.values.sum(0_i64) { |part| units(part) } == units(total)
    end

    # Whether each part is the floor or the ceiling of its share or, when the remainder
    # goes to one key, whether every part is its floor but one, which is less than a unit
    # per key above it.
    def self.bounded?(parts : Hash(K, V), total, weights : Hash(K, W), remainder : Symbol,
                      to : K? = nil) : Bool forall K, V, W
      exact = shares(units(total), weights)
      return false unless parts.keys.to_set == exact.keys.to_set
      above = parts.map do |key, part|
        units(part).abs.to_big_i - exact[key].numerator // exact[key].denominator
      end
      return above.all? { |more| more == 0 || more == 1 } if remainder == :largest_fraction
      above.all? { |more| more >= 0 && more < parts.size } && above.count(&.positive?) <= 1
    end

    # Whether every key of weight zero gets nothing.
    def self.unweighted?(parts : Hash(K, V), weights : Hash(K, W)) : Bool forall K, V, W
      weights.all? do |key, given|
        part = parts[key]?
        weight(given) != 0 || (!part.nil? && units(part) == 0)
      end
    end
  end

  module BoundedContext
    # `allocation split, of: Money::Amount, by: Weight, remainder: :largest_fraction, means:
    # "…"` declares the calculation `split(total : Money::Amount, weights : Hash(Int64,
    # Weight)) : Hash(Int64, Money::Amount)` (ADR 0062): each key's part of the total in
    # proportion to its weight, exact, with the units the floors leave given out as
    # `remainder:` says, ties going to the smaller key. `per: Owner` keys it by another type,
    # and `remainder: :to` adds a third argument, the key that takes the units left. Its
    # rules on the result say the parts add up to the total, each part is the floor or the
    # ceiling of its share (or its floor, but the one the remainder goes to), and a key of
    # weight zero gets nothing; a block adds rules of its own. Neither the types nor the
    # block may hold a `Float64`, `to_f` or a float literal.
    #
    # @word noun | Declares a calculation that splits an amount by weights, exact to the minor unit.
    # @usage allocation VERB, of: TYPE, by: TYPE, remainder: MODE[, ties: :key][, per: TYPE],
    #   means: TEXT [do ... end]
    # @in in a context
    # @option of | an amount type, as Money::Amount | - | The amount the calculation splits.
    #   Required; it holds no Float64.
    # @option by | a whole-number type or a Decimal(P, S) value | - | The weight of each key.
    #   Required; a weight is not negative, and the weights add up to more than zero.
    # @option remainder | :largest_fraction, :first, :last or :to | - | Where the units the
    #   floors leave go: one each to the largest fractions, all to the first or last key with a
    #   weight, or all to a key passed as a third argument with :to. Required.
    # @option ties | :key | by key, the smaller first | How a tie between fractions breaks.
    #   :key is the only form.
    # @option means | text | - | What the calculation does, in a line the glossary shows.
    #   Required.
    # @option per | a type | Int64 | The type that keys the weights and the parts.
    # @guide c-sweettalk-money
    # @example requires caramel/sweet_talk/money
    #   kernel Payroll, shared_by: [Wages, Stub], means: "how payroll counts money" do
    #     currencies %w[USD EUR], means: "a currency payroll pays in"
    #   end
    #
    #   context Wages, shares: Payroll, means: "sharing a pay pot between staff" do
    #     value Weight, Decimal(9, 6), at_least: "0", at_most: "100", means: "a member's percent"
    #     allocation split, of: Payroll::Amount, by: Weight, remainder: :largest_fraction,
    #       ties: :key, means: "a pot split by percent, the odd units to the largest fractions"
    #   end
    #
    #   context Stub, shares: Payroll, means: "what a pay stub shows" do
    #     aggregate Slip, means: "one pay stub" do
    #       has pay : Payroll::Amount
    #     end
    #   end
    macro allocation(name, of = nil, by = nil, remainder = nil, ties = nil, means = nil,
                     per = nil, &block)
      {% what = "allocation #{name}" %}
      {% unless name.is_a?(Call) && name.args.empty? && name.receiver.is_a?(Nop) &&
                  !name.block %}
        {% name.raise "allocation takes a verb, as in allocation split, of: Money::Amount, " +
                      "by: Weight, remainder: :largest_fraction, means: \"…\", not #{name}" %}
      {% end %}
      {% for option in [{"of", of, "the amount it splits, as in of: Money::Amount"},
                        {"by", by, "the weight of each key, as in by: Weight"}] %}
        {% if option[1].is_a?(NilLiteral) %}
          {% name.raise "#{what.id} needs #{option[0].id}:, #{option[2].id}" %}
        {% end %}
      {% end %}
      {% shapes = ::SweetTalk::Money::REMAINDERS %}
      {% unless remainder.is_a?(SymbolLiteral) && shapes.includes?(remainder.id.stringify) %}
        {% target = remainder.is_a?(NilLiteral) ? name : remainder %}
        {% target.raise "#{what.id} takes remainder: :largest_fraction, :first, :last or :to, " +
                        "where the units left after flooring each share go, not #{remainder}" %}
      {% end %}
      {% unless ties.is_a?(NilLiteral) || ties == :key %}
        {% ties.raise "#{what.id} breaks ties by key, the smaller first: write ties: :key or " +
                      "leave it out, not ties: #{ties}" %}
      {% end %}
      {% key = per.is_a?(NilLiteral) ? "Int64".id : per %}
      {% words = /(?<![\w])(Float64|Float32|to_f(?:32|64)?)(?![\w])/ %}
      {% literals = /\d\.\d|\d_?f(?:32|64)\b|\d[eE][-+]?\d/ %}
      {% for typed in [{"of", of}, {"by", by}, {"per", key}] %}
        {% text = typed[1].stringify.gsub(/"(?:[^"\\]|\\.)*"/, "\"\"") %}
        {% if text =~ words || text =~ literals %}
          {% typed[1].raise "#{what.id} counts exactly, so #{typed[0].id}: holds no Float64, " +
                            "to_f or float literal: use a whole number or a Decimal(P, S) value" %}
        {% end %}
      {% end %}
      {% rules = [] of Nil %}
      {% if block %}
        {% rules = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
      {% end %}
      {% for rule in rules %}
        {% text = rule.stringify.gsub(/"(?:[^"\\]|\\.)*"/, "\"\"") %}
        {% if text =~ words || text =~ literals %}
          {% rule.raise "#{what.id} counts exactly, so its rules hold no Float64, to_f or " +
                        "float literal: compare whole numbers or BigRational" %}
        {% end %}
      {% end %}
      {% mode = remainder %}
      {% bound = "each part is the floor or the ceiling of its share" %}
      {% if mode != :largest_fraction %}
        {% bound = "each part is the floor of its share, but the one the remainder goes to" %}
      {% end %}
      {% to = mode == :to ? ", to : #{key}".id : "".id %}
      {% given = mode == :to ? "to".id : "nil".id %}
      calculation {{ name.id }}(total : {{ of }}, weights : Hash({{ key }}, {{ by }}){{ to }}),
        returns: Hash({{ key }}, {{ of }}), means: {{ means }} do
        always "the parts add up to the total, in its currency" do
          ::SweetTalk::Money.summed?(result, total)
        end
        always {{ bound }} do
          ::SweetTalk::Money.bounded?(result, total, weights, {{ mode }})
        end
        always "a key of weight zero gets nothing" do
          ::SweetTalk::Money.unweighted?(result, weights)
        end
        {% for rule in rules %}
          {{ rule }}
        {% end %}
        units = ::SweetTalk::Money.allocate(::SweetTalk::Money.units(total), weights,
          {{ mode }}, {{ given }})
        units.to_h { |key, part| {key, ::SweetTalk::Money.rebuild(total, part).as({{ of }})} }
      end
    end
  end
end
