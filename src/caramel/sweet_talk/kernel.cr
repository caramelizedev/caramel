# Shared kernels: the part of a model that named contexts own together.
module SweetTalk
  # Refuses a `shares:` that names anything but a kernel declared before it, or a kernel
  # whose `shared_by:` leaves *name* out (ADR 0044). *kind* is "context" or "kernel".
  macro __sweettalk_shared(kind, name, shares)
    {% shared = [] of Nil %}
    {% shared = [shares] unless shares.is_a?(NilLiteral) %}
    {% shared = shares if shares.is_a?(ArrayLiteral) %}
    {% for path in shared %}
      {% found = path.is_a?(Path) && path.resolve? %}
      {% sharers = found && found.has_constant?("SWEETTALK_SHARED_BY") &&
                   found.constant("SWEETTALK_SHARED_BY") %}
      {% unless sharers %}
        {% path.raise "#{kind.id} #{name} shares #{path}, which is no kernel declared before it: " +
                      "declare kernel #{path}, shared_by: [#{name}, …] before #{name}, or take " +
                      "#{path} out of shares:" %}
      {% end %}
      {% unless sharers.includes?(name.stringify) %}
        {% path.raise "#{kind.id} #{name} shares #{path}, but kernel #{path} is shared by " +
                      "#{sharers.join(", ").id}: add #{name} to its shared_by:" %}
      {% end %}
    {% end %}
  end

  # `kernel Money, shared_by: [Pricing, Billing], means: "…" do … end` is the part of a
  # model that the contexts and kernels in `shared_by:` own together, each saying
  # `shares: Money`. It holds values, and aggregates with their entities, events and
  # commands, and stores like a context: its tables are `money_…` and, in a program that
  # requires caramel/tenancy, its rows belong to the tenant. `shares: Calendar` names
  # the kernels declared before it that it shares. Only its sharers name it, it names no
  # context, and each of its words that no other of its words uses is named by two or
  # more sharers (ADR 0044).
  #
  # @word noun | Declares a part of the model that two or more contexts own together.
  # @usage kernel NAME, shared_by: [SHARER, SHARER, ...][, shares: KERNELS], means: TEXT do ... end
  # @guide c-sweettalk-kernel
  # @option shared_by | a list of two or more context or kernel names | - | The contexts and
  #   kernels that share it. Each says `shares:` with the kernel's name.
  # @option shares | a kernel name, or a list of them | - | The kernels declared before this one
  #   that it shares in turn.
  # @option means | text | - | What the kernel is, in a line the glossary shows. Required.
  # @example
  #   kernel Alloy, shared_by: [Assayer, Treasury], means: "the metal both contexts weigh" do
  #     value Grams, Int64, at_least: 0, means: "a weight of metal"
  #   end
  #
  #   context Assayer, shares: Alloy, means: "weighing metal that comes in" do
  #     aggregate Sample, means: "one weighed sample" do
  #       has weight : Alloy::Grams
  #     end
  #   end
  #
  #   context Treasury, shares: Alloy, means: "metal kept in store" do
  #     aggregate Bar, means: "one bar in store" do
  #       has weight : Alloy::Grams
  #     end
  #   end
  macro kernel(name, shared_by = nil, shares = nil, means = nil, &block)
    {% prefix = @type == @top_level ? "" : "#{@type.name.id}::" %}
    {% name.raise "#{prefix.id}#{name} needs a meaning: add means: \"…\", " +
                  "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
    {% valid = shared_by.is_a?(ArrayLiteral) && shared_by.size >= 2 &&
               shared_by.all? { |sharer| sharer.is_a?(Path) } %}
    {% sharers = [] of Nil %}
    {% if valid %}
      {% sharers = shared_by.map(&.names.last.stringify) %}
      {% valid = sharers.uniq.size == sharers.size %}
    {% end %}
    {% unless valid %}
      {% target = shared_by.is_a?(NilLiteral) ? name : shared_by %}
      {% target.raise "kernel #{name} takes shared_by: [Pricing, Billing], the two or more " +
                      "contexts or kernels that share it, not shared_by: #{shared_by}" %}
    {% end %}
    {% body = block ? block.body : nil %}
    {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
    {% declared = [] of Nil %}
    {% for node in expressions %}
      {% unless node.is_a?(Nop) || node.is_a?(NilLiteral) %}
        {% held = %w[value aggregate currencies quote] %}
        {% unless node.is_a?(Call) && held.includes?(node.name.stringify) %}
          {% what = node.is_a?(Call) ? node.name.stringify : node.class_name.downcase %}
          {% node.raise "kernel #{name} holds values and aggregates only, not #{what.id}: " +
                        "move it into a context that shares #{name}" %}
        {% end %}
        {% reached = nil %}
        {% reached = "Caramel::Outbound" if node.stringify.includes?("Caramel::Outbound") %}
        {% reached = "HTTP::Client" if node.stringify.includes?("HTTP::Client") %}
        {% if reached %}
          {% node.raise "kernel #{name} reaches #{reached.id}, which only a border with an " +
                        "outside system may: move that call into such a border in a context " +
                        "that shares #{name}" %}
        {% end %}
        {% declared << node %}
      {% end %}
    {% end %}
    # The words no other word of this kernel uses: two sharers must name each.
    {% checked = [] of Nil %}
    {% for node, index in declared %}
      {% unless node.args.empty? || node.name == "currencies" %}
        {% word = node.args[0].stringify %}
        {% inside = false %}
        {% for other, position in declared %}
          {% if position != index %}
            {% pieces = other.stringify.split(word) %}
            {% for i in 1...pieces.size %}
              {% inside = true unless pieces[i - 1] =~ /[\w:]\z/ || pieces[i] =~ /\A\w/ %}
            {% end %}
          {% end %}
        {% end %}
        {% checked << word unless inside %}
      {% end %}
    {% end %}
    {% tenant = @type.has_constant?("SWEETTALK_TENANT") && @type.constant("SWEETTALK_TENANT") %}
    {% domain = @type == @top_level ? "the program" : @type.name.stringify %}
    {% declared_ids = @type.has_constant?("SWEETTALK_IDS") && @type.constant("SWEETTALK_IDS") %}
    {% shared = [] of Nil %}
    {% shared = [shares] unless shares.is_a?(NilLiteral) %}
    {% shared = shares if shares.is_a?(ArrayLiteral) %}
    {% shared = shared.select { |path| path.is_a?(Path) } %}
    __sweettalk_shared("kernel", {{ name }}, {{ shares }})
    module {{ name }}
      include ::SweetTalk::BoundedContext

      SWEETTALK_MEANS     = {{ means }}
      SWEETTALK_WAS       = nil
      SWEETTALK_STORED    = {{ name.stringify.underscore }}
      SWEETTALK_TENANT    = {{ tenant ? tenant : nil }}
      ::SweetTalk.__sweettalk_id_constants({{ name }}, {{ domain }}, {{ tenant ? tenant : nil }},
        {{ declared_ids }})
      {% key = "SWEETTALK_REQUIREMENTS" %}
      SWEETTALK_REQUIREMENTS = {{ @type.has_constant?(key) ? @type.constant(key) : nil }}
      SWEETTALK_CENTRAL   = false
      SWEETTALK_SUBDOMAIN = nil
      SWEETTALK_FOLLOWS   = [] of String
      SWEETTALK_SHARES    = [{{ shared.map(&.names.last.stringify).splat }}] of String
      # The contexts and kernels that share this kernel
      SWEETTALK_SHARED_BY = [{{ sharers.splat }}] of String
      # Its values and aggregates that no other of them uses: two sharers must name each
      SWEETTALK_WORDS     = [{{ checked.splat }}] of String
      SWEETTALK_TEXT      = {{ body ? body.stringify : "" }}
      # Where the kernel is declared, for the context map's refusals
      SWEETTALK_AT        = {{ "#{name.filename.id}:#{name.line_number}:#{name.column_number}" }}
      SWEETTALK_REACTS    = [] of {String, String}
      SWEETTALK_PUBLISHES = nil

      # This kernel's SugarORM schemas, one per aggregate and entity.
      module Rows
      end

      {{ body }}

      __sweettalk_check_queries
    end
  end
end
