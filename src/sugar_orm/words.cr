module SugarORM
  # What `not(…)` does with the rows that hold no value in a nullable column.
  enum Unknown
    Keep
    Drop
  end

  # A value the rows must not hold: `where(status: not("withdrawn"))`.
  record Not(V), value : V, unknown : Unknown = Unknown::Keep

  # A value the rows must exceed / fall short of: `where(copies: over(3))`.
  record Over(V), value : V
  record Under(V), value : V

  # A LIKE pattern over a String column, built by `starting_with`, `ending_with` and `containing`.
  record Text, text : String, at : Symbol, any_case : Bool

  # The condition a keyword `where` builds for one column's argument, whichever word it was
  # written with.
  module WhereWords
    def self.column(column : String, value, nullable : Bool) : ::SugarORM::Condition
      ::SugarORM::Condition.column(column, value)
    end

    def self.column(column : String, value : ::SugarORM::Not(V),
                    nullable : Bool) : ::SugarORM::Condition forall V
      ::SugarORM::Condition.column_not(column, value.value, nullable && value.unknown.keep?)
    end

    def self.column(column : String, value : ::SugarORM::Not(::SugarORM::Text),
                    nullable : Bool) : ::SugarORM::Condition
      text = column(column, value.value, nullable)
      text.copy_with(nullable: nullable && value.unknown.keep?).negate
    end

    def self.column(column : String, value : ::SugarORM::Over(V),
                    nullable : Bool) : ::SugarORM::Condition forall V
      ::SugarORM::Condition.compare(column, ">", value.value)
    end

    def self.column(column : String, value : ::SugarORM::Under(V),
                    nullable : Bool) : ::SugarORM::Condition forall V
      ::SugarORM::Condition.compare(column, "<", value.value)
    end

    def self.column(column : String, value : ::SugarORM::Text,
                    nullable : Bool) : ::SugarORM::Condition
      ::SugarORM::Condition.text(column, value.text, value.at, value.any_case, nullable)
    end

    # The condition for a belongs_to association's keyword: its parent query, or the parents
    # to leave out. *key* is the foreign key; *nullable* says it may hold NULL.
    def self.parent(key : String, parent : ::SugarORM::Subquery(U),
                    nullable : Bool) : ::SugarORM::Condition forall U
      parent.__sugar_in_condition(key)
    end

    def self.parent(key : String, parent : ::SugarORM::Not(::SugarORM::Subquery(U)),
                    nullable : Bool) : ::SugarORM::Condition forall U
      condition = parent.value.__sugar_in_condition(key)
      condition.copy_with(nullable: nullable && parent.unknown.keep?).negate
    end

    # An Int32 literal inside a word is an Int32, which no Int64 or Float64 column accepts:
    # widen it to the column's type.
    def self.widen(value : ::SugarORM::Not(Int32), to : Int64.class) : ::SugarORM::Not(Int64)
      ::SugarORM::Not(Int64).new(value.value.to_i64, value.unknown)
    end

    def self.widen(value : ::SugarORM::Over(Int32), to : Int64.class) : ::SugarORM::Over(Int64)
      ::SugarORM::Over(Int64).new(value.value.to_i64)
    end

    def self.widen(value : ::SugarORM::Under(Int32), to : Int64.class) : ::SugarORM::Under(Int64)
      ::SugarORM::Under(Int64).new(value.value.to_i64)
    end

    def self.widen(value : ::SugarORM::Not(Int32), to : Float64.class) : ::SugarORM::Not(Float64)
      ::SugarORM::Not(Float64).new(value.value.to_f64, value.unknown)
    end

    def self.widen(value : ::SugarORM::Over(Int32), to : Float64.class) : ::SugarORM::Over(Float64)
      ::SugarORM::Over(Float64).new(value.value.to_f64)
    end

    def self.widen(value : ::SugarORM::Under(Int32),
                   to : Float64.class) : ::SugarORM::Under(Float64)
      ::SugarORM::Under(Float64).new(value.value.to_f64)
    end

    def self.widen(value, to)
      value
    end
  end
end

# The words a keyword `where` reads. Like `puts`, they are visible in every class; a class's own
# method of the same name wins inside that class.

# The rows that do not hold *value*: `where(status: not("withdrawn"))`. Rows with no value in a
# nullable column stay in, unless `unknown: :drop`. A class's own `not` wins inside that class.
def not(value : V, *,
        unknown : ::SugarORM::Unknown = ::SugarORM::Unknown::Keep) : ::SugarORM::Not(V) forall V
  ::SugarORM::Not(V).new(value, unknown)
end

# The rows a parent query does not match: `where(team: not(Team.query.archived))`. A parent query
# is typed by the schema it yields, so `Not` must hold it as that.
def not(parent : ::SugarORM::Subquery(U), *,
        unknown : ::SugarORM::Unknown = ::SugarORM::Unknown::Keep) forall U
  ::SugarORM::Not(::SugarORM::Subquery(U)).new(parent, unknown)
end

# The rows whose column exceeds *value*: `where(copies: over(3))`. A class's own `over` wins
# inside that class.
def over(value : V) : ::SugarORM::Over(V) forall V
  ::SugarORM::Over(V).new(value)
end

# The rows whose column falls short of *value*: `where(copies: under(3))`. A class's own `under`
# wins inside that class.
def under(value : V) : ::SugarORM::Under(V) forall V
  ::SugarORM::Under(V).new(value)
end

# The rows whose text starts with *text*, which matches literally. A class's own
# `starting_with` wins inside that class.
def starting_with(text : String, *, any_case : Bool = false) : ::SugarORM::Text
  ::SugarORM::Text.new(text, :start, any_case)
end

# The rows whose text ends with *text*. A class's own `ending_with` wins inside that class.
def ending_with(text : String, *, any_case : Bool = false) : ::SugarORM::Text
  ::SugarORM::Text.new(text, :end, any_case)
end

# The rows whose text holds *text*. A class's own `containing` wins inside that class.
def containing(text : String, *, any_case : Bool = false) : ::SugarORM::Text
  ::SugarORM::Text.new(text, :within, any_case)
end
