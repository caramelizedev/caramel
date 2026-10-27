require "base64"
require "json"
require "http/cookie"
require "openssl/hmac"
require "crypto/subtle"
require "./csrf"

module Caramel
  # The signed, client-held login session: `__Host-caramel_session` carries
  # base64url JSON of a String => String hash, the unix second it was signed
  # and their HMAC-SHA256. The cookie is a browser-session cookie, and a value
  # older than `max_age` (14 days by default) reads as empty. The window is
  # absolute: an action re-signs the cookie only when it changes the session,
  # so an unchanged session ends `max_age` after its last write. Nothing is
  # stored server-side, so a copied cookie stays valid until then even after
  # `sign_out`; an application that must end a session everywhere keeps a
  # revocable row, as the website's Revocable sessions recipe shows. The hash
  # an action gets is a `Data`: a write that would take the Set-Cookie past
  # 4 KB raises `Overflow` at the write, before the action does anything else.
  class Session
    COOKIE_NAME      = "__Host-caramel_session"
    MAX_COOKIE_BYTES = 4096
    MAX_AGE          = 14.days
    # The unix second a cookie was signed: 10 digits until 2286.
    ISSUED_BYTES = 10
    # An HMAC-SHA256 digest in unpadded base64url.
    SIGNATURE_BYTES  = 43
    OVERFLOW_MESSAGE = "The session exceeds #{MAX_COOKIE_BYTES} bytes. Store large " \
                       "values in the database and keep only their ids in the session."

    class Overflow < Exception
    end

    # The session an action reads and writes. Every writer that can grow it
    # (`[]=`, `merge!`, `update`, `put`, `put_if_absent`, `transform_values!`)
    # checks that the cookie still fits, and one that would not leaves the
    # session as it was and raises `Overflow`.
    class Data < Hash(String, String)
      def initialize(loaded : Hash(String, String))
        super()
        merge!(loaded)
      end

      def []=(key : String, value : String) : String
        previous = self[key]?
        super
        return value if Session.fits?(self)

        previous ? super(key, previous) : delete(key)
        raise Overflow.new(OVERFLOW_MESSAGE)
      end

      def update(key : String, & : String -> String) : String
        previous = self[key]
        self[key] = yield previous
        previous
      end

      def put(key : String, value : String, &)
        return put_present(key, value) if has_key?(key)

        self[key] = value
        yield key
      end

      def put_if_absent(key : String, & : String -> String) : String
        fetch(key) { self[key] = yield key }
      end

      def transform_values!(& : String, String -> String) : self
        keys.each { |key| self[key] = yield self[key], key }
        self
      end

      private def put_present(key : String, value : String) : String
        previous = self[key]
        self[key] = value
        previous
      end
    end

    # The bytes the Set-Cookie name=value pair for `data` takes, without
    # encoding it: the name, `=`, the unpadded base64 of the JSON, `.`, the
    # issue time, `.` and the signature.
    def self.cookie_bytes(data : Hash(String, String)) : Int32
      payload = (4 * data.to_json.bytesize + 2) // 3
      COOKIE_NAME.bytesize + 1 + payload + 1 + ISSUED_BYTES + 1 + SIGNATURE_BYTES
    end

    # Whether the Set-Cookie for `data` stays within `MAX_COOKIE_BYTES`,
    # past which browsers silently drop it.
    def self.fits?(data : Hash(String, String)) : Bool
      cookie_bytes(data) <= MAX_COOKIE_BYTES
    end

    # *keys* are `CSRF#derive_keys("session")`: the first signs, and every one
    # verifies, so cookies signed under a previous secret still read.
    def initialize(@keys : Array(Bytes), @max_age : Time::Span = MAX_AGE)
      raise ArgumentError.new("Session needs at least one key") if @keys.empty?
    end

    # The cookie value for `data`, signed at *now* with the current key; raises
    # `Overflow` when the Set-Cookie name=value pair would exceed 4 KB. `Data`
    # refuses such a write already; this guards a hash built some other way.
    def encode(data : Hash(String, String), now = Time.utc) : String
      raise Overflow.new(OVERFLOW_MESSAGE) unless Session.fits?(data)

      payload = Base64.urlsafe_encode(data.to_json, padding: false)
      signed = "#{payload}.#{now.to_unix}"
      "#{signed}.#{sign(signed, @keys.first)}"
    end

    # The session a cookie value carries, or nil when it is oversized,
    # malformed, signed with none of this application's keys, issued more
    # than `CSRF::CLOCK_SKEW` after *now* or older than `max_age`.
    def decode(value : String, now = Time.utc) : Hash(String, String)?
      return if COOKIE_NAME.bytesize + 1 + value.bytesize > MAX_COOKIE_BYTES
      signed, dot, signature = value.rpartition('.')
      return if dot.empty?
      payload, dot, issued = signed.rpartition('.')
      return if dot.empty? || payload.empty?
      issued_at = issued.to_i64? || return
      return if issued_at > now.to_unix + CSRF::CLOCK_SKEW.total_seconds
      return if now.to_unix - issued_at > @max_age.total_seconds
      return unless signed?(signed, signature)
      Hash(String, String).from_json(Base64.decode_string(payload))
    rescue JSON::ParseException | TypeCastError
      nil
    end

    # Persists `data`, or deletes the cookie when `data` is empty. The cookie
    # has no Max-Age or Expires: it is a browser-session cookie.
    def cookie(data : Hash(String, String)) : HTTP::Cookie
      return session_cookie("", max_age: Time::Span.zero) if data.empty?

      session_cookie(encode(data))
    end

    private def session_cookie(value : String, max_age : Time::Span? = nil) : HTTP::Cookie
      HTTP::Cookie.new(
        COOKIE_NAME,
        value,
        path: "/",
        secure: true,
        http_only: true,
        samesite: HTTP::Cookie::SameSite::Lax,
        max_age: max_age,
      )
    end

    # Whether *signature* is *payload*'s HMAC under any key, the current one first.
    private def signed?(payload : String, signature : String) : Bool
      @keys.any? { |key| Crypto::Subtle.constant_time_compare(sign(payload, key), signature) }
    end

    private def sign(payload : String, key : Bytes) : String
      Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, key, payload), padding: false)
    end
  end
end
