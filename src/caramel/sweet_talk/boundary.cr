# One aggregate per transaction, the actor, cause and flow, and units of work, kept on the
# fiber.
module SweetTalk
  # What a service, a compensation or a deadline should do instead of changing a second
  # aggregate: a service may emit its context's own event.
  INSTEAD = "emit an event and react to it in a whenever"

  # Checks that changing *aggregate* (nil for a new one) keeps to one aggregate per
  # transaction. True when this fiber already runs a command on that aggregate. In a
  # handling, the first aggregate changed is remembered, and a command on it again passes;
  # a second aggregate, or a new one once any is changed, is refused.
  def self.__sweettalk_enter(aggregate : Aggregate?) : Bool
    fiber = ::Fiber.current
    if running = fiber.__sweettalk_command
      return true if aggregate && running.__sweettalk_same?(aggregate)
      changed = aggregate ? __sweettalk_named(aggregate) : "a new aggregate"
      raise Boundary.new("#{changed} changed inside #{__sweettalk_named(running)}'s " \
                         "command: a command changes one aggregate; react to its event " \
                         "in a whenever instead")
    end
    if handled = fiber.__sweettalk_handled
      changed = fiber.__sweettalk_changed
      return false if aggregate && changed && changed.__sweettalk_same?(aggregate)
      if changed
        what, remedy = handled
        raise Boundary.new("#{what} changes one aggregate, and this one already changed " \
                           "one: #{remedy}")
      end
      fiber.__sweettalk_changed = aggregate
    end
    false
  end

  # Remembers *aggregate*, just created in the open handling, as the aggregate it changed,
  # so a command on it afterwards passes.
  def self.__sweettalk_created(aggregate : Aggregate) : Nil
    fiber = ::Fiber.current
    fiber.__sweettalk_changed = aggregate if fiber.__sweettalk_handled
  end

  # An aggregate's class and id, as a refusal names it.
  private def self.__sweettalk_named(aggregate : Aggregate) : String
    "#{aggregate.class.name} #{aggregate.@__sweettalk_id || "(unsaved)"}"
  end

  # Runs a handler, a service or a deadline, remembering the aggregate it changes; *what*
  # and *remedy* name it in the refusal of a second one. A nested handling shares the
  # open one's aggregate and description. Returns the block's value.
  def self.__sweettalk_handling(what : String, remedy : String, &)
    fiber = ::Fiber.current
    return yield if fiber.__sweettalk_handled
    fiber.__sweettalk_changed = nil
    fiber.__sweettalk_handled = {what, remedy}
    begin
      yield
    ensure
      fiber.__sweettalk_changed = nil
      fiber.__sweettalk_handled = nil
    end
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

  # Pins the flow for a command or a factory that runs outside a handler, so every event
  # it emits shares one; a handler's flow is already pinned. Returns the block's value.
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

  # A row of a projection or a process, saved when its unit of work ends.
  module Keyed
    abstract def __sweettalk_save : Nil
  end

  # The rows one handler has asked for, by "Type:key".
  class Unit
    getter rows = {} of String => ::SweetTalk::Keyed
  end

  # Runs one handler in a transaction with its own unit of work, then saves every row it
  # touched; the unit lives on the fiber, and the one before it comes back afterwards.
  def self.__sweettalk_unit(&) : Nil
    fiber = ::Fiber.current
    previous = fiber.__sweettalk_unit
    unit = fiber.__sweettalk_unit = Unit.new
    begin
      ::SugarORM::Repo.transaction do
        yield
        unit.rows.each_value(&.__sweettalk_save)
      end
    ensure
      fiber.__sweettalk_unit = previous
    end
  end
end

class Fiber
  # The aggregate whose command this fiber runs; the aggregate the open handling has
  # changed, and what it is and how to fix a second one; the open unit of work; who acts;
  # and the event being handled and its flow. SweetTalk sets and restores each.
  property __sweettalk_command : ::SweetTalk::Aggregate? = nil
  property __sweettalk_changed : ::SweetTalk::Aggregate? = nil
  property __sweettalk_handled : {String, String}? = nil
  property __sweettalk_unit : ::SweetTalk::Unit? = nil
  property __sweettalk_actor : String? = nil
  property __sweettalk_cause : String? = nil
  property __sweettalk_flow : String? = nil
end
