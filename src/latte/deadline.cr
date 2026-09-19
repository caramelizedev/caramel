# A deadline belongs to the operation's fiber. Every managed external command
# uses the remaining budget, rather than renewing a timeout at each step.
class Fiber
  property caramel_operation_deadline : Time::Instant?
end

module Caramel::Latte
  class DeadlineExceeded < Exception
  end

  module OperationDeadline
    def self.run(duration : Time::Span, &)
      previous = Fiber.current.caramel_operation_deadline
      proposed = Time.instant + duration
      Fiber.current.caramel_operation_deadline = previous && previous < proposed ? previous : proposed
      yield
    ensure
      Fiber.current.caramel_operation_deadline = previous
    end

    def self.without(&)
      previous = Fiber.current.caramel_operation_deadline
      Fiber.current.caramel_operation_deadline = nil
      yield
    ensure
      Fiber.current.caramel_operation_deadline = previous
    end

    def self.limit(duration : Time::Span) : Time::Span
      if deadline = Fiber.current.caramel_operation_deadline
        remaining = deadline - Time.instant
        raise DeadlineExceeded.new("Managed service operation exceeded its deadline") if remaining <= Time::Span.zero
        return remaining < duration ? remaining : duration
      end
      duration
    end

    def self.check! : Nil
      limit(1.second)
    end
  end
end
