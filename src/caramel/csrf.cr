require "http"
require "uri"
require "openssl/hmac"
require "crypto/subtle"
require "random/secure"

module Caramel
  # Signed double-submit tokens are independent of optional login sessions.
  # Exact Origin checking also prevents sibling local sites from submitting.
  class CSRF
    COOKIE_NAME = "__Host-caramel_csrf"
    LIFETIME    = 24.hours

    getter origin : String

    def initialize(@secret : String, @origin : String)
      raise ArgumentError.new("CSRF secret must be at least 32 bytes") if @secret.bytesize < 32
      unless https_origin?(URI.parse(@origin))
        raise ArgumentError.new("CSRF origin must be an HTTPS origin without a path")
      end
    end

    def issue(now = Time.utc) : String
      payload = "#{now.to_unix}.#{Random::Secure.hex(32)}"
      "#{payload}.#{sign(payload)}"
    end

    def cookie(token : String) : HTTP::Cookie
      HTTP::Cookie.new(
        COOKIE_NAME,
        token,
        path: "/",
        secure: true,
        http_only: true,
        samesite: HTTP::Cookie::SameSite::Lax,
        max_age: LIFETIME,
      )
    end

    def valid?(request : HTTP::Request, submitted : String?, now = Time.utc) : Bool
      return false unless request.headers["Origin"]? == @origin
      return false unless submitted && submitted.bytesize <= 256
      stored = request.cookies[COOKIE_NAME]?.try(&.value)
      return false unless stored && Crypto::Subtle.constant_time_compare(stored, submitted)
      valid_token?(stored, now)
    end

    def valid_token?(token : String, now = Time.utc) : Bool
      return false unless token.matches?(/\A[0-9]{1,12}\.[0-9a-f]{64}\.[0-9a-f]{64}\z/)
      timestamp, nonce, signature = token.split('.')
      issued = timestamp.to_i64? || return false
      age = now.to_unix - issued
      return false unless issued <= now.to_unix && age <= LIFETIME.total_seconds
      Crypto::Subtle.constant_time_compare(sign("#{timestamp}.#{nonce}"), signature)
    end

    # A key for another purpose (such as the session signature), derived from
    # the application secret so that neither signature can stand in for the other.
    def derive_key(purpose : String) : Bytes
      OpenSSL::HMAC.digest(:sha256, @secret, "caramel.#{purpose}")
    end

    private def sign(payload : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, @secret, payload)
    end

    # A scheme and a host, with no credentials, path, query or fragment.
    private def https_origin?(uri : URI) : Bool
      return false unless uri.scheme == "https" && uri.host

      uri.user.nil? && uri.password.nil? &&
        uri.query.nil? && uri.fragment.nil? && uri.path.empty?
    end
  end
end
