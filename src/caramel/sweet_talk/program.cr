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
  # command.
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
  end

  @@checked = false

  # Runs the whole-program checks once. Dispatch, every job and every `find?` call it, so
  # a program that runs SweetTalk compiles them even without `boot`.
  def self.__sweettalk_checked : Nil
    @@checked ||= begin
      context_map
      glossary
      true
    end
  end

  # Runs the whole-program checks.
  def self.boot : Nil
    context_map
    glossary
  end

  # The context map as {from, to, kind} edges, kind "dependency" or "event". Refuses
  # unknown contexts, foreign names outside a border, `Rows` named in a context, and
  # cycles of dependency edges.
  def self.context_map : Array({String, String, String})
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% names = contexts.map(&.name.split("::").last) %}
    {% follows = {} of Nil => Nil %}
    {% borders = {} of Nil => Nil %}
    {% edges = [] of Nil %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% follows[short] = context.constant("SWEETTALK_FOLLOWS") %}
      {% borders[short] = context.constants.select(&.starts_with?("SWEETTALK_BORDER_"))
           .map { |constant| context.constant(constant) } %}
      {% for other in follows[short] %}
        {% unless names.includes?(other) %}
          {% raise "#{context.name} follows #{other.id}, but there is no context #{other.id}; " +
                   "contexts: #{names.join(", ").id}" %}
        {% end %}
        {% edge = {short, other, "dependency"} %}
        {% edges << edge unless edges.includes?(edge) %}
      {% end %}
      {% for border in borders[short] %}
        {% unless names.includes?(border[0]) %}
          {% raise "#{context.name} has a border with #{border[0].id}, but there is no context " +
                   "#{border[0].id}; contexts: #{names.join(", ").id}" %}
        {% end %}
        {% if border[2].includes?(border[0] + "::") %}
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
      {% for other in names %}
        {% if other != short && !follows[short].includes?(other) %}
          {% foreign = text.includes?(other + "::") %}
          {% for border in borders[short] %}
            {% foreign = true if border[0] != other && border[1].includes?(other + "::") %}
          {% end %}
          {% if foreign %}
            {% raise "#{context.name} names #{other.id}:: outside a border: move that code into " +
                     "border #{other.id} do … end, or declare follows: #{other.id}" %}
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
    edges = [] of {String, String, String}
    {% for edge in edges %}
      edges << { {{ edge[0] }}, {{ edge[1] }}, {{ edge[2] }} }
    {% end %}
    edges
    {% end %}
  end

  # The ubiquitous language: every context, service, value, aggregate, entity, event,
  # projection and process with its meaning, and its context's subdomain.
  def self.glossary : Array(::SweetTalk::Term)
    terms = [] of ::SweetTalk::Term
    {% begin %}
    {% contexts = ::SweetTalk::BoundedContext.includers %}
    {% for context in contexts %}
      {% short = context.name.split("::").last %}
      {% part = context.constant("SWEETTALK_SUBDOMAIN") %}
      terms << ::SweetTalk::Term.new("context", {{ short }}, {{ short }},
        {{ context.constant("SWEETTALK_MEANS") }}, {{ part }})
      {% for constant in context.constants.select(&.starts_with?("SWEETTALK_SERVICE_")) %}
        {% service = context.constant(constant) %}
        terms << ::SweetTalk::Term.new("service", {{ service[0] }}, {{ short }}, {{ service[1] }},
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
