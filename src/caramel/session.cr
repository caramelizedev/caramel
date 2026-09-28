require "base64"
require "json"
require "http/cookie"
require "openssl/hmac"
require "crypto/subtle"

module Caramel
  # The signed, client-held login session: `__Host-caramel_session` carries
  # base64url JSON of a String => String hash and its HMAC-SHA256. It has no
  # server-side expiry and lives until the browser session ends or the
  # application clears it (`sign_out`).
  class Session
    COOKIE_NAME      = "__Host-caramel_session"
    MAX_COOKIE_BYTES = 4096

    class Overflow < Exception
    end

    def initialize(@key : Bytes)
    end

    # The cookie value for `data`; raises `Overflow` when the Set-Cookie
    # name=value pair would exceed 4 KB, which browsers silently drop.
    def encode(data : Hash(String, String)) : String
      payload = Base64.urlsafe_encode(data.to_json, padding: false)
      value = "#{payload}.#{sign(payload)}"
      if COOKIE_NAME.bytesize + 1 + value.bytesize > MAX_COOKIE_BYTES
        raise Overflow.new("The session exceeds #{MAX_COOKIE_BYTES} bytes. Store large values in the database and keep only their ids in the session.")
      end
      value
    end

    # The session a cookie value carries, or nil when it is oversized,
    # malformed or not signed with this application's secret.
    def decode(value : String) : Hash(String, String)?
      return if COOKIE_NAME.bytesize + 1 + value.bytesize > MAX_COOKIE_BYTES
      payload, dot, signature = value.rpartition('.')
      return if dot.empty? || payload.empty?
      return unless Crypto::Subtle.constant_time_compare(sign(payload), signature)
      Hash(String, String).from_json(Base64.decode_string(payload))
    rescue JSON::ParseException | TypeCastError
      nil
    end

    # Persists `data`, or deletes the cookie when `data` is empty. The cookie
    # has no Max-Age or Expires: it is a browser-session cookie.
    def cookie(data : Hash(String, String)) : HTTP::Cookie
      if data.empty?
        HTTP::Cookie.new(COOKIE_NAME, "", path: "/", secure: true, http_only: true, samesite: HTTP::Cookie::SameSite::Lax, max_age: Time::Span.zero)
      else
        HTTP::Cookie.new(COOKIE_NAME, encode(data), path: "/", secure: true, http_only: true, samesite: HTTP::Cookie::SameSite::Lax)
      end
    end

    private def sign(payload : String) : String
      Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, @key, payload), padding: false)
    end
  end
end
