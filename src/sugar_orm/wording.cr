module SugarORM
  # The text of changeset errors. Each method returns English; an
  # application's translations may redefine any of them, with the same
  # signature.
  module Wording
    extend self

    def required : String
      "is required"
    end

    def blank : String
      "can't be blank"
    end

    def greater_than(than) : String
      "must be greater than #{than}"
    end

    def less_than(than) : String
      "must be less than #{than}"
    end

    def too_short(min) : String
      "should be at least #{min} character(s)"
    end

    def too_long(max) : String
      "should be at most #{max} character(s)"
    end

    def invalid_format : String
      "has invalid format"
    end

    def invalid : String
      "is invalid"
    end

    def taken : String
      "has already been taken"
    end

    def record_gone : String
      "Record no longer exists"
    end
  end
end
