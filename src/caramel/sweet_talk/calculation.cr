# Calculations: typed functions of a context whose `never` and `always` lines hold on their
# result (ADR 0062).
module SweetTalk
  # A rule on a calculation's result broke: the calculation computed what its own `never`
  # or `always` forbids. The caller did nothing wrong, so it is a defect, not a refusal: it
  # rolls back the transaction it runs in, and an action answers it 500.
  class Broken < Exception
    # The calculation, as `Ledger.carrying_chain`.
    getter calculation : String
    # The sentence of the rule it broke.
    getter rule : String

    def initialize(@calculation : String, @rule : String)
      super("#{@calculation} broke its rule: #{@rule}")
    end
  end

  # One calculation: its context, name and meaning, its arguments as {name, type}, the type
  # it returns, and its rules as {"never" or "always", sentence}, in the order written.
  record Calculation, context : String, name : String, means : String,
    arguments : Array({String, String}), returns : String, rules : Array({String, String})

  # Every calculation of the domain, context by context in declaration order. It is read
  # when the program compiles, as `glossary` is.
  def self.calculations : Array(Calculation)
    found = [] of Calculation
    {% begin %}
      {% for context in ::SweetTalk::BoundedContext.includers %}
        {% short = context.name.split("::").last %}
        {% for constant in context.constants.select(&.starts_with?("SWEETTALK_CALCULATION_")) %}
          {% entry = context.constant(constant) %}
          {% arguments = entry[3].map { |pair| "{#{pair[0]}, #{pair[1]}}" } %}
          {% rules = entry[5].map { |pair| "{#{pair[0]}, #{pair[1]}}" } %}
          found << Calculation.new({{ short }}, {{ entry[0] }}, {{ entry[1] }},
            [{{ arguments.join(", ").id }}] of {String, String}, {{ entry[4] }},
            [{{ rules.join(", ").id }}] of {String, String})
        {% end %}
      {% end %}
    {% end %}
    found
  end

  module BoundedContext
    # `calculation share(total : Cents, parts : Int32), returns: Array(Cents), means: "…"
    # do … end` is a calculation: a typed function of the context, `Billing.share`, with no
    # transaction, repository, event or command. The body's last expression is its result.
    # A `never` or `always` line in the body is a rule on `result`, checked after the body;
    # a broken one raises `SweetTalk::Broken`. `SWEETTALK_CALCULATION_<NAME>` records {name,
    # means, line, [{argument, type}], returns, [{"never" or "always", sentence}]}, each type
    # its full name, for `SweetTalk.calculations`.
    #
    # @word noun | Declares a typed function of a context that changes nothing.
    # @usage calculation VERB(ARG : TYPE, ...), returns: TYPE, means: TEXT do ... end
    # @in in a context
    # @guide c-sweettalk-calculations
    # @option returns | a type declared before it | - | The type of the result. Required.
    # @option means | text | - | What the calculation computes, in a line the glossary shows.
    #   Required.
    # @example
    #   context Mill, means: "grain milled into flour" do
    #     value Kilos, Int32, at_least: 0, means: "a weight in kilos"
    #
    #     calculation flour_from(grain : Kilos, percent : Int32), returns: Kilos,
    #       means: "the flour a weight of grain yields at a milling rate" do
    #       always "Flour weighs no more than the grain." do
    #         result.raw <= grain.raw
    #       end
    #       Kilos.new(grain.raw * percent // 100)
    #     end
    #   end
    macro calculation(call, returns = nil, means = nil, &block)
      {% typed = call.is_a?(Call) && call.receiver.is_a?(Nop) &&
                 call.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed %}
        {% call.raise "calculation takes a verb and typed arguments, as in calculation " +
                      "share(total : Cents, parts : Int32), returns: Array(Cents) do … end" %}
      {% end %}
      {% short = @type.name.split("::").last %}
      {% what = "calculation #{short.id}.#{call.name}" %}
      {% call.raise "#{@type.name.id}.#{call.name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      {% if returns.is_a?(NilLiteral) %}
        {% call.raise "#{what.id} needs returns:, the type of its result, as in " +
                      "returns: Cents" %}
      {% end %}
      {% unless block %}
        {% call.raise "#{what.id} needs a body, do … end, whose last expression is its result" %}
      {% end %}
      {% declared = [] of Nil %}
      {% for arg in call.args %}
        {% if arg.var.stringify == "result" %}
          {% arg.raise "#{what.id} takes an argument named result, the name its rules read " +
                       "its result by: rename the argument" %}
        {% end %}
        {% declared << {arg, "takes #{arg.var} : #{arg.type}", arg.type} %}
      {% end %}
      {% declared << {returns, "returns #{returns}", returns} %}
      {% resolved = [] of Nil %}
      {% for entry in declared %}
        {% found = entry[2].resolve? %}
        {% unless found %}
          {% entry[0].raise "#{what.id} #{entry[1].id}, which is no type declared before it: " +
                            "declare it above the calculation" %}
        {% end %}
        {% members = found.union? ? found.union_types : [found] %}
        {% for member in members %}
          {% held = member < ::Array ? member.type_vars[0] : member %}
          {% if held < ::SweetTalk::Model %}
            {% entry[0].raise "#{what.id} #{entry[1].id}, which holds the " +
                              "#{held.constant("SWEETTALK_KIND").id} #{held}: a calculation " +
                              "computes from values, so take what it needs from it, or its " +
                              "id, and let the caller load it" %}
          {% end %}
        {% end %}
        {% resolved << found %}
      {% end %}
      {% body = block.body %}
      {% steps = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% rules = steps.select do |step|
           step.is_a?(Call) && %w[never always].includes?(step.name.stringify) &&
             step.args.size == 1 && step.args[0].is_a?(StringLiteral) && !step.block.is_a?(Nop)
         end %}
      {% work = steps.reject { |step| rules.includes?(step) } %}
      {% checked = work.map { |step| {step, step.stringify} } %}
      {% for rule in rules %}
        {% checked << {rule, rule.block.body.stringify} %}
      {% end %}
      {% for check in checked %}
        {% text = check[1].gsub(/"(?:[^"\\]|\\.)*"/, "\"\"") %}
        {% reached = text.match(/(?<![\w])(SugarORM|Repo|Rows|SweetTalk\.lock)(?![\w])/) %}
        {% if reached %}
          {% check[0].raise "#{what.id} reaches #{reached[1].id}: a calculation computes " +
                            "from its arguments alone, with no repository or transaction; " +
                            "let the caller load what it needs and pass it in" %}
        {% end %}
        {% if text =~ /(?<![\w.:@])emit(?![\w?!])/ %}
          {% check[0].raise "#{what.id} emits an event: a calculation records nothing; emit " +
                            "from the command or the service that calls it" %}
        {% end %}
        {% for named in text.scan(/((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)\.([a-z_]\w*[?!]?)/) %}
          {% target = parse_type(named[1]).resolve? %}
          {% if target && target.is_a?(TypeNode) && target < ::SweetTalk::Model %}
            {% check[0].raise "#{what.id} calls #{named[1].id}.#{named[2].id}, on the " +
                              "#{target.constant("SWEETTALK_KIND").id} #{target}: a " +
                              "calculation computes from its arguments alone, with no " +
                              "repository or transaction; let the caller load what it needs " +
                              "and pass it in" %}
          {% end %}
          {% verb = named[2].upcase %}
          {% for kind in %w[service unit] %}
            {% key = "SWEETTALK_#{kind.upcase.id}_#{verb.id}" %}
            {% if target && target.is_a?(TypeNode) && target.has_constant?(key) %}
              {% check[0].raise "#{what.id} calls #{kind.id} #{named[1].id}.#{named[2].id}: a " +
                                "calculation changes nothing; let the caller run the #{kind.id} " +
                                "and pass its answer in" %}
            {% end %}
          {% end %}
        {% end %}
        {% for kind in %w[service unit] %}
          {% prefix = "SWEETTALK_#{kind.upcase.id}_" %}
          {% for constant in @type.constants.select(&.starts_with?(prefix)) %}
            {% verb = @type.constant(constant)[0] %}
            {% pieces = text.split(verb) %}
            {% for index in 1...pieces.size %}
              {% unless pieces[index - 1] =~ /[\w.:@]\z/ || pieces[index] =~ /\A[\w?!]/ %}
                {% check[0].raise "#{what.id} calls #{kind.id} #{short.id}.#{verb.id}: a " +
                                  "calculation changes nothing; let the caller run the " +
                                  "#{kind.id} and pass its answer in" %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      {% arguments = call.args.map_with_index do |arg, index|
           "{#{arg.var.stringify}, #{resolved[index].stringify}}"
         end %}
      {% sentences = rules.map { |rule| "{#{rule.name.stringify}, #{rule.args[0]}}" } %}
      SWEETTALK_CALCULATION_{{ call.name.upcase }} = { {{ call.name.stringify }}, {{ means }},
        {{ call.line_number }}, [{{ arguments.join(", ").id }}] of {String, String},
        {{ resolved[-1].stringify }}, [{{ sentences.join(", ").id }}] of {String, String} }
      {% for rule in rules %}
        {% said = (rule.named_args || [] of Nil).find { |arg| arg.name.stringify == "assures" } %}
        {% if said %}
          ::SweetTalk.__sweettalk_assures({{ rule.name.stringify }},
            {{ "#{rule.name} in #{what.id}" }}, {{ rule.args[0] }},
            {{ said.value }}, {{ @type.name.stringify }}, {{ "#{@type.name}.#{call.name}" }},
            {{ "SWEETTALK_ASSURES_CALCULATION_#{call.name.upcase}_#{rule.args[0].line_number}" }})
        {% end %}
      {% end %}

      private def self.__sweettalk_calculate_{{ call.name }}({{ call.args.splat }}) : {{ returns }}
        {% for step in work %}
          {{ step }}
        {% end %}
      end

      def self.{{ call.name }}({{ call.args.splat }}) : {{ returns }}
        result = __sweettalk_calculate_{{ call.name }}({{ call.args.map(&.var).splat }})
        {% for rule in rules %}
          {% if rule.name == "never" %}
            if ({{ rule.block.body }})
              raise ::SweetTalk::Broken.new({{ "#{short.id}.#{call.name}" }}, {{ rule.args[0] }})
            end
          {% else %}
            unless ({{ rule.block.body }})
              raise ::SweetTalk::Broken.new({{ "#{short.id}.#{call.name}" }}, {{ rule.args[0] }})
            end
          {% end %}
        {% end %}
        result
      end

      # Typed by `SweetTalk.boot`, so the body compiles whether or not anything calls it.
      def self.__sweettalk_touch_{{ call.name }} : Nil
        {% params = call.args.map { |arg| "#{arg.var} : #{arg.type}" } %}
        ->({{ params.join(", ").id }}) { {{ call.name }}({{ call.args.map(&.var).splat }}) }
        nil
      end
    end
  end

  abstract class Model
    macro calculation(call, returns = nil, means = nil, &block)
      {% owner = "#{@type.constant("SWEETTALK_KIND").id} #{@type.name.split("::").last.id}" %}
      {% call.raise "calculation belongs in a context, not in #{owner.id}" %}
    end
  end
end
