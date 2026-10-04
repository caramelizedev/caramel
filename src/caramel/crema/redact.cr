require "uri"

module Caramel::Crema
  # Text that may leave the process (the in-memory error ring, development
  # pages) is scrubbed first: secret-looking environment values, database
  # URLs and `name=value` credentials never survive.
  module Redact
    # A credential written as `name=value` or `name: "value"`.
    CREDENTIAL =
      /\b[A-Za-z0-9_]*(?:password|secret|token|api_key)\s*[=:]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)/i
    DATABASE_URL = /postgres(?:ql)?:\/\/[^\s"'<>]+/

    # The values of secret-looking environment variables, and the password
    # in each PostgreSQL URL among them.
    def self.secrets(env = ENV) : Array(String)
      secrets = [] of String
      env.each do |key, value|
        next unless key.matches?(/SECRET|PASSWORD|TOKEN|API_KEY|DATABASE_URL/i)
        secrets << value unless value.empty?
        if value.starts_with?("postgres://") || value.starts_with?("postgresql://")
          password = URI.parse(value).password
          secrets << URI.decode(password) if password && !password.empty?
        end
      end
      secrets
    end

    # *text* with every secret, database URL and credential removed, cut to
    # at most *limit* bytes.
    def self.text(text : String, secrets : Array(String), limit : Int32) : String
      safe = text.scrub
      known = secrets.reject(&.empty?).sort_by!(&.bytesize)
      known.reverse_each { |secret| safe = safe.gsub(secret, "[redacted]") }
      safe = safe.gsub(DATABASE_URL, "[database URL redacted]")
      safe = safe.gsub(CREDENTIAL, "[credential redacted]")
      safe.byte_slice(0, Math.min(safe.bytesize, limit)).scrub
    end
  end
end
