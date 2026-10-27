require "http"
require "uri"
require "openssl/hmac"
require "crypto/subtle"
require "random/secure"

module Caramel
  # Signed double-submit tokens are independent of optional login sessions.
  # Exact Origin checking also prevents sibling local sites from submitting. The
  # configured origin is normalised once (lowercase scheme and host, no `:443`), and
  # a request's `Origin` matches it case-insensitively, with or without `:443`.
  # Tokens and derived keys are made with the current secret and checked against
  # the current secret and each previous one (`APP_SECRET_PREVIOUS`), so a secret
  # rotates without ending every open form and session at once.
  class CSRF
    COOKIE_NAME = "__Host-caramel_csrf"
    LIFETIME    = 24.hours
    # How far ahead of this host's clock another host's issue time may be.
    CLOCK_SKEW = 1.minute

    # The normalised origin: `https://Example.com:443` becomes `https://example.com`.
    getter origin : String
    @origin_with_port : String
    # The current secret first, then the previous ones.
    @secrets : Array(String)

    def initialize(@secret : String, origin : String, previous : Array(String) = [] of String)
      raise ArgumentError.new("CSRF secret must be at least 32 bytes") if @secret.bytesize < 32
      if previous.any? { |old| old.bytesize < 32 }
        raise ArgumentError.new("Each previous CSRF secret must be at least 32 bytes")
      end
      @secrets = [@secret] + previous
      uri = URI.parse(origin)
      unless https_origin?(uri)
        raise ArgumentError.new("CSRF origin must be an HTTPS origin without a path")
      end
      @origin = normalise(uri)
      @origin_with_port = "#{@origin}:443"
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
      return false unless origin?(request.headers["Origin"]?)
      return false unless submitted && submitted.bytesize <= 256
      stored = request.cookies[COOKIE_NAME]?.try(&.value)
      return false unless stored && Crypto::Subtle.constant_time_compare(stored, submitted)
      valid_token?(stored, now)
    end

    # Whether *token* was issued under the current secret or a previous one and
    # has not expired.
    def valid_token?(token : String, now = Time.utc) : Bool
      return false unless token.matches?(/\A[0-9]{1,12}\.[0-9a-f]{64}\.[0-9a-f]{64}\z/)
      timestamp, nonce, signature = token.split('.')
      issued = timestamp.to_i64? || return false
      age = now.to_unix - issued
      return false if issued > now.to_unix + CLOCK_SKEW.total_seconds
      return false if age > LIFETIME.total_seconds
      payload = "#{timestamp}.#{nonce}"
      @secrets.any? do |secret|
        Crypto::Subtle.constant_time_compare(sign(payload, secret), signature)
      end
    end

    # A key for another purpose (such as the session signature), derived from
    # the current secret so that neither signature can stand in for the other.
    def derive_key(purpose : String) : Bytes
      derive(@secret, purpose)
    end

    # The key for *purpose* under the current secret, then under each previous
    # one: what a verifier accepts while a secret rotates out.
    def derive_keys(purpose : String) : Array(Bytes)
      @secrets.map { |secret| derive(secret, purpose) }
    end

    private def derive(secret : String, purpose : String) : Bytes
      OpenSSL::HMAC.digest(:sha256, secret, "caramel.#{purpose}")
    end

    private def sign(payload : String, secret : String = @secret) : String
      OpenSSL::HMAC.hexdigest(:sha256, secret, payload)
    end

    # Whether *header* names the configured origin, in any case and with or without `:443`.
    private def origin?(header : String?) : Bool
      return false unless header

      header.compare(@origin, case_insensitive: true) == 0 ||
        header.compare(@origin_with_port, case_insensitive: true) == 0
    end

    # Lowercase scheme and host, an explicit `:443` dropped. `https_origin?` has already
    # refused a path, so no trailing slash remains.
    private def normalise(uri : URI) : String
      host = (uri.host || raise ArgumentError.new("CSRF origin has no host")).downcase
      port = uri.port
      port.nil? || port == 443 ? "https://#{host}" : "https://#{host}:#{port}"
    end

    # A scheme and a host, with no credentials, path, query or fragment.
    private def https_origin?(uri : URI) : Bool
      return false unless uri.scheme == "https" && uri.host

      uri.user.nil? && uri.password.nil? &&
        uri.query.nil? && uri.fragment.nil? && uri.path.empty?
    end
  end
end
