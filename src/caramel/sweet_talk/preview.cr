# Preview and commit (ADR 0060): one body run dry to show what it would record, then run
# again and compared inside the transaction that keeps it.
module SweetTalk
  # A preview's fingerprint: SHA-256, as 64 hex digits, over the canonical form of what a
  # run would record. A form carries it in a hidden field, so it binds as a contract field.
  struct Fingerprint
    include ::Caramel::FieldValue(String)

    getter hex : String

    def initialize(@hex : String)
    end

    # Builds the fingerprint a contract field binds, or yields why it is not one.
    def self.from_field(raw : String, & : String ->) : self?
      return new(raw) if raw.matches?(/\A[0-9a-f]{64}\z/)
      yield "is not a preview's fingerprint"
      nil
    end

    def to_s(io : IO) : Nil
      io << hex
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(hex)
    end
  end

  # What a run would record: its events, in dispatch order; each aggregate it changed,
  # before and after; the `warn` lines that held; the sentences of a unit's `never` and
  # `always` lines that failed; the sentence a commit would be refused with; and the
  # fingerprint over all of it but the blockers after the first. Ids the run made read as
  # `new Receipt #1`, in the order it made them, and instants are left out, so two runs that
  # would record the same agree.
  class Preview
    # One event: its class, its subject as `Tea 4` or `new Receipt #1` (nil for a
    # context's event), and its fields in canonical form.
    record Emitted, name : String, subject : String?, fields : JSON::Any do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field("event", name)
          json.field("subject", subject)
          json.field("fields", fields)
        end
      end
    end

    # One aggregate the run changed: its class, its subject, what is stored now (nil for one
    # the run made) and what the run would leave. *ended* says it moved into a state no
    # move leaves.
    record Change, aggregate : String, subject : String, before : JSON::Any?,
      after : JSON::Any, ended : Bool do
      def made? : Bool
        before.nil?
      end

      def removed? : Bool
        after["removed"].as_bool && !before.try(&.["removed"].as_bool)
      end

      # A move into a state no move leaves: the after-state is final and the state changed.
      def ended? : Bool
        ended && after["state"]? != before.try(&.["state"]?)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field("aggregate", aggregate)
          json.field("subject", subject)
          json.field("before", before)
          json.field("after", after)
        end
      end
    end

    # One line of a summary: the aggregate's name, what happened (an event's name,
    # `removed`, `moved to <state>` or `changed`), the subjects it happened to, and whether it
    # cannot be undone by a later command.
    record Group, aggregate : String, what : String, subjects : Array(String),
      final : Bool do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field("aggregate", aggregate)
          json.field("what", what)
          json.field("subjects", subjects)
          json.field("final", final)
        end
      end
    end

    getter events : Array(Emitted)
    getter warnings : Array(String)
    # The sentences of a unit's `never` and `always` lines that failed, in the order they ran.
    getter blockers : Array(String)
    # The sentence a commit would be refused with: the body's refusal, or the first blocker.
    getter refusal : String?
    getter fingerprint : Fingerprint
    @rows : Array(Change)

    def initialize(@events : Array(Emitted), @rows : Array(Change), @warnings : Array(String),
                   @refusal : String?, @blockers : Array(String) = [] of String)
      @fingerprint = Fingerprint.new(Digest::SHA256.hexdigest(canonical))
    end

    # Each aggregate the run changed, in the order it first touched them; one it touched
    # and left as it was is not listed, though the fingerprint covers it.
    def changes : Array(Change)
      @rows.reject { |row| row.before == row.after }
    end

    # The run as a person reads it: grouped by aggregate and what happened, removals and
    # moves into a final state first, then each kind of event and each change no event
    # names, in the order they happened.
    def summary : Array(Group)
      groups = [] of Group
      changed = changes
      changed.select(&.removed?).each do |row|
        add(groups, row.aggregate, "removed", row.subject, true)
      end
      changed.select(&.ended?).each do |row|
        add(groups, row.aggregate, "moved to #{row.after["state"]}", row.subject, true)
      end
      @events.each do |event|
        parts = event.name.split("::")
        add(groups, parts[-2], parts[-1], event.subject, false)
      end
      named = @events.compact_map(&.subject)
      changed.each do |row|
        next if row.removed? || row.ended? || named.includes?(row.subject)
        add(groups, row.aggregate, "changed", row.subject, false)
      end
      groups.select(&.final) + groups.reject(&.final)
    end

    # True when the run would record nothing: no event and no change.
    def empty? : Bool
      @events.empty? && changes.empty?
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field("fingerprint", @fingerprint)
        json.field("refusal", @refusal)
        json.field("warnings", @warnings)
        json.field("blockers", @blockers)
        json.field("events", @events)
        json.field("changes", changes)
        json.field("summary", summary)
      end
    end

    private def add(groups : Array(Group), aggregate : String, what : String,
                    subject : String?, final : Bool) : Nil
      short = aggregate.split("::").last
      index = groups.index { |group| group.aggregate == short && group.what == what }
      group = index ? groups[index] : Group.new(short, what, [] of String, final)
      group.subjects << subject if subject && !group.subjects.includes?(subject)
      groups << group unless index
    end

    # What the fingerprint hashes: events, the after-state of every row the run touched,
    # the warnings and the refusal, as JSON.
    private def canonical : String
      JSON.build do |json|
        json.object do
          json.field("events", @events)
          json.field("rows") do
            json.array do
              @rows.each do |row|
                json.array do
                  json.string(row.aggregate)
                  json.string(row.subject)
                  row.after.to_json(json)
                end
              end
            end
          end
          json.field("warnings", @warnings)
          json.field("refusal", @refusal)
        end
      end
    end
  end

  # A preview that keeps what its block returned: `value`, nil when the body was refused.
  # The value stays out of the fingerprint and `to_json`.
  class Preview::Of(T) < Preview
    getter value : T?

    def initialize(@value : T?, events : Array(Emitted), rows : Array(Change),
                   warnings : Array(String), refusal : String?, blockers : Array(String))
      super(events, rows, warnings, refusal, blockers)
    end
  end

  # The world moved between a preview and its commit: the same body would now record
  # something else. Nothing was written. It carries the fresh preview, which a form shows
  # again with its fingerprint; an action that does not rescue it answers 422 (ADR 0034).
  class Stale < Refusal
    getter preview : Preview

    def initialize(@preview : Preview)
      super("This changed since it was previewed. Review it again.")
    end
  end

  # One `preview` or `commit` running on this fiber: the aggregates its commands loaded and
  # saved, the rows it made with the placeholder each reads as, and the warnings that held.
  class Run
    getter? dry : Bool
    getter warnings = [] of String
    # The sentences of a unit's `never` and `always` lines that failed in a dry run, in the
    # order they ran.
    getter blockers = [] of String
    getter events = [] of Event
    # Every aggregate instance a command loaded or saved, which reload after a dry run.
    getter instances = [] of Aggregate
    # {type, raw id} of each aggregate the run touched, its before-state, its latest instance
    @touched = [] of {String, ::SugarORM::Key, JSON::Any?, Aggregate}
    @made = {} of {String, ::SugarORM::Key} => String
    @counts = Hash(String, Int32).new(0)

    def initialize(@dry : Bool)
    end

    # Notes *aggregate*, just loaded under its lock by a command, as it is stored.
    def before(aggregate : Aggregate) : Nil
      remember(aggregate)
      key = {aggregate.class.name, aggregate.__sweettalk_raw_id.as(::SugarORM::Key)}
      return if @touched.any? { |entry| {entry[0], entry[1]} == key }
      @touched << {key[0], key[1], canon(aggregate), aggregate}
    end

    # Notes *aggregate*, just saved: one with no before-state was made by this run.
    def saved(aggregate : Aggregate) : Nil
      remember(aggregate)
      key = {aggregate.class.name, aggregate.__sweettalk_raw_id.as(::SugarORM::Key)}
      if index = @touched.index { |entry| {entry[0], entry[1]} == key }
        entry = @touched[index]
        @touched[index] = {entry[0], entry[1], entry[2], aggregate}
      else
        made(key[0], key[1])
        @touched << {key[0], key[1], nil, aggregate}
      end
    end

    # Names the row an entity was just inserted as, in creation order.
    def made(entity : Entity) : Nil
      made(entity.class.name, entity.__sweettalk_raw_id)
    end

    # Writes *raw*, an id of *type*, as the placeholder the run gave it, or as its number
    # or UUID.
    def id(json : JSON::Builder, type : String, raw : ::SugarORM::Key) : Nil
      if placeholder = @made[{type, raw}]?
        json.string(placeholder)
      else
        raw.to_json(json)
      end
    end

    # A subject as a person reads it: `Tea 4`, or `new Receipt #1` for one the run made.
    def subject(type : String, raw : ::SugarORM::Key) : String
      @made[{type, raw}]? || "#{type.split("::").last} #{raw}"
    end

    # What the run would record, or only *refusal* when the body was refused.
    def preview(refusal : String?) : Preview
      Preview.new(*parts(refusal))
    end

    # The same, keeping *value*, what the body returned as a *type*, nil when it was refused.
    def preview(refusal : String?, type : T.class, value : T?) : Preview::Of(T) forall T
      Preview::Of(T).new(value, *parts(refusal))
    end

    # A preview's events, rows, warnings, refusal and blockers: the body's refusal alone,
    # or what the run recorded with its first blocker as the refusal.
    private def parts(refusal : String?)
      if refusal
        return {[] of Preview::Emitted, [] of Preview::Change, [] of String,
                refusal.as(String?), [] of String}
      end
      emitted = @events.map do |event|
        Preview::Emitted.new(event.class.name, event.__sweettalk_canon_subject(self),
          JSON.parse(JSON.build { |json| event.__sweettalk_canon(json, self) }))
      end
      rows = @touched.map do |entry|
        Preview::Change.new(entry[0], subject(entry[0], entry[1]), entry[2], canon(entry[3]),
          entry[3].__sweettalk_ended?)
      end
      {emitted, rows, @warnings.dup, @blockers.first?, @blockers.dup}
    end

    private def canon(aggregate : Aggregate) : JSON::Any
      JSON.parse(JSON.build { |json| aggregate.__sweettalk_canon(json, self) })
    end

    private def made(type : String, raw : ::SugarORM::Key) : Nil
      short = type.split("::").last
      @made[{type, raw}] ||= "new #{short} ##{@counts[type] += 1}"
    end

    private def remember(aggregate : Aggregate) : Nil
      @instances << aggregate unless @instances.any?(&.same?(aggregate))
    end
  end

  # Why `Caramel::Outbound` refuses inside a preview's body.
  OUTSIDE_IN_PREVIEW = "Caramel::Outbound is refused while SweetTalk.preview runs: the " \
                       "preview rolls back, and a call outside cannot be taken back; call " \
                       "the outside system before the change, or from a whenever on its event"

  # Runs the block dry: in a transaction that always rolls back, with the commit's locks,
  # and `Caramel::Outbound` refused. Answers what it would record and what the block
  # returned; a refusal raised by the body answers its sentence alone, with no value.
  # Every aggregate instance a command loaded or saved reloads what is stored afterwards.
  def self.preview(& : -> T) : Preview::Of(T) forall T
    run = Run.new(dry: true)
    preview = nil
    begin
      ::SugarORM::Repo.transaction do
        begin
          value = __sweettalk_running(run) { yield }
          preview = run.preview(nil, T, value)
        rescue error : Refusal
          preview = run.preview(error.message || "", T, nil)
        end
        ::SugarORM::Repo.rollback
      end
    ensure
      run.instances.each(&.__sweettalk_reload)
    end
    preview || raise NilAssertionError.new("SweetTalk.preview finished without a preview")
  end

  # Runs the block, compares what it recorded with *expected*, a preview's fingerprint,
  # before the transaction ends, and keeps it only when they agree. A difference raises
  # `Stale` with the fresh preview, and nothing is written. A `warn` line that holds is
  # confirmed by the fingerprint. Returns the block's value.
  def self.commit(expected : Fingerprint, &)
    run = Run.new(dry: false)
    # The block's value in a tuple, so a block that returns nil is told from no value.
    outcome = nil
    begin
      ::SugarORM::Repo.transaction do
        outcome = {__sweettalk_running(run) { yield }}
        fresh = run.preview(nil)
        raise Stale.new(fresh) unless fresh.fingerprint == expected
      end
    rescue error
      run.instances.each(&.__sweettalk_reload)
      raise error
    end
    (outcome || raise NilAssertionError.new("SweetTalk.commit finished without a value"))[0]
  end

  # A unit's `warn` line that held: a run keeps its sentence, and a plain call is refused
  # with it.
  def self.__sweettalk_warn(sentence : String) : Nil
    run = ::Fiber.current.__sweettalk_run
    raise Refusal.new(sentence) unless run
    run.warnings << sentence unless run.warnings.includes?(sentence)
  end

  # A unit's `never` or `always` line, run after the body; the block answers whether the
  # rule holds. A rule that fails refuses with its sentence, except in a preview: there its
  # sentence joins the blockers and the next line runs. In a preview that already holds a
  # blocker, a line whose block raises is skipped, since the commit refuses before it.
  def self.__sweettalk_rule(sentence : String, on : Symbol?, & : -> Bool) : Nil
    run = ::Fiber.current.__sweettalk_run
    unless run && run.dry?
      raise Refusal.new(sentence, on: on) unless yield
      return
    end
    begin
      return if yield
    rescue error
      raise error if run.blockers.empty?
      return
    end
    run.blockers << sentence unless run.blockers.includes?(sentence)
  end

  private def self.__sweettalk_running(run : Run, &)
    fiber = ::Fiber.current
    if fiber.__sweettalk_run
      raise Boundary.new("SweetTalk.preview or commit called inside another: preview or " \
                         "commit the whole change once")
    end
    fiber.__sweettalk_run = run
    outcome = nil
    begin
      run.events.concat(emitted do
        outcome = if run.dry?
                    {::Caramel::Outbound.refusing(OUTSIDE_IN_PREVIEW) { yield }}
                  else
                    {yield}
                  end
      end)
    ensure
      fiber.__sweettalk_run = nil
    end
    (outcome || raise NilAssertionError.new("SweetTalk ran no body"))[0]
  end

  # One fact in canonical form: as `pack` writes it, but an id the run made as its
  # placeholder, an entity by its placeholder or id, and a time as `"time"`, since the
  # machine's clock differs between runs.
  def self.canon(json : JSON::Builder, value : Identity, run : Run) : Nil
    run.id(json, value.class.name.rchop("::Id"), value.raw)
  end

  def self.canon(json : JSON::Builder, value : Entity, run : Run) : Nil
    value.__sweettalk_canon(json, run)
  end

  def self.canon(json : JSON::Builder, value : Array, run : Run) : Nil
    json.array { value.each { |item| canon(json, item, run) } }
  end

  def self.canon(json : JSON::Builder, value : Time, run : Run) : Nil
    json.string("time")
  end

  def self.canon(json : JSON::Builder, value, run : Run) : Nil
    pack(json, value)
  end

  # Defines the canonical form of an event: `__sweettalk_canon` writes *names*, its fields,
  # and `__sweettalk_canon_subject` names its *subject* aggregate, nil for a context's.
  macro __sweettalk_canonical_event(subject, names)
    def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
      json.object do
        {% for field in names %}
          json.field({{ field }}) { ::SweetTalk.canon(json, @{{ field.id }}, run) }
        {% end %}
      end
    end

    def __sweettalk_canon_subject(run : ::SweetTalk::Run) : String?
      {% if subject %}
        __sweettalk_subject_id.try { |raw| run.subject({{ subject.stringify }}.lchop("::"), raw) }
      {% else %}
        nil
      {% end %}
    end
  end

  abstract class Event
    abstract def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
    abstract def __sweettalk_canon_subject(run : ::SweetTalk::Run) : String?
  end

  abstract class Aggregate < Model
    # Defines `__sweettalk_canon`, this aggregate as a preview shows it: its state when it
    # has moves, whether it is removed, and every attribute; and `__sweettalk_ended?`, true
    # in a state no move leaves.
    macro __sweettalk_canonical
      {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      {% moves = @type.has_constant?("SWEETTALK_MOVES") %}
      def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
        json.object do
          {% if moves %}
            json.field("state", __sweettalk_state)
          {% end %}
          json.field("removed", !@__sweettalk_removed_at.nil?)
          {% for attribute in attributes %}
            json.field({{ attribute[0] }}) do
              ::SweetTalk.canon(json, self.{{ attribute[0].id }}, run)
            end
          {% end %}
        end
      end

      def __sweettalk_ended? : Bool
        {% if moves %}
          ({{ @type.constant("SWEETTALK_FINAL") }}).includes?(__sweettalk_state)
        {% else %}
          false
        {% end %}
      end
    end

    def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
      raise NotImplementedError.new("#{self.class.name}#__sweettalk_canon")
    end

    def __sweettalk_ended? : Bool
      raise NotImplementedError.new("#{self.class.name}#__sweettalk_ended?")
    end
  end

  abstract class Entity < Model
    # Defines `__sweettalk_canon`, this entity as a preview shows it: its id, as the
    # placeholder the run gave a new one, then every attribute.
    macro __sweettalk_canonical
      {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
        json.object do
          json.field("id") do
            if raw = @__sweettalk_id
              run.id(json, self.class.name, raw)
            else
              json.null
            end
          end
          {% for attribute in attributes %}
            json.field({{ attribute[0] }}) do
              ::SweetTalk.canon(json, self.{{ attribute[0].id }}, run)
            end
          {% end %}
        end
      end
    end

    def __sweettalk_canon(json : ::JSON::Builder, run : ::SweetTalk::Run) : Nil
      raise NotImplementedError.new("#{self.class.name}#__sweettalk_canon")
    end
  end
end

class Fiber
  # The `SweetTalk.preview` or `SweetTalk.commit` running on this fiber.
  property __sweettalk_run : ::SweetTalk::Run? = nil
end
