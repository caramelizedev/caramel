require "../sugar_orm"

module Caramel
  # A string cache in the UNLOGGED `caramel_cache` table,
  # read and written through SugarORM::Repo's current connection. Expired
  # entries read as nil; Cold Brew's maintenance fiber deletes them.
  module Cache
    WRITE = <<-SQL
      INSERT INTO caramel_cache (key, value, expires_at)
      VALUES ($1, $2, now() + make_interval(secs => $3))
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at
      SQL

    READ = "SELECT value FROM caramel_cache " \
           "WHERE key = $1 AND (expires_at IS NULL OR expires_at > now())"

    # `expires_in: nil` keeps the entry until it is deleted or replaced.
    def self.write(key : String, value : String, expires_in : Time::Span? = nil) : Nil
      if expires_in && expires_in <= Time::Span.zero
        raise ArgumentError.new("expires_in must be positive, got #{expires_in}")
      end
      SugarORM.sql_exec(WRITE, key, value, expires_in.try(&.total_seconds))
    end

    def self.read(key : String) : String?
      SugarORM.sql(READ, key, as: {value: String}).first?.try(&.[:value])
    end

    # The cached value, or the block's value, written with `expires_in`.
    def self.fetch(key : String, expires_in : Time::Span? = nil, & : -> String) : String
      if cached = read(key)
        return cached
      end
      value = yield
      write(key, value, expires_in)
      value
    end

    # True when an entry was removed.
    def self.delete(key : String) : Bool
      SugarORM.sql_exec("DELETE FROM caramel_cache WHERE key = $1", key) > 0
    end

    def self.clear : Nil
      SugarORM.sql_exec("DELETE FROM caramel_cache")
    end

    # Deletes expired entries and returns how many.
    def self.vacuum : Int64
      SugarORM.sql_exec("DELETE FROM caramel_cache WHERE expires_at <= now()")
    end
  end
end
