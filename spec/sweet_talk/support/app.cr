require "spec"
require "random/secure"
require "./tea_shop"
require "./rules"
require "./renamed"
require "./tea_house"
require "./ledger"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
private def owned_url(variable : String) : String
  ENV[variable]? || raise "Run scripts/check integration; no #{variable} provided"
end

# SweetTalk's domains (ADRs 0030 and 0031) on a scratch database of their own. Most
# examples run in a transaction that is rolled back; those that need commits empty
# every table afterwards.
module SweetTalkSpec
  ADMIN_URL   = owned_url("CARAMEL_OWNED_ADMIN_URL")
  OWNER_URL   = owned_url("CARAMEL_OWNED_SPEC_URL")
  RUNTIME_URL = owned_url("CARAMEL_OWNED_MODEL_RUNTIME_URL")
  NAME        = "caramel_sweet_talk_#{Random::Secure.hex(6)}"

  @@owner : DB::Database? = nil
  @@runtime : DB::Database? = nil

  def self.url(base : String) : String
    base.sub("/caramel_spec?", "/#{NAME}?")
  end

  # The scratch database, owned by the spec role and migrated from the declared
  # schemas. The runtime role gets only CONNECT, schema USAGE and DML, like a Latte
  # runtime role.
  def self.owner : DB::Database
    @@owner ||= begin
      admin = Caramel::Database.open(ADMIN_URL, 1)
      begin
        admin.exec(%(CREATE DATABASE "#{NAME}" OWNER caramel_spec))
        admin.exec(%(REVOKE CONNECT, TEMPORARY ON DATABASE "#{NAME}" FROM PUBLIC))
        admin.exec(%(GRANT CONNECT ON DATABASE "#{NAME}" TO caramel_spec, caramel_model_spec))
      ensure
        admin.close
      end
      owner = Caramel::Database.open(url(OWNER_URL), 2)
      owner.exec("REVOKE ALL ON SCHEMA public FROM PUBLIC")
      owner.exec("GRANT USAGE ON SCHEMA public TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT USAGE, SELECT ON SEQUENCES TO caramel_model_spec")
      SugarORM::Migrator.new(owner, Caramel::ColdBrew::MIGRATIONS + [schemas]).migrate
      owner
    end
  end

  def self.runtime : DB::Database
    @@runtime ||= Caramel::Database.open(url(RUNTIME_URL), 8)
  end

  def self.drop : Nil
    return unless @@owner
    @@runtime.try(&.close)
    @@owner.try(&.close)
    admin = Caramel::Database.open(ADMIN_URL, 1)
    admin.exec(%(DROP DATABASE IF EXISTS "#{NAME}" WITH (FORCE)))
    admin.close
  end

  # The migration that creates every declared table.
  private def self.schemas : SugarORM::Migration
    tables = SugarORM::Catalog.declared
    plan = SugarORM::Differ.diff(tables, [] of SugarORM::Catalog::Table)
    statements = SugarORM::DDL.statements(plan.transactional)
    SugarORM::Migration.new(20261009000000_i64, "create_sweet_talk", statements)
  end

  # Runs the block inside a transaction on one runtime connection, then rolls it back.
  def self.rolled_back(&) : Nil
    runtime.using_connection do |connection|
      connection.transaction do |transaction|
        SugarORM::Repo.bind(transaction) { yield connection }
        transaction.rollback
      end
    end
  end

  # Runs the block on committed data, then empties every table through the owner.
  def self.committed(&) : Nil
    yield
  ensure
    tables = SugarORM::Catalog.declared.map { |table| %("#{table.name}") } + ["caramel_jobs"]
    owner.exec("TRUNCATE #{tables.join(", ")} RESTART IDENTITY CASCADE")
  end

  def self.count(table : String) : Int64
    SugarORM.sql("SELECT count(*) AS value FROM #{table}", as: {value: Int64}).first[:value]
  end

  # Polls every 50 ms until the block is true, for up to 10 s.
  def self.eventually(what : String, &) : Nil
    deadline = Time.instant + 10.seconds
    until yield
      fail "#{what} not within 10 s" if Time.instant > deadline
      sleep 50.milliseconds
    end
  end
end

Spec.before_suite do
  SweetTalkSpec.owner
  SugarORM::Repo.database = SweetTalkSpec.runtime
end

Spec.after_suite { SweetTalkSpec.drop }
