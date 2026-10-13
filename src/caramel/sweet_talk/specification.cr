# Specifications: one rule an aggregate satisfies or not, read by Crystal and by PostgreSQL.
module SweetTalk
  # `specification Dispatchable, on: Order, where: {state: :placed}, means: "…"` in a
  # context. Each one is a subclass: `SWEETTALK_ON` names its aggregate, `satisfied_by?`
  # asks an aggregate, and `__sweettalk_condition` is the same rule as a SugarORM
  # condition.
  abstract struct Specification
  end

  # Whether a stored attribute *have* holds what a specification's `where:` asks: a list
  # holds any member, a range its span, `nil` only nil, and anything else itself, as
  # SugarORM's keyword conditions read it.
  def self.__sweettalk_holds?(have, wanted : Array) : Bool
    wanted.includes?(have)
  end

  def self.__sweettalk_holds?(have, wanted : Range) : Bool
    return false if have.nil?
    wanted.includes?(have)
  end

  def self.__sweettalk_holds?(have, wanted : Nil) : Bool
    have.nil?
  end

  def self.__sweettalk_holds?(have, wanted) : Bool
    have == wanted
  end

  # Every condition holds: `(a) AND (b)`.
  def self.__sweettalk_all(conditions : Array(::SugarORM::Condition)) : ::SugarORM::Condition
    joined(conditions, " AND ")
  end

  # One of the conditions holds: `(a) OR (b)`.
  def self.__sweettalk_any(conditions : Array(::SugarORM::Condition)) : ::SugarORM::Condition
    joined(conditions, " OR ")
  end

  # The condition does not hold: `(a) IS NOT TRUE`, so a NULL column, which fails `a`
  # in PostgreSQL as `nil` fails it in Crystal, passes the negation in both.
  def self.__sweettalk_none(condition : ::SugarORM::Condition) : ::SugarORM::Condition
    ::SugarORM::Condition.new("(#{condition.sql}) IS NOT TRUE", condition.values)
  end

  private def self.joined(conditions : Array(::SugarORM::Condition),
                          operator : String) : ::SugarORM::Condition
    sql = conditions.map { |condition| "(#{condition.sql})" }.join(operator)
    ::SugarORM::Condition.new(sql, conditions.flat_map(&.values))
  end
end
