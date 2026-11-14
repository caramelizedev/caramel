require "spec"
require "random/pcg32"
require "random/secure"

module Corretto
  # `Corretto.property(Billing.share)` runs a class method on 200 generated cases and fails
  # the example when one raises (ADR 0010 decision 11). It takes any `Owner.method` whose
  # arguments each have a type, read where the method is defined, and draws each argument
  # from its type: `Int32`, `Int64`, `Bool`, `String`, nil, unions, arrays of at most 8
  # elements, hashes of at most 8 keys, and any type with a generator, the class method
  # `corretto_draw(random : Random) : self`. A case that raises `Property::Skip`, or an
  # exception `Property.outside` names, is outside the domain: it is skipped and counted.
  # Any other error fails the example with the case's arguments and the seed, which
  # `CORRETTO_SEED` gives back. It needs no session and no database. Returns the run's
  # counts.
  macro property(call)
    {% shaped = call.is_a?(Call) && call.receiver.is_a?(Path) &&
                call.args.empty? && call.block.is_a?(Nop) %}
    {% unless shaped %}
      {% call.raise "Corretto.property takes a class method, as in " +
                    "Corretto.property(Billing.share), not #{call}" %}
    {% end %}
    {% owner = call.receiver.resolve? %}
    {% holder = owner %}
    {% methods = [] of Nil %}
    {% if owner && owner.is_a?(TypeNode) %}
      {% methods = owner.class.methods.select { |method| method.name == call.name } %}
      # A class inherits its class methods, and a module that extends itself holds them.
      {% for ancestor in owner.class.ancestors %}
        {% if methods.empty? %}
          {% methods = ancestor.methods.select { |method| method.name == call.name } %}
          {% holder = ancestor.instance if !methods.empty? %}
        {% end %}
      {% end %}
    {% end %}
    {% if methods.empty? %}
      {% call.raise "Corretto.property takes a class method, and #{call} is none: define " +
                    "def self.#{call.name} in #{call.receiver}, each argument with its type" %}
    {% end %}
    {% if methods.size > 1 %}
      {% call.raise "Corretto.property runs one method, and #{call} has #{methods.size} " +
                    "overloads: give the one to run a name of its own" %}
    {% end %}
    {% method = methods[0] %}
    {% unless method.splat_index.is_a?(NilLiteral) && method.double_splat.is_a?(Nop) &&
                !method.accepts_block? %}
      {% call.raise "Corretto.property draws one value for each argument, and #{call} takes " +
                    "a splat or a block: wrap it in a class method of typed arguments" %}
    {% end %}
    {% label = "#{owner.name.split("::").last.id}.#{call.name}" %}
    # A restriction is read as the type that defines the method reads it: inside that
    # type, then inside each namespace around it, then at the top level.
    {% scopes = [""] %}
    {% for segment in holder.name(generic_args: false).split("::") %}
      {% scopes = ["#{scopes[0].id}::#{segment.id}"] + scopes %}
    {% end %}
    {% named = /(?<![\w:])(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*/ %}
    {% types = [] of Nil %}
    {% for argument in method.args %}
      {% if argument.restriction.is_a?(Nop) %}
        {% call.raise "Corretto.property draws each argument from its type, and " +
                      "#{argument.name} of #{label.id} has none: write " +
                      "#{argument.name} : Type in def self.#{call.name}" %}
      {% end %}
      {% written = argument.restriction.stringify
           .gsub(/(?<![\w:.@])self(?![\w?!])/, "::#{owner}") %}
      {% between = written.split(named) %}
      {% full = between[0] %}
      {% for match, index in written.scan(named) %}
        {% found = match[0].starts_with?("::") ? match[0] : nil %}
        {% for scope in scopes %}
          {% candidate = "#{scope.id}::#{match[0].id}" %}
          {% found = candidate if !found && parse_type(candidate).resolve? %}
        {% end %}
        {% full = full + (found || match[0]) + between[index + 1] %}
      {% end %}
      {% unless parse_type(full).resolve? %}
        {% call.raise "Corretto.property cannot draw #{argument.name} : " +
                      "#{argument.restriction} for #{label.id}: it names no type the " +
                      "program declares; write one that is, not a free variable" %}
      {% end %}
      # Walks the type breadth first with an explicit queue, since a macro cannot recurse:
      # unions, arrays and hashes hold the types drawn.
      {% queue = [parse_type(full).resolve] %}
      {% for index in 0...64 %}
        {% if index < queue.size %}
          {% type = queue[index] %}
          {% if type.union? %}
            {% queue = queue + type.union_types %}
          {% elsif type < ::Array %}
            {% queue << type.type_vars[0] %}
          {% elsif type < ::Hash %}
            {% queue = queue + type.type_vars %}
          {% elsif !::Corretto::Property::PLAIN.includes?(type.stringify) &&
                     !type.class.has_method?("corretto_draw") %}
            {% call.raise "Corretto.property cannot draw #{argument.name} : #{type} for " +
                          "#{label.id}: it draws " + ::Corretto::Property::DRAWS %}
          {% end %}
        {% end %}
      {% end %}
      {% types << full %}
    {% end %}
    {% names = method.args.map_with_index { |_argument, index| "__corretto_#{index}".id } %}
    ::Corretto::Property.run({{ label }}, {{ call.filename }},
      {{ call.line_number }}) do |__corretto_random, __corretto_inputs|
      {% for argument, index in method.args %}
        {{ names[index] }} = ::Corretto::Property.draw({{ types[index].id }},
          __corretto_random)
        __corretto_inputs << "{{ argument.name }} = #{{{ names[index] }}.inspect}"
      {% end %}
      ::{{ owner }}.{{ call.name }}({{ names.splat }})
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
    SPAN         = 1_000_000_i64
    LETTERS      = ('a'..'z').to_a + ('A'..'Z').to_a
    SEED         = "CORRETTO_SEED"
    SEED_REFUSAL = "CORRETTO_SEED must be a whole number from 0 to 18446744073709551615, not "
    # The types drawn with no generator
    PLAIN = %w[Nil Bool Int32 Int64 String]
    # What is drawn, as a refusal lists it
    DRAWS = "Int32, Int64, Bool, String, nil, arrays, hashes and unions of them, and any " \
            "type with a class method corretto_draw(random : Random) : self"

    # Raise it in the method a property runs to put the case outside the method's domain:
    # the case is skipped and counted, not failed.
    class Skip < Exception
    end

    @@outside = [Skip] of Exception.class
    @@message_only = [] of Exception.class

    # Names *error*, an exception class, as outside the domain: a case that raises it, or a
    # subclass of it, is skipped and counted, as one that raises `Skip` is.
    def self.outside(error : Exception.class) : Nil
      @@outside << error
    end

    # Names *error*, an exception class, as one whose message says what failed: a failure
    # starts with the message alone, not with the method and the class.
    def self.message_only(error : Exception.class) : Nil
      @@message_only << error
    end

    # What a run did: its seed, and how many cases held and how many were skipped.
    record Run, label : String, seed : UInt64, held : Int32, skipped : Int32

    # Runs CASES cases, each drawn by the block from one random source seeded from
    # CORRETTO_SEED, or from a new seed. A case whose block raises an error outside the
    # domain is skipped. Fails at *file* and *line* on the first case that raises any
    # other error, and when no case held.
    def self.run(label : String,
                 file : String,
                 line : Int32,
                 & : Random, Array(String) ->) : Run
      seed = self.seed
      random = Random::PCG32.new(seed)
      held = 0
      CASES.times do |index|
        inputs = [] of String
        begin
          yield random, inputs
          held += 1
        rescue error
          next if @@outside.any?(&.===(error))
          raise ::Spec::AssertionFailed.new(broken(label, error, index, seed, inputs),
            file, line)
        end
      end
      raise ::Spec::AssertionFailed.new(empty(label, seed), file, line) if held.zero?
      Run.new(label, seed, held, CASES - held)
    end

    # The seed CORRETTO_SEED names, or a new one.
    def self.seed : UInt64
      text = ENV[SEED]? || return Random::Secure.rand(UInt64)
      text.to_u64? || raise ArgumentError.new(SEED_REFUSAL + text)
    end

    # What failed, the case and its seed, and each argument drawn, one per line. The
    # failure names the method and the error's class, unless the error's message says what
    # failed by itself.
    private def self.broken(label : String,
                            error : Exception,
                            index : Int32,
                            seed : UInt64,
                            inputs : Array(String)) : String
      String.build do |text|
        unless @@message_only.any?(&.===(error))
          text << label << " raised " << error.class.name << ": "
        end
        text << error.message
        text << "\n  case " << index + 1 << " of " << CASES << ", seed " << seed
        text << "; rerun with " << SEED << "=" << seed << "\n"
        inputs.each { |input| text << "  " << input << "\n" }
      end
    end

    private def self.empty(label : String, seed : UInt64) : String
      "#{label} refused every one of #{CASES} cases, so the run proved nothing: widen " \
      "the bounds of its arguments' values, or refuse less (seed #{seed})"
    end

    # A value of *type*: a plain one, the members of a union, the elements of an array or
    # a hash, or what the type's generator draws.
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
      {% elsif T.class.has_method?("corretto_draw") %}
        T.corretto_draw(random)
      {% else %}
        {% raise "Corretto.property cannot draw #{T}: it draws #{DRAWS.id}" %}
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
