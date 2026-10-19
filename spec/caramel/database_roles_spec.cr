require "spec"
require "../../src/caramel"

describe Caramel::DatabaseRoles do
  it "prints the psql script for an application's roles and database" do
    elevated = "SUPERUSER, CREATEDB, CREATEROLE, BYPASSRLS or REPLICATION"
    hint = "As a superuser run ALTER ROLE name NOSUPERUSER NOCREATEDB NOCREATEROLE " \
           "NOBYPASSRLS NOREPLICATION, then run this script again."
    closing = "-- The role that ran this script stays a member of both roles; " \
              "REVOKE them when you no longer need them."
    expected = <<-SQL
      -- psql script: creates roles shop_migration and shop_runtime and database shop.
      -- Set passwords separately. Run with psql -v ON_ERROR_STOP=1 so a failed check stops it.
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shop_migration') THEN
          CREATE ROLE "shop_migration" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS
            CONNECTION LIMIT 1;
        END IF;
      END $$;
      ALTER ROLE "shop_migration" LOGIN CONNECTION LIMIT 1;
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shop_runtime') THEN
          CREATE ROLE "shop_runtime" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS
            CONNECTION LIMIT 24;
        END IF;
      END $$;
      ALTER ROLE "shop_runtime" LOGIN CONNECTION LIMIT 24;
      DO $$
      DECLARE elevated text;
      BEGIN
        SELECT string_agg(rolname, ', ' ORDER BY rolname) INTO elevated FROM pg_roles
          WHERE rolname IN ('shop_migration', 'shop_runtime')
            AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolbypassrls OR rolreplication);
        IF elevated IS NOT NULL THEN
          RAISE EXCEPTION 'role(s) % have #{elevated}', elevated
            USING HINT = '#{hint}';
        END IF;
      END $$;
      GRANT "shop_migration" TO CURRENT_USER;
      GRANT "shop_runtime" TO CURRENT_USER;
      CREATE DATABASE "shop" OWNER "shop_migration" ENCODING 'UTF8' TEMPLATE template0;
      ALTER DATABASE "shop" OWNER TO "shop_migration";
      ALTER DATABASE "shop" SET timezone TO 'UTC';
      REVOKE CONNECT, TEMPORARY, CREATE ON DATABASE "shop" FROM PUBLIC;
      GRANT CONNECT ON DATABASE "shop" TO "shop_migration", "shop_runtime";
      \\connect shop
      REVOKE ALL ON SCHEMA public FROM PUBLIC;
      ALTER SCHEMA public OWNER TO "shop_migration";
      REVOKE ALL ON SCHEMA public FROM "shop_runtime";
      GRANT USAGE ON SCHEMA public TO "shop_runtime";
      ALTER DEFAULT PRIVILEGES FOR ROLE "shop_migration" IN SCHEMA public
        REVOKE ALL ON TABLES FROM PUBLIC;
      ALTER DEFAULT PRIVILEGES FOR ROLE "shop_migration" IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "shop_runtime";
      ALTER DEFAULT PRIVILEGES FOR ROLE "shop_migration" IN SCHEMA public
        REVOKE ALL ON SEQUENCES FROM PUBLIC;
      ALTER DEFAULT PRIVILEGES FOR ROLE "shop_migration" IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO "shop_runtime";
      CREATE TABLE IF NOT EXISTS caramel_migrations (
        version bigint PRIMARY KEY,
        name text NOT NULL,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      ALTER TABLE caramel_migrations OWNER TO "shop_migration";
      REVOKE ALL ON TABLE caramel_migrations FROM "shop_runtime";
      GRANT SELECT ON TABLE caramel_migrations TO "shop_runtime";
      #{closing}

      SQL
    Caramel::DatabaseRoles.script("shop", "shop_migration", "shop_runtime").should eq(expected)
  end

  it "sets a password on every run, outside the DO body" do
    statements = Caramel::DatabaseRoles.role("x", 3, "p'w")
    statements.should end_with("ALTER ROLE \"x\" LOGIN CONNECTION LIMIT 3 PASSWORD 'p''w';")
    statements.split("END $$;").first.should_not contain("PASSWORD")
  end

  it "keeps a hostile password outside the DO" do
    statements = Caramel::DatabaseRoles.role("x", 1, "a$$; DROP ROLE y; --")
    statements.split("ALTER ROLE").first.scan("$$").size.should eq(2)
    statements.scan("DROP ROLE y").size.should eq(1)
    statements.split("ALTER ROLE").first.should_not contain("DROP ROLE y")
  end

  it "refuses bad names" do
    [
      -> { Caramel::DatabaseRoles.script("Bad", "m", "r") },
      -> { Caramel::DatabaseRoles.script("d", "m$$", "r") },
      -> { Caramel::DatabaseRoles.script("d", "m", "r;x") },
      -> { Caramel::DatabaseRoles.script("shop\n\\! id", "m", "r") },
      -> { Caramel::DatabaseRoles.role("a$$b", 1) },
      -> { Caramel::DatabaseRoles.attribute_check(["a'b"]) },
    ].each do |attempt|
      error = expect_raises(ArgumentError) { attempt.call }
      error.message.to_s.should contain("names must match [a-z_][a-z0-9_]*")
    end
  end

  it "checks existing role attributes before any grant" do
    script = Caramel::DatabaseRoles.script("shop", "shop_migration", "shop_runtime")
    script.should contain("rolsuper OR rolcreatedb OR rolcreaterole OR rolbypassrls OR " \
                          "rolreplication")
    grant = script.index!("GRANT \"shop_migration\" TO CURRENT_USER;")
    (script.index!("rolsuper OR") < grant).should be_true
  end

  it "quotes generated SQL identifiers and literals" do
    Caramel::DatabaseRoles.quote_identifier("safe_name").should eq("\"safe_name\"")
    quoted = %("name""with""quotes")
    Caramel::DatabaseRoles.quote_identifier(%(name"with"quotes)).should eq(quoted)
    Caramel::DatabaseRoles.quote_literal("don't").should eq("'don''t'")
  end
end

describe "APP db" do
  it "refuses role and database names it would have to quote" do
    Caramel::Crema.run_command("db", ["roles", "Bad", "m", "r"]).should eq(2)
    Caramel::Crema.run_command("db", ["roles", "d", "m$$", "r"]).should eq(2)
  end

  it "refuses an unknown subcommand" do
    Caramel::Crema.run_command("db", ["frobnicate"]).should eq(2)
  end
end
