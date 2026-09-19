require "uri/params"
require "set"
require "http"

module Caramel
  # URL-encoded forms have one explicitly named input envelope. Duplicate keys
  # are errors instead of silently selecting a value based on parser order.
  class Form
    class TooLarge < Exception; end

    class InvalidEncoding < Exception; end

    class UnsupportedMediaType < Exception; end

    MAX_BYTES = 65_536
    getter values = {} of String => String
    getter errors = [] of String
    getter field_errors = {} of String => Array(String)
    getter csrf_token : String? = nil
    @override : String? = nil

    def self.read(request : HTTP::Request, envelope : String, fields : Array(String), required_fields : Array(String) = fields) : self
      media_type = request.headers["Content-Type"]?.try(&.split(';', 2).first.strip.downcase)
      unless media_type == "application/x-www-form-urlencoded"
        raise UnsupportedMediaType.new("Expected a URL-encoded form")
      end
      body = request.body
      raise InvalidEncoding.new("Missing form body") unless body
      buffer = Bytes.new(MAX_BYTES + 1)
      size = body.read_greedy(buffer)
      raise TooLarge.new("Form exceeds 64 KiB") if size > MAX_BYTES
      new(String.new(buffer[0, size]), envelope, fields, required_fields)
    end

    def initialize(body : String, envelope : String, fields : Array(String), required_fields : Array(String) = fields)
      raise TooLarge.new("Form exceeds 64 KiB") if body.bytesize > MAX_BYTES
      raise InvalidEncoding.new("Malformed form encoding") if !body.valid_encoding? || body.matches?(/%(?![0-9a-fA-F]{2})/)
      seen = Set(String).new
      URI::Params.parse(body).each do |key, value|
        raise InvalidEncoding.new("Malformed form encoding") unless key.valid_encoding? && value.valid_encoding? && !key.includes?('\0') && !value.includes?('\0')
        if seen.includes?(key)
          field = fields.find { |name| key == "#{envelope}[#{name}]" }
          add_error(field || "_base", "Duplicate form field")
          next
        end
        seen << key
        case key
        when "_csrf"
          @csrf_token = value
        when "_method"
          @override = value.upcase
          add_error("_base", "Unsupported method override") unless {"PATCH", "PUT", "DELETE"}.includes?(@override)
        else
          if field = fields.find { |name| key == "#{envelope}[#{name}]" }
            @values[field] = value
          else
            add_error("_base", "Unknown form field")
          end
        end
      end
      required_fields.each { |field| add_error(field, "Missing #{field}") unless @values.has_key?(field) }
    end

    private def add_error(field : String, message : String) : Nil
      @errors << message
      (@field_errors[field] ||= [] of String) << message
    end

    def [](field : String) : String
      @values[field]? || ""
    end

    def valid? : Bool
      @errors.empty?
    end

    # The caller must validate CSRF before dispatching an overridden method.
    def method(original : String) : String
      original == "POST" && valid? ? (@override || original) : original
    end
  end
end
