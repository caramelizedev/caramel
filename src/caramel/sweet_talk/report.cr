# `frappe glossary`: the detailed glossary, every term with the facts its declaration
# holds, and the context map (ADR 0059). The application answers it; Frappé compiles the
# application and asks.
module SweetTalk
  GLOSSARY_USAGE = "Usage: glossary"

  # A glossary term with the facts its declaration holds, by name: a context's `follows`
  # and `shares`, a kernel's `shared_by`, a value's `wraps`, `at_least`, `at_most` and
  # `one_of`, an aggregate's or a process's `states` and `moves`, an event's `handlers` in
  # the order they run, and a unit's `changes`, `locks` and `once_by`.
  record Entry, term : Term, facts : Hash(String, Array(String))

  # A term's kind, context and name, which the report keys its facts by.
  alias TermKey = {String, String, String}

  # The glossary, each term with its facts, in the glossary's order. Every fact is read
  # from the declarations when the program compiles, as the glossary is.
  def self.report : Array(Entry)
    facts = __sweettalk_report_facts
    __sweettalk_handlers.each do |key, handlers|
      (facts[key] ||= {} of String => Array(String))["handlers"] = handlers
    end
    glossary.map do |term|
      Entry.new(term, facts[{term.kind, term.context, term.name}]? || {} of String => Array(String))
    end
  end

  # Prints the report and the context map as one JSON document for `glossary`; returns the
  # exit status: 0, or 2 for any argument.
  def self.__sweettalk_print_glossary(arguments : Array(String), output : IO, errors : IO) : Int32
    unless arguments.empty?
      errors.puts GLOSSARY_USAGE
      return 2
    end
    JSON.build(output) do |json|
      json.object do
        json.field("terms") { __sweettalk_report_json(json) }
        json.field("map") do
          json.array do
            context_map.each { |edge| json.array { edge.each { |part| json.string(part) } } }
          end
        end
      end
    end
    output.puts
    0
  end

  private def self.__sweettalk_report_json(json : JSON::Builder) : Nil
    json.array do
      report.each do |entry|
        term = entry.term
        json.object do
          json.field("kind", term.kind)
          json.field("name", term.name)
          json.field("context", term.context)
          json.field("means", term.means)
          json.field("subdomain", term.subdomain)
          json.field("facts") do
            json.object do
              entry.facts.each { |name, values| json.field(name) { values.to_json(json) } }
            end
          end
        end
      end
    end
  end

  # Each event's handlers, keyed as its glossary term, in the order they run: those without
  # `after:` in declaration order, each followed by the handlers that say `after:` it.
  private def self.__sweettalk_handlers : Hash(TermKey, Array(String))
    found = {} of TermKey => Array({String, String, String?})
    __sweettalk_handler_entries.each do |(key, owner, label, after)|
      (found[key] ||= [] of {String, String, String?}) << {owner, label, after}
    end
    found.transform_values do |handlers|
      ordered = [] of {String, String, String?}
      handlers.each { |handler| __sweettalk_place(handler, handlers, ordered) unless handler[2] }
      handlers.each { |handler| ordered << handler unless ordered.includes?(handler) }
      ordered.map { |handler| handler[2] ? "#{handler[1]}, after: #{handler[2]}" : handler[1] }
    end
  end

  private def self.__sweettalk_place(handler : {String, String, String?},
                                     handlers : Array({String, String, String?}),
                                     ordered : Array({String, String, String?})) : Nil
    return if ordered.includes?(handler)
    ordered << handler
    handlers.each do |follower|
      __sweettalk_place(follower, handlers, ordered) if follower[2] == handler[0]
    end
  end

  # {event's term key, owner, label, after:} of every handler, in declaration order.
  private def self.__sweettalk_handler_entries : Array({TermKey, String, String, String?})
    entries = [] of {TermKey, String, String, String?}
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% owners = contexts + ::SweetTalk::Projection.all_subclasses +
                ::SweetTalk::Process.all_subclasses %}
    {% for owner in owners %}
      {% scopes = owner.name.split("::") %}
      {% short = scopes.last %}
      {% for constant in owner.constants.select(&.starts_with?("SWEETTALK_HANDLER_")) %}
        {% entry = owner.constant(constant) %}
        {% event = nil %}
        {% for depth in 0..scopes.size %}
          {% prefix = scopes[0...(scopes.size - depth)] %}
          {% found = event ? nil : parse_type("::" + (prefix + [entry[0]]).join("::")).resolve? %}
          {% event = found if found %}
        {% end %}
        {% if event %}
          {% home = contexts.find { |context| event.name.starts_with?("#{context.name}::") } %}
          {% full = event.name.stringify %}
          {% name = home ? full[home.name.stringify.size + 2..] : full %}
          {% within = home ? home.name.split("::").last : "" %}
          {% label = entry[6].starts_with?("border ") ? "#{short.id}, #{entry[6].id}" : short %}
          {% after = entry[3] ? entry[3].split("::").last : nil %}
          entries << { {"event", {{ within }}, {{ name }}}, {{ short }}, {{ label }}, {{ after }} }
        {% end %}
      {% end %}
    {% end %}
    {% end %}
    entries
  end

  # The facts each term's declaration holds, keyed {kind, context, name} as its term.
  private def self.__sweettalk_report_facts : Hash(TermKey, Hash(String, Array(String)))
    facts = {} of TermKey => Hash(String, Array(String))
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% sharers = context.constant("SWEETTALK_SHARED_BY") %}
      {% kind = sharers ? "kernel" : "context" %}
      facts[{ {{ kind }}, {{ short }}, {{ short }} }] = {
        "follows" => {{ context.constant("SWEETTALK_FOLLOWS") }},
        "shares"  => {{ context.constant("SWEETTALK_SHARES") }},
        {% if sharers %}
          "shared_by" => {{ sharers }},
        {% end %}
      } of String => Array(String)
      {% for constant in context.constants.select(&.starts_with?("SWEETTALK_UNIT_")) %}
        {% unit = context.constant(constant) %}
        facts[{"unit", {{ short }}, {{ unit[0] }}}] = {
          "changes" => [{{ unit[4].split(", ").reject(&.empty?).splat }}] of String,
          "locks"   => [{{ unit[5].split(", ").reject(&.empty?).splat }}] of String,
          {% if unit[3] %}
            "once_by" => [{{ unit[3] }}],
          {% end %}
        } of String => Array(String)
      {% end %}
    {% end %}
    {% kinds = [{"value", ::SweetTalk::Value}, {"aggregate", ::SweetTalk::Aggregate},
                {"process", ::SweetTalk::Process}] %}
    {% for pair in kinds %}
      {% for type in pair[1].all_subclasses %}
        {% if type.has_constant?("SWEETTALK_MEANS") %}
          {% home = contexts.find { |context| type.name.starts_with?("#{context.name}::") } %}
          {% full = type.name.stringify %}
          {% name = home ? full[home.name.stringify.size + 2..] : full %}
          {% within = home ? home.name.split("::").last : "" %}
          {% held = {} of Nil => Nil %}
          {% if type.has_constant?("SWEETTALK_WRAPS") %}
            {% held["wraps"] = [type.constant("SWEETTALK_WRAPS").gsub(/\A::/, "")] %}
          {% end %}
          {% if type.has_constant?("SWEETTALK_BOUNDS") %}
            {% bounds = type.constant("SWEETTALK_BOUNDS") %}
            {% held["at_least"] = [bounds[0]] if bounds[0] %}
            {% held["at_most"] = [bounds[1]] if bounds[1] %}
          {% end %}
          {% if type.has_constant?("SWEETTALK_ONE_OF") %}
            {% held["one_of"] = type.constant("SWEETTALK_ONE_OF") %}
          {% end %}
          {% if type.has_constant?("SWEETTALK_MOVES") %}
            {% held["states"] = type.constant("SWEETTALK_MOVES") %}
            {% held["moves"] = type.constant("SWEETTALK_STEPS") %}
          {% end %}
          {% unless held.empty? %}
            facts[{ {{ pair[0] }}, {{ within }}, {{ name }} }] = {
              {% for fact, values in held %}
                {{ fact }} => [{{ values.splat }}] of String,
              {% end %}
            } of String => Array(String)
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    {% end %}
    facts
  end
end

Caramel::Crema.command("glossary", "glossary") do |arguments|
  SweetTalk.__sweettalk_print_glossary(arguments, STDOUT, STDERR)
end
