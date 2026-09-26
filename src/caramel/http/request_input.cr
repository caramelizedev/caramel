require "http"
require "http/formdata"
require "uri/params"
require "set"

module Caramel
  # A multipart file part streamed to a private tempfile. The file is deleted
  # when the request finishes; copy it elsewhere to keep it.
  record UploadedFile, filename : String?, content_type : String?, path : String, size : Int64

  # Every request source a contract may bind: route parameters, the URL query
  # and a bounded URL-encoded or multipart body. Duplicate keys are errors
  # instead of silently selecting a value based on parser order.
  class RequestInput
    class TooLarge < Exception; end

    class UnsupportedMediaType < Exception; end

    class InvalidEncoding < Exception; end

    MAX_FORM_BYTES   =      2_097_152
    MAX_UPLOAD_BYTES = 67_108_864_i64
    OVERRIDES        = {"PATCH", "PUT", "DELETE"}
    BODY_METHODS     = {"POST", "PUT", "PATCH", "DELETE"}

    getter query = {} of String => String
    getter body = {} of String => String
    getter files = {} of String => UploadedFile
    getter errors = {} of String => Array(String)
    getter csrf_token : String? = nil
    getter method_override : String? = nil
    property route_params = {} of String => String
    getter lenient_query : Bool
    @submitted_override : String? = nil

    def self.read(request : HTTP::Request, max_form_bytes : Int32 = MAX_FORM_BYTES, max_upload_bytes : Int64 = MAX_UPLOAD_BYTES) : self
      input = new({"GET", "HEAD"}.includes?(request.method))
      begin
        input.parse(request, max_form_bytes, max_upload_bytes)
      rescue error
        input.cleanup
        raise error
      end
      input
    end

    protected def initialize(@lenient_query : Bool)
    end

    protected def parse(request : HTTP::Request, max_form_bytes : Int32, max_upload_bytes : Int64) : Nil
      request.query.try { |text| parse_pairs(text, @query, controls: false) }
      if BODY_METHODS.includes?(request.method)
        media_type = request.headers["Content-Type"]?.try(&.split(';', 2).first.strip.downcase)
        case media_type
        when "application/x-www-form-urlencoded"
          parse_urlencoded(request, max_form_bytes)
        when "multipart/form-data"
          parse_multipart(request, max_form_bytes, max_upload_bytes)
        when nil
          raise UnsupportedMediaType.new("Expected a URL-encoded or multipart form") unless empty_body?(request)
        else
          raise UnsupportedMediaType.new("Expected a URL-encoded or multipart form")
        end
      end
      if request.method == "POST" && (override = @submitted_override)
        override = override.upcase
        raise InvalidEncoding.new("Unsupported method override") unless OVERRIDES.includes?(override)
        @method_override = override
      end
    end

    def value?(name : String) : String?
      @route_params[name]? || @body[name]? || @query[name]?
    end

    def file?(name : String) : UploadedFile?
      @files[name]?
    end

    def source_count(name : String) : Int32
      count = 0
      count += 1 if @route_params.has_key?(name)
      count += 1 if @body.has_key?(name)
      count += 1 if @query.has_key?(name)
      count += 1 if @files.has_key?(name)
      count
    end

    # Keys that must be declared by the contract. GET and HEAD queries may
    # carry unrelated parameters such as analytics or cache busters.
    def strict_keys : Array(String)
      keys = @body.keys + @files.keys
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

    private def parse_urlencoded(request : HTTP::Request, max_form_bytes : Int32) : Nil
      if (length = request.headers["Content-Length"]?.try(&.to_i64?)) && length > max_form_bytes
        raise TooLarge.new("Form exceeds #{max_form_bytes} bytes")
      end
      source = request.body
      return unless source
      copied = 0_i64
      text = String.build do |io|
        copied = IO.copy(source, io, max_form_bytes.to_i64 + 1)
      end
      raise TooLarge.new("Form exceeds #{max_form_bytes} bytes") if copied > max_form_bytes
      parse_pairs(text, @body, controls: true)
    end

    private def parse_pairs(text : String, target : Hash(String, String), controls : Bool) : Nil
      raise InvalidEncoding.new("Malformed form encoding") if !text.valid_encoding? || text.matches?(/%(?![0-9a-fA-F]{2})/)
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

    private def parse_multipart(request : HTTP::Request, max_form_bytes : Int32, max_upload_bytes : Int64) : Nil
      text_budget = max_form_bytes.to_i64
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
            raise TooLarge.new("Uploads exceed #{max_upload_bytes} bytes") if copied > upload_budget
          rescue error
            file.close
            file.delete
            raise error
          end
          file.close
          upload_budget -= copied
          @files[name] = UploadedFile.new(part.filename, part.headers["Content-Type"]?, file.path, copied)
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
    rescue error : HTTP::FormData::Error | MIME::Multipart::Error
      raise InvalidEncoding.new("Malformed multipart form")
    end

    private def check_text(text : String) : Nil
      raise InvalidEncoding.new("Malformed form encoding") unless text.valid_encoding? && !text.includes?('\0')
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
