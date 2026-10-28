# One aggregate per transaction, units, ordered row locks, the actor, cause and flow,
# and a handler's unit of work, kept on the fiber.
module SweetTalk
  # What a service, a compensation or a deadline should do instead of changing a second
  # aggregate: a service may emit its context's own event.
  INSTEAD = "emit an event and react to it in a whenever"

  # A running `unit` (ADR 0046): the aggregate types its commands may change, the rows it
  # locked or created as {table, id}, and the aggregate instances its commands touched,
  # which reload what is stored when it fails. Closed once it returns.
  class Unit
    getter name : String
    getter allowed : Array(Aggregate.class)
    getter locked = Set({String, Int64}).new
    getter touched = [] of Aggregate
    property? open = true

    def initialize(@name : String, @allowed : Array(Aggregate.class))
    end

    # Admits a command on *aggregate*, or a `create` of *type* when *aggregate* is nil:
    # the type is named in `changes:`, and an existing row was locked.
    def admit(aggregate : Aggregate?, type : Aggregate.class) : Nil
      unless @allowed.includes?(type)
        changed = aggregate ? SweetTalk.__sweettalk_named(aggregate) : "a new #{short(type)}"
        raise Boundary.new("#{changed} changed inside #{@name}, which changes #{listed}: " \
                           "add #{short(type)} to its changes:")
      end
      return unless aggregate
      unless @locked.includes?({type.__sweettalk_table, aggregate.__sweettalk_raw_id})
        raise Boundary.new("#{SweetTalk.__sweettalk_named(aggregate)} changed inside #{@name} " \
                           "without its lock: lock it in locks:")
      end
      touch(aggregate)
    end

    # Counts *aggregate*, just created inside this unit, as locked and touched.
    def made(aggregate : Aggregate) : Nil
      @locked << {aggregate.class.__sweettalk_table, aggregate.__sweettalk_raw_id}
      touch(aggregate)
    end

    private def touch(aggregate : Aggregate) : Nil
      @touched << aggregate unless @touched.any?(&.same?(aggregate))
    end

    private def short(type : Aggregate.class) : String
      type.name.split("::").last
    end

    # The allowed types as the refusal lists them: "Journal, Position and Segment".
    private def listed : String
      names = @allowed.map { |type| short(type) }
      return names[0] if names.size == 1
      "#{names[0..-2].join(", ")} and #{names[-1]}"
    end
  end

  # What one handling (a `whenever` handler, a service, a compensation, a deadline or a
  # unit called outside them) may change: one aggregate, by any number of commands, or
  # one unit. *what* and *remedy* name it in the refusal of a second.
  class Handling
    getter what : String
    getter remedy : String
    property changed : (Aggregate | Unit)? = nil

    def initialize(@what : String, @remedy : String)
    end
  end

  # Checks that changing *changing*, an aggregate or, for `create` and a factory, the class
  # of a new one, keeps to one aggregate per transaction. True when this fiber already runs
  # a command on that aggregate. In a handling, the first aggregate changed is remembered,
  # and a command on it again passes; a second aggregate, or a new one once any is
  # changed, is refused. Inside a unit the type must be in its `changes:` and an existing
  # row must have been locked.
  def self.__sweettalk_enter(changing : Aggregate | Aggregate.class) : Bool
    fiber = ::Fiber.current
    aggregate = changing.is_a?(Aggregate) ? changing : nil
    type = changing.is_a?(Aggregate) ? changing.class : changing
    if running = fiber.__sweettalk_command
      return true if aggregate && running.__sweettalk_same?(aggregate)
      changed = aggregate ? __sweettalk_named(aggregate) : "a new aggregate"
      raise Boundary.new("#{changed} changed inside #{__sweettalk_named(running)}'s " \
                         "command: a command changes one aggregate; react to its event " \
                         "in a whenever instead")
    end
    if handling = fiber.__sweettalk_handling
      case changed = handling.changed
      in Unit
        raise Boundary.new(__sweettalk_second(handling)) unless changed.open?
        changed.admit(aggregate, type)
      in Aggregate
        return false if aggregate && changed.__sweettalk_same?(aggregate)
        raise Boundary.new(__sweettalk_second(handling))
      in Nil
        handling.changed = aggregate
      end
    end
    false
  end

  # Remembers *aggregate*, just created in the open handling, as the aggregate it changed,
  # so a command on it afterwards passes; inside a unit, as a row it may change unlocked.
  def self.__sweettalk_created(aggregate : Aggregate) : Nil
    return unless handling = ::Fiber.current.__sweettalk_handling
    case changed = handling.changed
    in Unit      then changed.made(aggregate)
    in Aggregate then nil
    in Nil       then handling.changed = aggregate
    end
  end

  # An aggregate's class and id, as a refusal names it.
  def self.__sweettalk_named(aggregate : Aggregate) : String
    "#{aggregate.class.name} #{aggregate.@__sweettalk_id || "(unsaved)"}"
  end

  private def self.__sweettalk_second(handling : Handling) : String
    "#{handling.what} changes one aggregate, and this one already changed one: " \
    "#{handling.remedy}"
  end

  # Runs a handler, a service or a deadline, remembering the aggregate it changes; *what*
  # and *remedy* name it in the refusal of a second one. A nested handling shares the
  # open one's aggregate and description. Returns the block's value.
  def self.__sweettalk_handling(what : String, remedy : String, &)
    fiber = ::Fiber.current
    return yield if fiber.__sweettalk_handling
    fiber.__sweettalk_handling = Handling.new(what, remedy)
    begin
      yield
    ensure
      fiber.__sweettalk_handling = nil
    end
  end

  # Runs a unit named *name* whose commands may change the *allowed* types: locks, body
  # and checks in the block, in one transaction with one flow. Inside a command, a factory
  # or another unit it is refused; inside a handling that has changed nothing yet it
  # becomes that handling's one change, and a second change there is refused. On any
  # failure every aggregate instance its commands touched reloads what is stored, and the
  # error goes on. Returns the block's value.
  def self.__sweettalk_unit(name : String, allowed : Array(Aggregate.class), &)
    fiber = ::Fiber.current
    if running = fiber.__sweettalk_command
      raise Boundary.new("#{name} called inside #{__sweettalk_named(running)}'s command: a " \
                         "command changes one aggregate; call the unit from an action, a " \
                         "service or a whenever instead")
    end
    unit = Unit.new(name, allowed)
    own = fiber.__sweettalk_handling.nil?
    if handling = fiber.__sweettalk_handling
      case changed = handling.changed
      in Unit
        if changed.open?
          raise Boundary.new("#{name} called inside #{changed.name}: a unit runs its " \
                             "commands itself; name every aggregate it changes in changes:")
        end
        raise Boundary.new(__sweettalk_second(handling))
      in Aggregate
        raise Boundary.new(__sweettalk_second(handling))
      in Nil
        handling.changed = unit
      end
    else
      handling = fiber.__sweettalk_handling = Handling.new(name, INSTEAD)
      handling.changed = unit
    end
    begin
      __sweettalk_flowing do
        ::SugarORM::Repo.transaction { yield }
      end
    rescue error
      unit.touched.each(&.__sweettalk_reload)
      raise error
    ensure
      unit.open = false
      fiber.__sweettalk_handling = nil if own
    end
  end

  # Locks the rows of *ids*, aggregates' ids, aggregates, and arrays of either, `FOR
  # UPDATE`: one statement per table, the tables in name order and the ids in order
  # within each, so two transactions that lock the same rows wait on each other instead
  # of deadlocking. A missing or removed id raises `Missing`. It runs inside a
  # transaction, or raises `ArgumentError`; a row locked twice in one transaction is
  # simply held. Inside a unit the rows count as locked for its commands; a call after the
  # first is ordered within its own batch only.
  def self.lock(*ids) : Nil
    unless ::SugarORM::Repo.in_transaction?
      raise ArgumentError.new("SweetTalk.lock runs inside a transaction: open " \
                              "SugarORM::Repo.transaction around it, or name the ids in a " \
                              "unit's locks:")
    end
    wanted = [] of Identity
    ids.each { |id| __sweettalk_wanted(wanted, id) }
    unit = __sweettalk_open_unit
    wanted.group_by(&.__sweettalk_table).to_a.sort_by!(&.[0]).each do |table, batch|
      raws = batch.map(&.raw).uniq!.sort!
      batch[0].__sweettalk_lock(raws)
      raws.each { |raw| unit.locked << {table, raw} } if unit
    end
  end

  private def self.__sweettalk_wanted(wanted : Array(Identity), id : Identity) : Nil
    wanted << id
  end

  private def self.__sweettalk_wanted(wanted : Array(Identity), aggregate : Aggregate) : Nil
    wanted << aggregate.id
  end

  private def self.__sweettalk_wanted(wanted : Array(Identity), ids : Enumerable) : Nil
    ids.each { |id| __sweettalk_wanted(wanted, id) }
  end

  # The unit running on this fiber, if any.
  private def self.__sweettalk_open_unit : Unit?
    changed = ::Fiber.current.__sweettalk_handling.try(&.changed)
    changed if changed.is_a?(Unit) && changed.open?
  end

  # Runs the block as *by*: every event emitted inside it records *by* as its actor, and
  # every policy job that follows one of those events runs as the same actor. Returns the
  # block's value.
  def self.acting(by : String?, &)
    fiber = ::Fiber.current
    previous = fiber.__sweettalk_actor
    fiber.__sweettalk_actor = by
    begin
      yield
    ensure
      fiber.__sweettalk_actor = previous
    end
  end

  # Runs the block as a handler of the event *cause*, in its *flow*, as *by*: every event
  # emitted inside it names *cause* as its cause and keeps *flow*. Returns the block's value.
  def self.__sweettalk_following(by : String?, cause : String?, flow : String?, &)
    fiber = ::Fiber.current
    previous = {fiber.__sweettalk_cause, fiber.__sweettalk_flow}
    fiber.__sweettalk_cause, fiber.__sweettalk_flow = cause, flow
    begin
      acting(by) { yield }
    ensure
      fiber.__sweettalk_cause, fiber.__sweettalk_flow = previous
    end
  end

  # The flow a new event keeps: the handled event's or the running command's, else the
  # current trace's id, else a random 32-hex one.
  def self.__sweettalk_flow : String
    ::Fiber.current.__sweettalk_flow || ::Caramel::Crema.current?.try(&.trace_id) ||
      Random::Secure.hex(16)
  end

  # Pins the flow for a command, a factory or a unit that runs outside a handler, so every
  # event it emits shares one; a handler's flow is already pinned. Returns the block's value.
  def self.__sweettalk_flowing(&)
    fiber = ::Fiber.current
    return yield if fiber.__sweettalk_flow
    fiber.__sweettalk_flow = __sweettalk_flow
    begin
      yield
    ensure
      fiber.__sweettalk_flow = nil
    end
  end

  # A row of a projection or a process, saved when its handler's work ends.
  module Keyed
    abstract def __sweettalk_save : Nil
  end

  # The rows one handler has asked for, by "Type:key": its unit of work.
  class Work
    getter rows = {} of String => ::SweetTalk::Keyed
  end

  # Runs one handler in a transaction with its own unit of work, then saves every row it
  # touched; the work lives on the fiber, and the one before it comes back afterwards.
  def self.__sweettalk_work(&) : Nil
    fiber = ::Fiber.current
    previous = fiber.__sweettalk_work
    work = fiber.__sweettalk_work = Work.new
    begin
      ::SugarORM::Repo.transaction do
        yield
        work.rows.each_value(&.__sweettalk_save)
      end
    ensure
      fiber.__sweettalk_work = previous
    end
  end
end

class Fiber
  # The aggregate whose command this fiber runs; the open handling, with what it has
  # changed; the open unit of work; who acts; and the event being handled and its flow.
  # SweetTalk sets and restores each.
  property __sweettalk_command : ::SweetTalk::Aggregate? = nil
  property __sweettalk_handling : ::SweetTalk::Handling? = nil
  property __sweettalk_work : ::SweetTalk::Work? = nil
  property __sweettalk_actor : String? = nil
  property __sweettalk_cause : String? = nil
  property __sweettalk_flow : String? = nil
end
