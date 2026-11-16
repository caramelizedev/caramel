# `frappe sweettalk:glossary` and `frappe sweettalk:contexts`: the detailed glossary, every
# term with the facts its declaration holds, and the context map (ADR 0036). The
# application answers both: Frappé compiles it and runs its command, which prints what the
# person or the agent reads.
module SweetTalk
  GLOSSARY_USAGE = "Usage: sweettalk:glossary [--json]"
  CONTEXTS_USAGE = "Usage: sweettalk:contexts [--mermaid]"

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

  # Prints the glossary for `sweettalk:glossary`: as Markdown, or with `--json` the report
  # and the context map as one JSON document. Returns the exit status: 0, or 2 for any
  # other argument.
  def self.__sweettalk_print_glossary(arguments : Array(String),
                                      output : IO,
                                      errors : IO) : Int32
    if arguments.empty?
      output.print(__sweettalk_glossary_markdown(report))
    elsif arguments == ["--json"]
      __sweettalk_glossary_json(output)
    else
      errors.puts GLOSSARY_USAGE
      return 2
    end
    0
  end

  # Prints the context map for `sweettalk:contexts`: each context and kernel with the edges
  # that leave it, or with `--mermaid` a Mermaid flowchart. Returns the exit status: 0, or
  # 2 for any other argument.
  def self.__sweettalk_print_contexts(arguments : Array(String),
                                      output : IO,
                                      errors : IO) : Int32
    if arguments.empty?
      output.print(__sweettalk_map_text(report, context_map))
    elsif arguments == ["--mermaid"]
      output.print(__sweettalk_map_mermaid(report, context_map))
    else
      errors.puts CONTEXTS_USAGE
      return 2
    end
    0
  end

  # *entries* as Markdown: one section per context or kernel, its meaning, its follows: and
  # shares:, then a table of its terms with their facts.
  def self.__sweettalk_glossary_markdown(entries : Array(Entry)) : String
    String.build do |io|
      io << "# Glossary\n"
      entries.group_by(&.term.context).each do |name, held|
        __sweettalk_glossary_section(io, name, held)
      end
    end
  end

  # The context map as text: each context and kernel of *entries* with the *edges* that
  # leave it.
  def self.__sweettalk_map_text(entries : Array(Entry),
                                edges : Array({String, String, String})) : String
    String.build do |io|
      __sweettalk_modules(entries).each do |name|
        io << name << "\n"
        edges.each do |(from, to, kind)|
          io << "  " << __sweettalk_edge_verb(kind) << " " << to << "\n" if from == name
        end
      end
    end
  end

  # The context map as a Mermaid flowchart: a dependency is an arrow, an event a dotted
  # arrow, a shared kernel a line and an outside system a hexagon.
  def self.__sweettalk_map_mermaid(entries : Array(Entry),
                                   edges : Array({String, String, String})) : String
    String.build do |io|
      io << "flowchart LR\n"
      __sweettalk_modules(entries).each { |name| io << "  " << name << "\n" }
      edges.each do |(from, to, kind)|
        verb = __sweettalk_edge_verb(kind)
        case kind
        when "dependency" then io << "  " << from << " -->|" << verb << "| " << to << "\n"
        when "event"      then io << "  " << from << " -.->|" << verb << "| " << to << "\n"
        when "kernel"     then io << "  " << from << " ---|" << verb << "| " << to << "\n"
        else
          io << "  " << from << " -->|" << verb << "| " << to << "{{" << to << "}}\n"
        end
      end
    end
  end

  # What an edge of the context map says of the module it leaves, by its kind.
  private def self.__sweettalk_edge_verb(kind : String) : String
    case kind
    when "dependency" then "depends on"
    when "event"      then "reacts to"
    when "kernel"     then "shares"
    else                   "calls"
    end
  end

  # The name of each context and kernel among *entries*, in their order.
  private def self.__sweettalk_modules(entries : Array(Entry)) : Array(String)
    entries.select { |entry| __sweettalk_module?(entry) }.map(&.term.name)
  end

  private def self.__sweettalk_module?(entry : Entry) : Bool
    {"context", "kernel"}.includes?(entry.term.kind)
  end

  # One section of the Markdown glossary: the context or kernel *name* with the terms it
  # holds, or the terms outside any context.
  private def self.__sweettalk_glossary_section(io : IO, name : String, held : Array(Entry)) : Nil
    head = held.find { |entry| __sweettalk_module?(entry) }
    io << "\n## " << (name.empty? ? "Outside any context" : name)
    if head
      term = head.term
      subdomain = term.subdomain
      io << " (" << term.kind << (subdomain ? ", #{subdomain}" : "") << ")"
      io << "\n\n" << term.means << "\n"
      facts = __sweettalk_facts_text(head.facts)
      io << "\n" << facts << "\n" unless facts.empty?
    else
      io << "\n"
    end
    rows = head ? held.reject { |entry| entry == head } : held
    return if rows.empty?
    io << "\n| Term | Kind | Means | Facts |\n| --- | --- | --- | --- |\n"
    rows.each do |entry|
      io << "| " << __sweettalk_cell(entry.term.name) << " | " << entry.term.kind << " | "
      io << __sweettalk_cell(entry.term.means) << " | "
      io << __sweettalk_cell(__sweettalk_facts_text(entry.facts)) << " |\n"
    end
  end

  private def self.__sweettalk_facts_text(facts : Hash(String, Array(String))) : String
    listed = facts.reject { |_, values| values.empty? }
    listed.join("; ") { |name, values| "#{name}: #{values.join(", ")}" }
  end

  private def self.__sweettalk_cell(text : String) : String
    text.gsub('|', "\\|").gsub('\n', ' ')
  end

  # The report and the context map as one JSON document, on a line of its own.
  private def self.__sweettalk_glossary_json(output : IO) : Nil
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

Caramel::Crema.command("sweettalk:glossary", "sweettalk:glossary [--json]") do |arguments|
  SweetTalk.__sweettalk_print_glossary(arguments, STDOUT, STDERR)
end

Caramel::Crema.command("sweettalk:contexts", "sweettalk:contexts [--mermaid]") do |arguments|
  SweetTalk.__sweettalk_print_contexts(arguments, STDOUT, STDERR)
end
