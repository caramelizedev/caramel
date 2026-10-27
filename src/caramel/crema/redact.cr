require "uri"

module Caramel::Crema
  # Text that may leave the process (the in-memory error ring, development
  # pages) is scrubbed first: secret-looking environment values, database
  # URLs, URL userinfo, cookies, PostgreSQL key details and `name=value`
  # credentials never survive.
  module Redact
    # A credential written as `name=value`, `name: "value"` or `"name": "value"`, and a
    # bearer token on its own.
    NAMES = "password|passwd|secret|token|api[_-]?key|access_key|private_key|credential|" \
            "authorization"
    VALUE        = %q((?:(?-i:Bearer|Basic)\s+\S+|"[^"]*"|'[^']*'|[^\s,;]+))
    BARE         = %q(\b(?-i:Bearer)\s+[A-Za-z0-9._~+/=-]+)
    CREDENTIAL   = /(?:\b[A-Za-z0-9_]*(?:#{NAMES})["']?\s*[=:]\s*#{VALUE})|#{BARE}/i
    DATABASE_URL = /postgres(?:ql)?:\/\/[^\s"'<>]+/
    # `scheme://user:pass@` in any other URL; the scheme and host stay.
    URL_USERINFO = /\b([a-z][a-z0-9+.\-]*:\/\/)[^\/\s"'<>@:]+:[^\/\s"'<>@]*@/i
    # A `Cookie:` or `Set-Cookie:` header line, or a `cookie=` pair, to its end of line.
    COOKIE = /\b(?:Set-)?Cookie["']?\s*[:=]\s*[^\r\n]+/i
    # The values of PostgreSQL's `Key (email)=(a@b.c) already exists`; the columns stay.
    KEY_DETAIL = /\bKey (\([^)]*\))=\([^)]*\)/

    # The values of secret-looking environment variables, and the password
    # in each PostgreSQL URL among them. A value that is not a valid URL stays a
    # secret as written.
    def self.secrets(env = ENV) : Array(String)
      secrets = [] of String
      env.each do |key, value|
        next unless key.matches?(/SECRET|PASSWORD|TOKEN|API_KEY|DATABASE_URL/i)
        secrets << value unless value.empty?
        next unless value.starts_with?("postgres://") || value.starts_with?("postgresql://")

        password = url_password(value)
        secrets << password if password && !password.empty?
      end
      secrets
    end

    private def self.url_password(value : String) : String?
      password = URI.parse(value).password
      password.try { |encoded| URI.decode(encoded) }
    rescue URI::Error
      nil
    end

    # *text* with every secret, database URL, URL userinfo, cookie, key detail and
    # credential removed, cut to at most *limit* bytes. Pass `credentials: false` for
    # compiler output, whose `password=` style text is source code, not a leaked value.
    def self.text(text : String,
                  secrets : Array(String),
                  limit : Int32,
                  credentials : Bool = true) : String
      safe = text.scrub
      known = secrets.reject(&.empty?).sort_by!(&.bytesize)
      known.reverse_each { |secret| safe = safe.gsub(secret, "[redacted]") }
      safe = safe.gsub(DATABASE_URL, "[database URL redacted]")
      safe = safe.gsub(URL_USERINFO, "\\1[credential redacted]@")
      safe = safe.gsub(COOKIE, "Cookie: [credential redacted]")
      safe = safe.gsub(KEY_DETAIL, "Key \\1=([redacted])")
      safe = safe.gsub(CREDENTIAL, "[credential redacted]") if credentials
      safe.byte_slice(0, Math.min(safe.bytesize, limit)).scrub
    end
  end
end
