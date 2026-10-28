# The whole program: dispatch, the context map and the glossary.
module SweetTalk
  # In a program that requires caramel/tenancy, every domain names its tenant (ADR 0033),
  # so no domain's rows are shared between tenants by omission.
  macro finished
    {% if ::Caramel.has_constant?("Tenancy") %}
      {% for domain in ::SweetTalk.includers %}
        {% unless domain.has_constant?("SWEETTALK_TENANT") %}
          {% raise "#{domain} uses SweetTalk in a program that requires caramel/tenancy: name " +
                   "the tenant before its contexts, as in tenant App::Account, the model the " +
                   "routes' tenant block names; a context every tenant shares takes " +
                   "central: true" %}
        {% end %}
      {% end %}
    {% end %}
  end

  # Enqueues one job per policy, projection and process step that follows the event, then
  # notifies live pages; both run on the current connection, so they commit with the
  # command. The jobs are enqueued in declaration order: the policies of every context
  # and its borders, then the projections' handlers, then the processes' steps; Cold Brew
  # starts them in that order and finishes them in any. A collector `emitted` opened on
  # this fiber sees the event too.
  def self.dispatch(event : ::SweetTalk::Event) : Nil
    __sweettalk_checked
    {% begin %}
      {% owners = ::SweetTalk::BoundedContext.includers + ::SweetTalk::Projection.all_subclasses +
                  ::SweetTalk::Process.all_subclasses %}
      {% for owner in owners %}
        {% for method in owner.class.methods %}
          {% if method.name.starts_with?("__sweettalk_enqueue_") %}
            ::{{ owner }}.{{ method.name }}(event)
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    ::Caramel::ColdBrew.publish(event.__sweettalk_channel, event.__sweettalk_payload)
    ::Fiber.current.__sweettalk_emitted.try &.each(&.<< event)
  end

  # The events `dispatch` sees on this fiber while the block runs, in dispatch order, for
  # a spec that asserts what a command emitted; the jobs are still enqueued. A nested
  # call collects its own, and the outer one sees those events too. A refused command
  # dispatches nothing, so its refusal leaves the block with an empty list.
  def self.emitted(&) : Array(::SweetTalk::Event)
    fiber = ::Fiber.current
    collectors = fiber.__sweettalk_emitted ||= [] of Array(::SweetTalk::Event)
    events = [] of ::SweetTalk::Event
    collectors << events
    begin
      yield
    ensure
      collectors.pop
      fiber.__sweettalk_emitted = nil if collectors.empty?
    end
    events
  end

  # The events of one class among those, typed: `SweetTalk.emitted(Order::Placed) { … }`.
  def self.emitted(kind : E.class, &) : Array(E) forall E
    emitted { yield }.compact_map(&.as?(E))
  end

  @@checked = false

  # Runs the whole-program checks once. Dispatch, every job and every `find?` call it, so
  # a program that runs SweetTalk compiles them even without `boot`.
  def self.__sweettalk_checked : Nil
    @@checked ||= begin
      context_map
      glossary
      __sweettalk_touch
      true
    end
  end

  # Runs the whole-program checks.
  def self.boot : Nil
    context_map
    glossary
    __sweettalk_touch
  end

  # References every command, factory and service, so `crystal build --no-codegen` types
  # their bodies whether or not anything calls them (ADR 0031 decision 10).
  def self.__sweettalk_touch : Nil
    {% begin %}
      {% owners = ::SweetTalk::Aggregate.all_subclasses + ::SweetTalk::BoundedContext.includers %}
      {% for owner in owners %}
        {% for method in owner.class.methods %}
          {% if method.name.starts_with?("__sweettalk_touch_") %}
            ::{{ owner }}.{{ method.name }}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
  end

  # The context map as {from, to, kind} edges, kind "dependency", "event", "outside" or
  # "kernel". Refuses unknown contexts, foreign names and calls outside a border, names a
  # context does not publish, `Rows` named in a context, outside borders named like a
  # context, a kernel named, followed or bordered by one that does not share it, a kernel
  # that names a context, shared by an unknown or silent context or kernel, or holding a
  # word fewer than two of its sharers name, and cycles of dependency edges.
  def self.context_map : Array({String, String, String})
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% names = contexts.map(&.name.split("::").last) %}
    {% follows = {} of Nil => Nil %}
    {% borders = {} of Nil => Nil %}
    {% edges = [] of Nil %}
    {% kernels = contexts.select(&.constant("SWEETTALK_SHARED_BY"))
         .map(&.name.split("::").last) %}
    {% bounded = names.reject { |name| kernels.includes?(name) } %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% follows[short] = context.constant("SWEETTALK_FOLLOWS") %}
      {% borders[short] = context.constants.select(&.starts_with?("SWEETTALK_BORDER_"))
           .map { |constant| context.constant(constant) } %}
      {% for other in follows[short] %}
        {% unless names.includes?(other) %}
          {% raise "#{context.name} follows #{other.id}, but there is no context #{other.id}; " +
                   "contexts: #{bounded.join(", ").id}" %}
        {% end %}
        {% if kernels.includes?(other) %}
          {% raise "#{context.name} follows #{other.id}, a kernel: say shares: #{other.id} " +
                   "and list #{short.id} in its shared_by:" %}
        {% end %}
        {% edge = {short, other, "dependency"} %}
        {% edges << edge unless edges.includes?(edge) %}
      {% end %}
      {% for border in borders[short] %}
        {% unless names.includes?(border[0]) %}
          {% raise "#{context.name} has a border with #{border[0].id}, but there is no context " +
                   "#{border[0].id}; contexts: #{bounded.join(", ").id}" %}
        {% end %}
        {% if kernels.includes?(border[0]) %}
          {% raise "#{context.name} has a border with #{border[0].id}, a kernel: say shares: " +
                   "#{border[0].id} and list #{short.id} in its shared_by:" %}
        {% end %}
        {% calls = border[2].split(border[0] + ".")[1..-1].any? { |piece| piece =~ /\A[a-z_]/ } %}
        {% if border[2].includes?(border[0] + "::") || calls %}
          {% edge = {short, border[0], "dependency"} %}
          {% edges << edge unless edges.includes?(edge) %}
        {% end %}
        {% if border[3] %}
          {% edge = {short, border[0], "event"} %}
          {% edges << edge unless edges.includes?(edge) %}
        {% end %}
      {% end %}
      {% for react in context.constant("SWEETTALK_REACTS") %}
        {% edge = {short, react[0], "event"} %}
        {% if names.includes?(react[0]) && react[0] != short && !edges.includes?(edge) %}
          {% edges << edge %}
        {% end %}
      {% end %}
      {% for constant in context.constants.select(&.starts_with?("SWEETTALK_OUTSIDE_")) %}
        {% system = context.constant(constant)[0] %}
        {% if names.includes?(system) %}
          {% raise "#{context.name} has a border with #{system.id}, outside: \"…\", but " +
                   "#{system.id} is a context: drop outside:, or name the system after " +
                   "what it is" %}
        {% end %}
        {% edge = {short, system, "outside"} %}
        {% edges << edge unless edges.includes?(edge) %}
      {% end %}
    {% end %}
    # Each sharer of a kernel is a context or kernel that says it shares it.
    {% for context in contexts %}
      {% if context.constant("SWEETTALK_SHARED_BY") %}
        {% short = context.name.split("::").last %}
        {% for sharer in context.constant("SWEETTALK_SHARED_BY") %}
          {% unless names.includes?(sharer) %}
            {% raise "#{context.name} is shared by #{sharer.id}, but there is no context or " +
                     "kernel #{sharer.id}" %}
          {% end %}
          {% home = contexts.find { |candidate| candidate.name.split("::").last == sharer } %}
          {% unless home.constant("SWEETTALK_SHARES").includes?(short) %}
            {% raise "#{context.name} is shared by #{sharer.id}, but #{sharer.id} does not say " +
                     "shares: #{short.id}: add shares: #{short.id} to #{sharer.id}, or take " +
                     "#{sharer.id} out of shared_by:" %}
          {% end %}
          {% edge = {sharer, short, "kernel"} %}
          {% edges << edge unless edges.includes?(edge) %}
        {% end %}
      {% end %}
    {% end %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% text = context.constant("SWEETTALK_TEXT") %}
      {% named = text.includes?("Rows::") ||
                 borders[short].any?(&.[1].includes?("Rows::")) %}
      {% if named %}
        {% raise "#{context.name} names Rows, SweetTalk's storage: change an aggregate through " +
                 "its commands, and read it with find" %}
      {% end %}
      {% own_sharers = context.constant("SWEETTALK_SHARED_BY") %}
      {% shares = context.constant("SWEETTALK_SHARES") %}
      {% for other in names %}
        {% if other == short %}
        {% elsif kernels.includes?(other) %}
          {% texts = [text] + borders[short].map(&.[1]) %}
          {% if !shares.includes?(other) && texts.any?(&.includes?(other + "::")) %}
            {% raise "#{context.name} names #{other.id}::, a kernel it does not share: say " +
                     "shares: #{other.id} and list #{short.id} in its shared_by:, or leave " +
                     "#{other.id} to the ones that share it" %}
          {% end %}
        {% elsif own_sharers %}
          {% calls = text.split(other + ".")[1..-1].any? { |piece| piece =~ /\A[a-z_]/ } %}
          {% if text.includes?(other + "::") || calls %}
            {% raise "#{context.name} is a kernel and names #{other.id}: a kernel names no " +
                     "context; move that code into a context that shares #{short.id}" %}
          {% end %}
        {% elsif !follows[short].includes?(other) %}
          {% foreign = text.includes?(other + "::") %}
          {% for border in borders[short] %}
            {% foreign = true if border[0] != other && border[1].includes?(other + "::") %}
          {% end %}
          {% if foreign %}
            {% raise "#{context.name} names #{other.id}:: outside a border: move that code into " +
                     "border #{other.id} do … end, or declare follows: #{other.id}" %}
          {% end %}
          {% texts = [text] %}
          {% for border in borders[short] %}
            {% texts << border[2] if border[0] != other %}
          {% end %}
          {% for piece_text in texts %}
            {% for piece in piece_text.split(other + ".")[1..-1] %}
              {% if piece =~ /\A[a-z_]/ %}
                {% call = piece.gsub(/\A([a-z_]\w*[?!]?)[\s\S]*\z/, "\\1") %}
                {% raise "#{context.name} calls #{other.id}.#{call.id} outside a border: move " +
                         "that call into border #{other.id} do … end, or declare follows: " +
                         "#{other.id}" %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        {% upstream = contexts.find { |candidate| candidate.name.split("::").last == other } %}
        {% offers = other != short && upstream.constant("SWEETTALK_PUBLISHES") %}
        {% if offers %}
          {% offered = offers.join(", ") %}
          {% texts = [text] + borders[short].map(&.[2]) %}
          {% for piece_text in texts %}
            {% for piece in piece_text.split(other + "::")[1..-1] %}
              {% path = piece.gsub(/\A([A-Z]\w*(?:::[A-Z]\w*)*)[\s\S]*\z/, "\\1") %}
              {% found = parse_type(upstream.name.stringify + "::" + path).resolve? %}
              {% open = offers.any? { |offer| path == offer || path.starts_with?(offer + "::") } ||
                        (found && found < ::SweetTalk::Event) %}
              {% unless open %}
                {% raise "#{context.name} names #{other.id}::#{path.id}, which #{other.id} does " +
                         "not publish; it publishes #{offered.id}: use one of those, or publish " +
                         "#{path.id} in #{other.id}" %}
              {% end %}
            {% end %}
            {% for piece in piece_text.split(other + ".")[1..-1] %}
              {% call = piece =~ /\A[a-z_]/ && piece.gsub(/\A([a-z_]\w*[?!]?)[\s\S]*\z/, "\\1") %}
              {% if call && !offers.includes?(call) %}
                {% raise "#{context.name} calls #{other.id}.#{call.id}, which #{other.id} does " +
                         "not publish; it publishes #{offered.id}: use one of those, or publish " +
                         "#{call.id} in #{other.id}" %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    {% dependencies = edges.select { |edge| edge[2] == "dependency" } %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% reach = dependencies.select { |edge| edge[0] == short }.map { |edge| edge[1] } %}
      {% for round in names %}
        {% for edge in dependencies %}
          {% reach << edge[1] if reach.includes?(edge[0]) && !reach.includes?(edge[1]) %}
        {% end %}
      {% end %}
      {% if reach.includes?(short) %}
        {% raise "the context map runs in a circle of dependencies through #{context.name}: " +
                 "follows: and borders that name another context's types must point one way; " +
                 "reacting to another context's events in a border is allowed" %}
      {% end %}
    {% end %}
    # A kernel's words that fewer than two of its sharers name, by the text they write.
    {% for context in contexts %}
      {% if context.constant("SWEETTALK_SHARED_BY") %}
        {% short = context.name.split("::").last %}
        {% for word in context.constant("SWEETTALK_WORDS") %}
          {% users = [] of Nil %}
          {% for sharer in context.constant("SWEETTALK_SHARED_BY") %}
            {% home = contexts.find { |candidate| candidate.name.split("::").last == sharer } %}
            {% texts = [home.constant("SWEETTALK_TEXT")] + borders[sharer].map(&.[1]) %}
            {% named = false %}
            {% for text in texts %}
              {% for piece in text.split(short + "::")[1..-1] %}
                {% named = true if piece.gsub(/\A([A-Z]\w*)[\s\S]*\z/, "\\1") == word %}
              {% end %}
            {% end %}
            {% users << sharer if named %}
          {% end %}
          {% if users.size == 1 %}
            {% raise "#{context.name}::#{word.id} is named only by #{users[0].id}: a kernel " +
                     "holds what two or more of its sharers name; move #{word.id} into " +
                     "#{users[0].id}" %}
          {% elsif users.empty? %}
            {% raise "#{context.name}::#{word.id} is named by none of its sharers: a kernel " +
                     "holds what two or more of its sharers name; remove #{word.id} from " +
                     "#{short.id}" %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    edges = [] of {String, String, String}
    {% for edge in edges %}
      edges << { {{ edge[0] }}, {{ edge[1] }}, {{ edge[2] }} }
    {% end %}
    edges
    {% end %}
  end

  # The ubiquitous language: every context, kernel, service, outside system, value,
  # aggregate, entity, event, projection, specification and process with its meaning, and
  # its context's subdomain.
  def self.glossary : Array(::SweetTalk::Term)
    terms = [] of ::SweetTalk::Term
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% part = context.constant("SWEETTALK_SUBDOMAIN") %}
      {% kind = context.constant("SWEETTALK_SHARED_BY") ? "kernel" : "context" %}
      terms << ::SweetTalk::Term.new({{ kind }}, {{ short }}, {{ short }},
        {{ context.constant("SWEETTALK_MEANS") }}, {{ part }})
      {% for constant in context.constants.select(&.starts_with?("SWEETTALK_SERVICE_")) %}
        {% service = context.constant(constant) %}
        terms << ::SweetTalk::Term.new("service", {{ service[0] }}, {{ short }}, {{ service[1] }},
          {{ part }})
      {% end %}
      {% for constant in context.constants.select(&.starts_with?("SWEETTALK_OUTSIDE_")) %}
        {% system = context.constant(constant) %}
        terms << ::SweetTalk::Term.new("outside", {{ system[0] }}, {{ short }}, {{ system[1] }},
          {{ part }})
      {% end %}
    {% end %}
    {% kinds = [{"value", ::SweetTalk::Value}, {"value", ::SweetTalk::Composite},
                {"aggregate", ::SweetTalk::Aggregate}, {"entity", ::SweetTalk::Entity},
                {"event", ::SweetTalk::Event}, {"projection", ::SweetTalk::Projection},
                {"process", ::SweetTalk::Process},
                {"specification", ::SweetTalk::Specification}] %}
    {% for pair in kinds %}
      {% for type in pair[1].all_subclasses %}
        {% if type.has_constant?("SWEETTALK_MEANS") %}
          {% home = contexts.find { |context| type.name.starts_with?("#{context.name}::") } %}
          {% full = type.name.stringify %}
          {% name = home ? full[home.name.stringify.size + 2..] : full %}
          {% within = home ? home.name.split("::").last : "" %}
          {% part = home ? home.constant("SWEETTALK_SUBDOMAIN") : nil %}
          terms << ::SweetTalk::Term.new({{ pair[0] }}, {{ name }}, {{ within }},
            {{ type.constant("SWEETTALK_MEANS") }}, {{ part }})
        {% end %}
      {% end %}
    {% end %}
    {% end %}
    terms
  end
end

class Fiber
  # The open `SweetTalk.emitted` collectors on this fiber, innermost last.
  property __sweettalk_emitted : Array(Array(::SweetTalk::Event))? = nil
end
