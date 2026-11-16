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

  # `not(…)` holds when the wanted value does not; with no value it holds unless the word
  # says `unknown: :drop`, as IS DISTINCT FROM and IS NOT TRUE read it in PostgreSQL.
  # `not(nil)` holds when there is a value. A macro tells the two apart: when two overloads
  # restrict `Not` alike, Crystal does not rank `Not(Nil)` above `Not(V)`.
  def self.__sweettalk_holds?(have, wanted : ::SugarORM::Not(V)) : Bool forall V
    {% if V == Nil %}
      !have.nil?
    {% else %}
      return wanted.unknown.keep? if have.nil?
      !__sweettalk_holds?(have, wanted.value)
    {% end %}
  end

  def self.__sweettalk_holds?(have, wanted : ::SugarORM::Over(V)) : Bool forall V
    return false if have.nil?
    have > wanted.value
  end

  def self.__sweettalk_holds?(have, wanted : ::SugarORM::Under(V)) : Bool forall V
    return false if have.nil?
    have < wanted.value
  end

  # A text word matches the text literally; LIKE's escaping applies only in SQL.
  def self.__sweettalk_holds?(have, wanted : ::SugarORM::Text) : Bool
    return false if have.nil?
    text = wanted.any_case ? wanted.text.downcase : wanted.text
    value = wanted.any_case ? have.downcase : have
    case wanted.at
    when :start then value.starts_with?(text)
    when :end   then value.ends_with?(text)
    else             value.includes?(text)
    end
  end

  def self.__sweettalk_holds?(have, wanted) : Bool
    have == wanted
  end

  # The condition on a codec column, from *encoded*: what the row's encoder made of the
  # value, a text, a range of texts or nil. SugarORM's typed `where` encodes for itself; a
  # specification builds the condition directly, so it binds the encoded text.
  def self.__sweettalk_coded(column : String, encoded) : ::SugarORM::Condition
    ::SugarORM::Condition.column(column, encoded)
  end

  def self.__sweettalk_coded(column : String, encoded : String?) : ::SugarORM::Condition
    return ::SugarORM::Condition.column(column, nil) unless encoded
    ::SugarORM::Condition.column(column, encoded)
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
