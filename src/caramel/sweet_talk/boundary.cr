# One aggregate per transaction, the actor, and units of work, kept on the fiber.
module SweetTalk
  # What a service, a compensation or a deadline should do instead of changing a second
  # aggregate.
  INSTEAD = "emit an event and react to it in a whenever"

  # Checks that changing *aggregate* (nil for a new one) keeps to one aggregate per
  # transaction. True when this fiber already runs a command on that aggregate.
  def self.__sweettalk_enter(aggregate : Aggregate?) : Bool
    fiber = ::Fiber.current
    if running = fiber.__sweettalk_command
      return true if aggregate && running.__sweettalk_same?(aggregate)
      changed = aggregate ? __sweettalk_named(aggregate) : "a new aggregate"
      raise Boundary.new("#{changed} changed inside #{__sweettalk_named(running)}'s " \
                         "command: a command changes one aggregate; react to its event " \
                         "in a whenever instead")
    end
    if changes = fiber.__sweettalk_changes
      if changes >= 1
        handled = fiber.__sweettalk_handled
        what, remedy = handled || {"a whenever handler", "use each: or a second whenever"}
        raise Boundary.new("#{what} changes one aggregate, and this one already changed " \
                           "one: #{remedy}")
      end
      fiber.__sweettalk_changes = changes + 1
    end
    false
  end

  # An aggregate's class and id, as a refusal names it.
  private def self.__sweettalk_named(aggregate : Aggregate) : String
    "#{aggregate.class.name} #{aggregate.@__sweettalk_id || "(unsaved)"}"
  end

  # Runs a handler, a service or a deadline, counting the aggregates it changes; *what*
  # and *remedy* name it in the refusal of a second change. A nested handling shares the
  # open one's count and description. Returns the block's value.
  def self.__sweettalk_handling(what : String, remedy : String, &)
    fiber = ::Fiber.current
    return yield if fiber.__sweettalk_handled
    fiber.__sweettalk_changes = 0
    fiber.__sweettalk_handled = {what, remedy}
    begin
      yield
    ensure
      fiber.__sweettalk_changes = nil
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
  # The aggregate whose command this fiber runs; how many aggregates the open handling
  # has changed, and what it is and how to fix a second change; the open unit of work;
  # and who acts. SweetTalk sets and restores each.
  property __sweettalk_command : ::SweetTalk::Aggregate? = nil
  property __sweettalk_changes : Int32? = nil
  property __sweettalk_handled : {String, String}? = nil
  property __sweettalk_unit : ::SweetTalk::Unit? = nil
  property __sweettalk_actor : String? = nil
end
