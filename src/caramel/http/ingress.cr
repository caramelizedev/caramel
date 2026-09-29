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

    # The vocabulary the `ingress` macro checks at compile time.
    KEYWORDS = ["body", "limit", "csrf", "authenticate"]
    UNITS    = {
      "kilobyte" => 1_024, "kilobytes" => 1_024,
      "megabyte" => 1_048_576, "megabytes" => 1_048_576,
    }
    EXAMPLE = "ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?"

    getter body : Body
    getter limit : Int64
    getter? csrf : Bool

    # The action method that authenticates the request, when it declares one.
    getter authenticate : String?

    def initialize(@body : Body = Body::Form,
                   @limit : Int64 = DEFAULT_LIMIT,
                   @csrf : Bool = true,
                   @authenticate : String? = nil)
      return if 1 <= @limit <= MAX_LIMIT

      raise ArgumentError.new("An ingress limit is 1 byte to 64 MiB, got #{@limit}")
    end

    DEFAULT = new

    # A `_method` override may reach a route only when that route reads the
    # POST's body the same way, so an override never skips a check.
    def reads_like?(other : Ingress) : Bool
      {body, limit, csrf?} == {other.body, other.limit, other.csrf?}
    end

    # What `routes` prints after a route: empty for DEFAULT, otherwise such
    # as `raw, 256 KiB, csrf off, authenticate signed?`.
    def summary : String
      parts = [] of String
      parts << "raw" if @body.raw?
      parts << Ingress.size(@limit) if @body.raw? || @limit != DEFAULT_LIMIT
      parts << "csrf off" unless @csrf
      @authenticate.try { |name| parts << "authenticate #{name}" }
      parts.join(", ")
    end

    def self.size(bytes : Int64) : String
      return "#{bytes // 1.megabyte} MiB" if bytes.divisible_by?(1.megabyte)
      return "#{bytes // 1.kilobyte} KiB" if bytes.divisible_by?(1.kilobyte)

      "#{bytes} bytes"
    end
  end
end
