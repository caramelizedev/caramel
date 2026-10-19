require "crypto/subtle"
require "http/cookie"
require "http/request"
require "random/secure"

module Caramel::Crema
  # The per-start key every ops request must present (ADR 0028). It lives in
  # `<socket path>.key`, mode 0600, beside the socket in the same private directory.
  module OpsKey
    SUFFIX = ".key"
    COOKIE = "caramel_ops"
    BYTES  = 32

    def self.path(socket : String) : String
      socket + SUFFIX
    end

    # Writes a new key, replacing any file (or symlink) already at the path.
    def self.create(socket : String) : String
      file = path(socket)
      key = Random::Secure.hex(BYTES)
      File.delete?(file)
      File.open(file, "w", 0o600) { |io| io << key << '\n' }
      File.chmod(file, 0o600)
      key
    end

    def self.read(socket : String) : String?
      File.read(path(socket)).strip.presence
    rescue File::Error
      nil
    end

    def self.remove(socket : String) : Nil
      File.delete?(path(socket))
    end

    def self.valid?(presented : String?, key : String) : Bool
      !presented.nil? && Crypto::Subtle.constant_time_compare(presented, key)
    end

    # The key a request carries: `Authorization: Bearer KEY`, or on GET only the cookie.
    def self.presented(request : HTTP::Request) : String?
      if header = request.headers["Authorization"]?
        scheme, _, rest = header.partition(' ')
        return scheme.compare("Bearer", case_insensitive: true) == 0 ? rest.strip : nil
      end

      request.method == "GET" ? request.cookies[COOKIE]?.try(&.value) : nil
    end

    def self.cookie(key : String) : HTTP::Cookie
      HTTP::Cookie.new(COOKIE, key, path: "/", http_only: true,
        samesite: HTTP::Cookie::SameSite::Strict)
    end
  end
end
