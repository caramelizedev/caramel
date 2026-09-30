require "http"
require "http/formdata"
require "json"
require "uri/params"
require "set"
require "./ingress"

module Caramel
  # A multipart file part streamed to a private tempfile. The file is deleted
  # when the request finishes; copy it elsewhere to keep it.
  record UploadedFile, filename : String?, content_type : String?, path : String, size : Int64

  # Every request source a contract may bind: route parameters, the URL query
  # and a bounded body: a URL-encoded or multipart form or a JSON object, or,
  # for a route whose ingress is raw, the bytes as sent. Duplicate keys are
  # errors instead of silently selecting a value based on parser order.
  class RequestInput
    class TooLarge < Exception; end

    class UnsupportedMediaType < Exception; end

    class InvalidEncoding < Exception; end

    # The JSON type each member of a JSON body arrived as; a contract field
    # accepts only its own.
    enum JsonKind
      String
      Number
      Bool
      Null
      Nested
    end

    MAX_FORM_BYTES   =      2_097_152
    MAX_UPLOAD_BYTES = 67_108_864_i64
    OVERRIDES        = {"PATCH", "PUT", "DELETE"}
    BODY_METHODS     = {"POST", "PUT", "PATCH", "DELETE"}
    UNSUPPORTED      = "Expected a URL-encoded form, multipart form or JSON object"

    getter query = {} of String => String
    getter body = {} of String => String
    getter files = {} of String => UploadedFile
    getter errors = {} of String => Array(String)
    getter csrf_token : String? = nil
    getter method_override : String? = nil
    # The body exactly as sent, read only for a raw ingress.
    getter raw_body : Bytes = Bytes.empty
    property route_params = {} of String => String
    getter? lenient_query : Bool
    @submitted_override : String? = nil
    @json_kinds = {} of String => JsonKind

    # Reads *request* as its route's *ingress* allows: its limit bounds the
    # body text, and uploads share *max_upload_bytes*.
    def self.read(request : HTTP::Request,
                  ingress : Ingress = Ingress::DEFAULT,
                  max_upload_bytes : Int64 = MAX_UPLOAD_BYTES) : self
      input = new({"GET", "HEAD"}.includes?(request.method))
      begin
        input.parse(request, ingress, max_upload_bytes)
      rescue error
        input.cleanup
        raise error
      end
      input
    end

    @[Deprecated("Use `RequestInput.read(request, Caramel::Ingress.new(limit: bytes))`")]
    def self.read(request : HTTP::Request,
                  max_form_bytes : Int32,
                  max_upload_bytes : Int64 = MAX_UPLOAD_BYTES) : self
      read(request, Ingress.new(limit: max_form_bytes.to_i64), max_upload_bytes)
    end

    protected def initialize(@lenient_query : Bool)
    end

    protected def parse(request : HTTP::Request,
                        ingress : Ingress,
                        max_upload_bytes : Int64) : Nil
      request.query.try { |text| parse_pairs(text, @query, controls: false) }
      return unless BODY_METHODS.includes?(request.method)

      if ingress.body.raw?
        @raw_body = read_body(request, ingress.limit)
      else
        parse_body(request, ingress.limit, max_upload_bytes)
        apply_override(request)
      end
    end

    def value?(name : String) : String?
      @route_params[name]? || @body[name]? || @query[name]?
    end

    def file?(name : String) : UploadedFile?
      @files[name]?
    end

    # True when a JSON body sent *name* as a type other than *expected*;
    # null counts as absent.
    def json_mismatch?(name : String, expected : JsonKind) : Bool
      kind = @json_kinds[name]?
      !kind.nil? && !kind.null? && kind != expected
    end

    def source_count(name : String) : Int32
      count = 0
      count += 1 if @route_params.has_key?(name)
      count += 1 if @body.has_key?(name) || @json_kinds.has_key?(name)
      count += 1 if @query.has_key?(name)
      count += 1 if @files.has_key?(name)
      count
    end

    # Keys that must be declared by the contract, including JSON members that
    # were null or nested. GET and HEAD queries may carry unrelated
    # parameters such as analytics or cache busters.
    def strict_keys : Array(String)
      keys = (@json_kinds.empty? ? @body.keys : @json_kinds.keys) + @files.keys
      keys.concat(@query.keys) unless @lenient_query
      keys
    end

    def cleanup : Nil
      @files.each_value { |file| File.delete?(file.path) }
    end

    private def add_error(field : String, message : String) : Nil
      (@errors[field] ||= [] of String) << message
    end

    private def empty_body?(request : HTTP::Request) : Bool
      request.body.try(&.read_byte).nil?
    end

    private def parse_body(request : HTTP::Request,
                           limit : Int64,
                           max_upload_bytes : Int64) : Nil
      case media_type(request)
      when "application/x-www-form-urlencoded"
        parse_pairs(read_text(request, limit), @body, controls: true)
      when "multipart/form-data"
        parse_multipart(request, limit, max_upload_bytes)
      when "application/json"
        parse_json(read_text(request, limit))
      when nil
        raise UnsupportedMediaType.new(UNSUPPORTED) unless empty_body?(request)
      else
        raise UnsupportedMediaType.new(UNSUPPORTED)
      end
    end

    private def media_type(request : HTTP::Request) : String?
      request.headers["Content-Type"]?.try(&.split(';', 2).first.strip.downcase)
    end

    # A POST form may ask for PATCH, PUT or DELETE in its `_method` field.
    private def apply_override(request : HTTP::Request) : Nil
      return unless request.method == "POST" && (override = @submitted_override)

      override = override.upcase
      unless OVERRIDES.includes?(override)
        raise InvalidEncoding.new("Unsupported method override")
      end
      @method_override = override
    end

    private def read_text(request : HTTP::Request, limit : Int64) : String
      String.new(read_body(request, limit))
    end

    # At most *limit* bytes of the body; a declared or actual excess raises.
    private def read_body(request : HTTP::Request, limit : Int64) : Bytes
      declared = request.headers["Content-Length"]?.try(&.to_i64?)
      raise TooLarge.new("Body exceeds #{limit} bytes") if declared && declared > limit

      source = request.body || return Bytes.empty
      buffer = IO::Memory.new
      copied = IO.copy(source, buffer, limit + 1)
      raise TooLarge.new("Body exceeds #{limit} bytes") if copied > limit
      buffer.to_slice
    end

    # A JSON object's scalar members become body fields, with numbers as
    # their source text so contracts convert them like form text. `_csrf`
    # and `_method` are ordinary members: JSON clients send headers instead.
    private def parse_json(text : String) : Nil
      return if text.empty?
      raise InvalidEncoding.new("Malformed JSON") unless text.valid_encoding?

      parser = JSON::PullParser.new(text)
      if parser.kind.begin_object?
        parser.read_object { |key| read_json_member(parser, key) }
      else
        parser.skip
        add_error("_base", "Expected a JSON object")
      end
      raise InvalidEncoding.new("Malformed JSON") unless parser.kind.eof?
    rescue JSON::ParseException
      raise InvalidEncoding.new("Malformed JSON")
    end

    # Records one member, and the JSON type it arrived as. The first of two
    # members with one name wins; the second is an error.
    private def read_json_member(parser : JSON::PullParser, key : String) : Nil
      check_text(key)
      if @json_kinds.has_key?(key)
        add_error("_base", "Duplicate field: #{key}")
        parser.skip
      else
        @json_kinds[key] = read_json_value(parser, key)
      end
    end

    private def read_json_value(parser : JSON::PullParser, key : String) : JsonKind
      case parser.kind
      when .string?
        value = parser.read_string
        check_text(value)
        @body[key] = value
        JsonKind::String
      when .int?, .float?
        @body[key] = parser.raw_value
        parser.read_next
        JsonKind::Number
      when .bool?
        @body[key] = parser.read_bool.to_s
        JsonKind::Bool
      when .null?
        parser.read_null
        JsonKind::Null
      else
        parser.skip
        JsonKind::Nested
      end
    end

    private def parse_pairs(text : String, target : Hash(String, String), controls : Bool) : Nil
      malformed = !text.valid_encoding? || text.matches?(/%(?![0-9a-fA-F]{2})/)
      raise InvalidEncoding.new("Malformed form encoding") if malformed
      seen = Set(String).new
      URI::Params.parse(text).each do |key, value|
        check_text(key)
        check_text(value)
        unless seen.add?(key)
          add_error("_base", "Duplicate field: #{key}")
          next
        end
        next if control?(key, value, controls)
        target[key] = value
      end
    end

    private def parse_multipart(request : HTTP::Request,
                                max_form_bytes : Int64,
                                max_upload_bytes : Int64) : Nil
      text_budget = max_form_bytes
      upload_budget = max_upload_bytes
      seen = Set(String).new
      HTTP::FormData.parse(request) do |part|
        name = part.name
        check_text(name)
        unless seen.add?(name)
          add_error("_base", "Duplicate field: #{name}")
          next
        end
        if part.filename
          file = File.tempfile("caramel-upload-")
          begin
            copied = IO.copy(part.body, file, upload_budget + 1)
            if copied > upload_budget
              raise TooLarge.new("Uploads exceed #{max_upload_bytes} bytes")
            end
          rescue error
            file.close
            file.delete
            raise error
          end
          file.close
          upload_budget -= copied
          @files[name] = UploadedFile.new(
            filename: part.filename,
            content_type: part.headers["Content-Type"]?,
            path: file.path,
            size: copied)
        else
          copied = 0_i64
          value = String.build do |io|
            copied = IO.copy(part.body, io, text_budget + 1)
          end
          raise TooLarge.new("Form exceeds #{max_form_bytes} bytes") if copied > text_budget
          text_budget -= copied
          check_text(value)
          @body[name] = value unless control?(name, value, true)
        end
      end
    rescue HTTP::FormData::Error | MIME::Multipart::Error
      raise InvalidEncoding.new("Malformed multipart form")
    end

    private def check_text(text : String) : Nil
      malformed = !text.valid_encoding? || text.includes?('\0')
      raise InvalidEncoding.new("Malformed form encoding") if malformed
    end

    # `_csrf` and `_method` are transport controls, never contract fields.
    private def control?(key : String, value : String, capture : Bool) : Bool
      case key
      when "_csrf"
        @csrf_token = value if capture
        true
      when "_method"
        @submitted_override = value if capture
        true
      else
        false
      end
    end
  end
end
