module Caramel
  # The roles, database and grants an application's database needs: a migration
  # role that owns the database and a runtime role that reads and writes rows.
  # Latte runs these statements for its sites, and `APP db roles` prints them for
  # a server Latte does not manage.
  module DatabaseRoles
    # A role or database name `script` writes without quoting.
    NAME = /\A[a-z_][a-z0-9_]{0,62}\z/

    MIGRATION_CONNECTION_LIMIT =  1
    RUNTIME_CONNECTION_LIMIT   = 24

    ATTRIBUTES = "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS"

    def self.quote_identifier(identifier : String) : String
      %("#{identifier.gsub("\"", "\"\"")}")
    end

    def self.quote_literal(value : String) : String
      "'#{value.gsub("'", "''")}'"
    end

    # Creates the login role *name* unless it exists, then sets its connection
    # limit. The attributes beyond LOGIN are set only on creation, because
    # PostgreSQL refuses `ALTER ROLE … NOSUPERUSER` from a role that is not a
    # superuser, such as a managed server's administrator.
    def self.role(name : String, connection_limit : Int32, password : String? = nil) : String
      identifier = quote_identifier(name)
      limit = "CONNECTION LIMIT #{connection_limit}"
      secret = password.try { |value| " PASSWORD #{quote_literal(value)}" }
      <<-SQL
        DO $$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{quote_literal(name)}) THEN
            CREATE ROLE #{identifier} #{ATTRIBUTES}
              #{limit}#{secret};
          END IF;
        END $$;
        ALTER ROLE #{identifier} LOGIN #{limit}#{secret};
        SQL
    end

    def self.create_database(database : String, owner : String) : String
      "CREATE DATABASE #{quote_identifier(database)} OWNER #{quote_identifier(owner)} " \
      "ENCODING 'UTF8' TEMPLATE template0;"
    end

    # Run from any database: ownership, the UTC time zone, and CONNECT for the
    # two roles alone.
    def self.database_access(database : String, migration : String, runtime : String) : String
      name = quote_identifier(database)
      owner = quote_identifier(migration)
      <<-SQL
        ALTER DATABASE #{name} OWNER TO #{owner};
        ALTER DATABASE #{name} SET timezone TO 'UTC';
        REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE #{name} FROM PUBLIC;
        GRANT CONNECT ON DATABASE #{name} TO #{owner}, #{quote_identifier(runtime)};
        SQL
    end

    # Run inside the database: the migration role owns schema public and
    # `caramel_migrations`, and the runtime role gets DML on every table the
    # migration role creates.
    def self.schema_access(migration : String, runtime : String) : String
      owner = quote_identifier(migration)
      user = quote_identifier(runtime)
      defaults = "ALTER DEFAULT PRIVILEGES FOR ROLE #{owner} IN SCHEMA public"
      <<-SQL
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        ALTER SCHEMA public OWNER TO #{owner};
        REVOKE ALL ON SCHEMA public FROM #{user};
        GRANT USAGE ON SCHEMA public TO #{user};
        #{defaults}
          REVOKE ALL ON TABLES FROM PUBLIC;
        #{defaults}
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{user};
        #{defaults}
          REVOKE ALL ON SEQUENCES FROM PUBLIC;
        #{defaults}
          GRANT USAGE, SELECT ON SEQUENCES TO #{user};
        CREATE TABLE IF NOT EXISTS caramel_migrations (
          version bigint PRIMARY KEY,
          name text NOT NULL,
          checksum text NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        ALTER TABLE caramel_migrations OWNER TO #{owner};
        REVOKE ALL ON TABLE caramel_migrations FROM #{user};
        GRANT SELECT ON TABLE caramel_migrations TO #{user};
        SQL
    end

    # A psql script, without passwords, that creates both roles and the
    # database. It grants both roles to the role that runs it, which a managed
    # server's administrator that is not a superuser needs to create a database
    # they own and to change its schema. The names must match NAME.
    def self.script(database : String, migration : String, runtime : String) : String
      [
        "-- psql script: creates roles #{migration} and #{runtime} and database #{database}.",
        "-- Set passwords separately.",
        role(migration, MIGRATION_CONNECTION_LIMIT),
        role(runtime, RUNTIME_CONNECTION_LIMIT),
        "GRANT #{quote_identifier(migration)} TO CURRENT_USER;",
        "GRANT #{quote_identifier(runtime)} TO CURRENT_USER;",
        create_database(database, migration),
        database_access(database, migration, runtime),
        "\\connect #{database}",
        schema_access(migration, runtime),
      ].join('\n') + "\n"
    end
  end
end
