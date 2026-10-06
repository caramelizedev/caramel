require "crypto/subtle"
require "openssl/hmac"

module Caramel::Crema
  # A signed, expiring permission to trace and keep one person's requests. The
  # token is `"<expires_unix>.<hmac>"`; an operator issues one on the ops socket
  # and sends it as `X-Caramel-Debug` or the `__Host-caramel_debug` cookie.
  module DebugToken
    HEADER = "X-Caramel-Debug"
    COOKIE = "__Host-caramel_debug"
    # No token may outlive this, whatever it claims.
    MAX_AGE = 2.hours

    # A token valid for *minutes*, and when it expires.
    def self.issue(key : Bytes, minutes : Int32, now : Time = Time.utc) : {String, Time}
      expires = now + minutes.minutes
      unix = expires.to_unix
      {"#{unix}.#{sign(key, unix)}", expires}
    end

    # True when *token* was signed with *key*, has not expired and does not
    # claim more than two hours.
    def self.valid?(key : Bytes, token : String, now : Time = Time.utc) : Bool
      stamp, _, signature = token.partition('.')
      unix = stamp.to_i64? || return false
      return false unless Crypto::Subtle.constant_time_compare(signature, sign(key, unix))

      current = now.to_unix
      unix > current && unix <= current + MAX_AGE.total_seconds.to_i64
    end

    private def self.sign(key : Bytes, unix : Int64) : String
      OpenSSL::HMAC.hexdigest(:sha256, key, unix.to_s)
    end
  end
end
