require "../units"

module Caramel
  # How a route reads its request (ADR 0020): the body it accepts, the most
  # bytes of it that are read, and whether the browser CSRF check or the
  # action's own authenticator guards it. Actions declare one with `ingress`;
  # every other route uses DEFAULT.
  struct Ingress
    enum Body
      # URL-encoded and multipart forms, or a JSON object, bound into the contract.
      Form
      # The bytes exactly as sent, for `raw_body`; the contract binds only the
      # route and the query.
      Raw
    end

    DEFAULT_LIMIT = 2_097_152_i64
    # Bodies are held in memory, so a route cannot ask for more than uploads get.
    MAX_LIMIT = 67_108_864_i64

    getter body : Body
    getter limit : Int64
    getter? csrf : Bool
    # The action method that authenticates the request, when it declares one.
    getter authenticate : String?

    def initialize(@body : Body = Body::Form, @limit : Int64 = DEFAULT_LIMIT, @csrf : Bool = true, @authenticate : String? = nil)
      raise ArgumentError.new("An ingress limit is 1 byte to 64 MiB, got #{@limit}") unless 1 <= @limit <= MAX_LIMIT
    end

    DEFAULT = new

    # A `_method` override may reach a route only when that route reads the
    # POST's body the same way, so an override never skips a check.
    def reads_like?(other : Ingress) : Bool
      @body == other.body && @limit == other.limit && @csrf == other.csrf?
    end

    # What `routes` prints after a route; empty for DEFAULT.
    def summary : String
      parts = [] of String
      parts << "raw" if @body.raw?
      parts << Ingress.size(@limit) if @body.raw? || @limit != DEFAULT_LIMIT
      parts << "csrf off" unless @csrf
      @authenticate.try { |name| parts << "authenticate #{name}" }
      parts.join(", ")
    end

    def self.size(bytes : Int64) : String
      if bytes % 1.megabyte == 0
        "#{bytes // 1.megabyte} MiB"
      elsif bytes % 1.kilobyte == 0
        "#{bytes // 1.kilobyte} KiB"
      else
        "#{bytes} bytes"
      end
    end
  end
end
