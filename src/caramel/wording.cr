module Caramel
  # The language Caramel's pages declare. `caramel/i18n` replaces it with
  # the request locale's code.
  def self.language : String
    "en"
  end

  # *path* as a link writes it. `caramel/i18n` adds the locale prefix.
  def self.localize_path(path : String) : String
    path
  end

  # The text of Caramel's own messages: contract errors and the pages it
  # answers. Each method returns English; `caramel/i18n` redefines those a
  # locale catalog translates, with the same signature.
  module Wording
    extend self

    def required : String
      "is required"
    end

    def must_be_file : String
      "must be a file"
    end

    def json_type(type) : String
      "must be a JSON #{type}"
    end

    def invalid_value(type) : String
      "must be a valid #{type}"
    end

    def at_least(min) : String
      "must be at least #{min}"
    end

    def at_least_characters(min) : String
      "must be at least #{min} characters"
    end

    def at_most(max) : String
      "must be at most #{max}"
    end

    def at_most_characters(max) : String
      "must be at most #{max} characters"
    end

    def duplicate_field(name) : String
      "Duplicate field: #{name}"
    end

    def unknown_field(name) : String
      "Unknown field: #{name}"
    end

    def expected_json_object : String
      "Expected a JSON object"
    end

    def url : String
      "must be an absolute http or https URL"
    end

    def check_request : String
      "Check your request"
    end

    def not_found : String
      "Not found"
    end

    def expired_form : String
      "This form has expired or came from another site. Reload the page and try again."
    end
  end
end
