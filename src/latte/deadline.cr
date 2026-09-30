# A deadline belongs to the operation's fiber. Every managed external command
# uses the remaining budget, rather than renewing a timeout at each step.
class Fiber
  property caramel_operation_deadline : Time::Instant?
end

module Caramel::Latte
  class DeadlineExceeded < Exception
  end

  module OperationDeadline
    EXCEEDED = "Managed service operation exceeded its deadline"

    def self.run(duration : Time::Span, &)
      previous = Fiber.current.caramel_operation_deadline
      proposed = Time.instant + duration
      earlier = previous && previous < proposed ? previous : proposed
      Fiber.current.caramel_operation_deadline = earlier
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
      deadline = Fiber.current.caramel_operation_deadline || return duration
      remaining = deadline - Time.instant
      raise DeadlineExceeded.new(EXCEEDED) if remaining <= Time::Span.zero
      remaining < duration ? remaining : duration
    end

    def self.check! : Nil
      limit(1.second)
    end
  end
end
