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
        {% unless node.is_a?(Call) && %w[value aggregate].includes?(node.name.stringify) %}
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
      {% unless node.args.empty? %}
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
      SWEETTALK_CENTRAL   = false
      SWEETTALK_SUBDOMAIN = nil
      SWEETTALK_FOLLOWS   = [] of String
      SWEETTALK_SHARES    = [{{ shared.map(&.names.last.stringify).splat }}] of String
      # The contexts and kernels that share this kernel
      SWEETTALK_SHARED_BY = [{{ sharers.splat }}] of String
      # Its values and aggregates that no other of them uses: two sharers must name each
      SWEETTALK_WORDS     = [{{ checked.splat }}] of String
      SWEETTALK_TEXT      = {{ body ? body.stringify : "" }}
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
