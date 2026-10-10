require "spec"
require "../../src/caramel/database"
require "../../src/sugar_orm"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
owner_url = ENV["CARAMEL_OWNED_SPEC_URL"]? ||
            raise "Run scripts/check integration; no owned test database provided"
runtime_url = ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"]? ||
              raise "Run scripts/check integration; no runtime role URL provided"

module SugarSpec
  struct Team < SugarORM::Schema
    schema "sugar_teams" do
      field id : Int64, primary: true
      field name : String
      field seats : Int32 = 5
      field archived : Bool = false
      field billing_email : String?
      timestamps
      has_many users : User
      belongs_to owner : User?
      has_one profile : Profile
      index :name, unique: true
    end

    scope active { where(archived: false) }
    scope larger_than(seats : Int32) { where("seats > ?", seats) }
  end

  struct User < SugarORM::Schema
    schema "sugar_users" do
      field id : Int64, primary: true
      field email : String
      field score : Float64?
      belongs_to team : Team
      timestamps
      index :email, unique: true
    end
  end

  struct Profile < SugarORM::Schema
    schema "sugar_profiles" do
      field id : Int64, primary: true
      field bio : String
      belongs_to team : Team
    end
  end

  record Rate, text : String

  module RateCodec
    def self.sql_type : String
      "numeric(30,10)"
    end

    def self.encode(value : Rate) : String
      value.text
    end

    def self.decode(text : String) : Rate
      Rate.new(text)
    end
  end

  record Snapshot, label : String, history : Array(Hash(String, String)) do
    include JSON::Serializable
  end

  struct Quote < SugarORM::Schema
    schema "sugar_quotes" do
      field id : Int64, primary: true
      field rate : Rate, codec: RateCodec
      field fee : Rate?, codec: RateCodec
      field snapshot : Snapshot, codec: SugarORM::JSONB(Snapshot)
    end
  end

  struct Shelf < SugarORM::Schema
    schema "sugar_shelves" do
      field id : Int64, primary: true
      field stock : Int32 = 0
      field reserved : Int32 = 0
      check stock: 0..10
      check :reserved_within_stock, "reserved <= stock"
    end
  end

  struct Sale < SugarORM::Schema
    schema "sugar_sales" do
      field id : Int64, primary: true
      field tea_id : Int64
      field sold : Int32 = 0
      field lock_version : Int32, version: true
      timestamps
      index :tea_id, unique: true
    end
  end

  class Sale::Count < SugarORM::Changeset(Sale)
    param sold : Int32
    param lock_version : Int32
  end

  class Sale::Record < SugarORM::Changeset(Sale)
    param tea_id : Int64
    param sold : Int32
    upsert on: :tea_id, update: [:sold]
  end

  class Sale::Seed < SugarORM::Changeset(Sale)
    param tea_id : Int64
    param sold : Int32
    upsert on: :tea_id
  end

  alias Preloads = NamedTuple(users: Array(User), owner: User?, profile: Profile?)

  class Team::UpdateChangeset < SugarORM::Changeset(Team)
    param seats : Int32
    param billing_email : String?

    def validate(cs)
      cs.validate_greater_than(:seats, 0)
      cs.validate_format(:billing_email, /\A[^@\s]+@[^@\s]+\z/)
    end
  end

  class User::CreateChangeset < SugarORM::Changeset(User)
    param email : String
    param team_id : Int64

    def validate(cs)
      cs.validate_format(:email, /@/)
      cs.unique_constraint(:email, "is already registered")
    end
  end

  class Shelf::CreateChangeset < SugarORM::Changeset(Shelf)
    param stock : Int32
    param reserved : Int32

    def validate(cs)
      cs.check_constraint(:stock)
      cs.check_constraint(:reserved_within_stock, on: :reserved, message: "exceeds stock")
    end
  end

  def self.with_tables(owner_url : String, runtime_url : String, &)
    owner = Caramel::Database.open(owner_url)
    runtime = Caramel::Database.open(runtime_url)
    SugarORM::Repo.database = runtime
    begin
      owner.exec(<<-SQL)
        CREATE TABLE sugar_teams (
          id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          name text NOT NULL,
          seats integer NOT NULL DEFAULT 5,
          archived boolean NOT NULL DEFAULT false,
          billing_email text,
          created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
          owner_id bigint
        )
        SQL
      owner.exec("CREATE UNIQUE INDEX index_sugar_teams_on_name ON sugar_teams (name)")
      owner.exec(<<-SQL)
        CREATE TABLE sugar_users (
          id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          email text NOT NULL,
          score double precision,
          team_id bigint NOT NULL REFERENCES sugar_teams (id),
          created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        SQL
      owner.exec("CREATE UNIQUE INDEX index_sugar_users_on_email ON sugar_users (email)")
      profiles = "CREATE TABLE sugar_profiles (" \
                 "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, " \
                 "bio text NOT NULL, " \
                 "team_id bigint NOT NULL REFERENCES sugar_teams (id))"
      owner.exec(profiles)
      quotes = "CREATE TABLE sugar_quotes (" \
               "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, " \
               "rate numeric(30,10) NOT NULL, fee numeric(30,10), snapshot jsonb NOT NULL)"
      owner.exec(quotes)
      owner.exec(SugarORM::DDL.create_table(SugarSpec::Shelf.__sugar_table))
      owner.exec(SugarORM::DDL.create_table(SugarSpec::Sale.__sugar_table))
      SugarSpec::Sale.__sugar_table.indexes.each do |index|
        add = SugarORM::Differ::AddIndex.new("sugar_sales", index, concurrently: false)
        owner.exec(SugarORM::DDL.render(add))
      end
      tables = "sugar_teams, sugar_users, sugar_profiles, sugar_quotes, sugar_shelves, " \
               "sugar_sales"
      sequences = "sugar_teams_id_seq, sugar_users_id_seq, sugar_profiles_id_seq, " \
                  "sugar_quotes_id_seq, sugar_shelves_id_seq, sugar_sales_id_seq"
      owner.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON #{tables} TO caramel_model_spec")
      owner.exec("GRANT USAGE, SELECT ON SEQUENCE #{sequences} TO caramel_model_spec")
      yield owner, runtime
    ensure
      owner.exec("DROP TABLE IF EXISTS sugar_sales, sugar_shelves, sugar_quotes, " \
                 "sugar_profiles, sugar_users, sugar_teams")
      runtime.close
      owner.close
    end
  end

  def self.statements(&) : Int64
    before = SugarORM::Repo.statements_executed
    yield
    SugarORM::Repo.statements_executed - before
  end

  # Blocks until some backend waits for a lock, or raises after five seconds.
  def self.await_lock_wait(owner : DB::Database) : Nil
    deadline = Time.instant + 5.seconds
    until owner.scalar("SELECT count(*) FROM pg_locks WHERE NOT granted").as(Int64) >= 1
      raise "no backend waited for a lock within 5 seconds" if Time.instant > deadline
      sleep 10.milliseconds
    end
  end

  # Runs *first* in a transaction on one pool connection, then *second* in a transaction on
  # another, once *first* holds what *second* will wait for. *second* is released only after
  # the database shows a waiter; then *first* ends, by committing or, with *rollback*, by
  # rolling back. Both connections are proven distinct by their backend pids.
  def self.contend(owner : DB::Database,
                   first : Proc,
                   second : Proc,
                   rollback : Bool = false) : Nil
    pids = Channel(Int32).new(2)
    ready = Channel(Nil).new
    release = Channel(Nil).new(1)
    first_done = Channel(Exception?).new
    second_done = Channel(Exception?).new
    spawn do
      signalled = false
      error = nil
      begin
        SugarORM::Repo.transaction do
          pids.send(backend_pid)
          first.call
          signalled = true
          ready.send(nil)
          release.receive
          SugarORM::Repo.rollback if rollback
        end
      rescue ex
        error = ex
        ready.send(nil) unless signalled
      end
      first_done.send(error)
    end
    ready.receive
    spawn do
      error = nil
      begin
        SugarORM::Repo.transaction do
          pids.send(backend_pid)
          second.call
        end
      rescue ex
        error = ex
      end
      second_done.send(error)
    end
    begin
      await_lock_wait(owner)
    ensure
      release.send(nil)
    end
    errors = [first_done.receive, second_done.receive].compact
    raise errors.first unless errors.empty?
    [pids.receive, pids.receive].uniq.size.should eq(2)
  end

  def self.backend_pid : Int32
    SugarORM.sql("SELECT pg_backend_pid() AS pid", as: {pid: Int32}).first[:pid]
  end
end

# The names of the teams `query` returns, in its order.
private def names(query) : Array(String)
  query.to_a.map(&.name)
end

# A DO NOTHING upsert of tea 9 selling *sold*.
private def upsert_seed(sold : Int32) : SugarSpec::Sale::Seed
  SugarSpec::Sale::Seed.new(tea_id: 9_i64, sold: sold)
end

# A DO UPDATE upsert of tea 9 selling *sold*.
private def upsert_record(sold : Int32) : SugarSpec::Sale::Record
  SugarSpec::Sale::Record.new(tea_id: 9_i64, sold: sold)
end

describe "SugarORM with PostgreSQL" do
  it "runs as a restricted role that can write rows but cannot create tables" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      role = SugarORM.sql("SELECT current_user::text AS name", as: {name: String})
      role.should eq([{name: "caramel_model_spec"}])
      forbidden = "CREATE TABLE sugar_forbidden (id integer)"
      expect_raises(PQ::PQError, /permission denied/) { SugarORM.sql_exec(forbidden) }
    end
  end

  it "creates, updates and deletes through the facade and explicit changesets" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      team = SugarSpec::Team.create!(name: "Acme")
      team.id.should be > 0
      team.seats.should eq(5)
      team.archived.should be_false
      team.billing_email.should be_nil

      duplicate = SugarSpec::Team.create(name: "Acme")
      duplicate.saved?.should be_false
      duplicate.errors.should eq({"name" => ["has already been taken"]})
      taken = "SugarSpec::Team::DefaultChangeset is invalid: name has already been taken"
      expect_raises(SugarORM::Invalid, taken) { SugarSpec::Team.create!(name: "Acme") }

      unnamed = SugarSpec.statements do
        SugarSpec::Team.create(seats: 3).errors.should eq({"name" => ["is required"]})
      end
      unnamed.should eq(0)

      rename = "UPDATE sugar_teams SET name = 'Acme Corp', updated_at = '2000-01-01' " \
               "WHERE id = $1"
      owner.exec(rename, team.id)
      updated = SugarSpec.statements do
        team.update!(seats: 10, billing_email: "billing@acme.com").seats.should eq(10)
      end
      updated.should eq(1)
      stored = SugarSpec::Team.query.find!(team.id)
      stored.name.should eq("Acme Corp")
      stored.billing_email.should eq("billing@acme.com")
      stored.updated_at.should be > Time.utc(2001, 1, 1)

      invalid = stored.update(seats: 0)
      invalid.saved?.should be_false
      invalid.errors.should eq({"seats" => ["must be greater than 0"]})
      expect_raises(SugarORM::Invalid, /seats must be greater than 0/) { stored.update!(seats: -1) }

      explicit = SugarSpec::Team::UpdateChangeset.new(stored, seats: 12)
      SugarORM::Repo.update(explicit).should be(explicit)
      explicit.saved?.should be_true
      explicit.record.seats.should eq(12)
      explicit.record.name.should eq("Acme Corp")
      SugarSpec::Team.query.find!(team.id).seats.should eq(12)

      owner.exec("DELETE FROM sugar_teams WHERE id = $1", team.id)
      stale = stored.update(seats: 20)
      stale.saved?.should be_false
      stale.errors.should eq({"_base" => ["Record no longer exists"]})
      SugarSpec::Team.query.count.should eq(0)

      kept = SugarSpec::Team.create!(name: "Kept")
      doomed = SugarSpec::Team.create!(name: "Doomed")
      doomed.delete.should be_true
      doomed.delete.should be_false
      deletion = SugarORM::Repo.delete(SugarSpec::Team::UpdateChangeset.new(doomed))
      deletion.saved?.should be_false
      deletion.errors.should eq({"_base" => ["Record no longer exists"]})
      SugarSpec::Team.query.to_a.map(&.id).should eq([kept.id])
    end
  end

  it "uses CreateChangeset for create, maps its unique_constraint, and honours explicit handles" do
    SugarSpec.with_tables(owner_url, runtime_url) do |_owner, runtime|
      team = SugarSpec::Team.create!(runtime, name: "Acme Corp")
      user = SugarSpec::User.create!(runtime, email: "founder@caramel.dev", team_id: team.id)
      user.email.should eq("founder@caramel.dev")
      invalid = SugarSpec::User.create(email: "no-at-sign", team_id: team.id)
      invalid.errors.should eq({"email" => ["has invalid format"]})
      duplicate = SugarSpec::User.create(email: "founder@caramel.dev", team_id: team.id)
      duplicate.errors.should eq({"email" => ["is already registered"]})
      SugarSpec::Team::Query.where(name: "Acme Corp").first!(runtime).id.should eq(team.id)
      SugarSpec::User::Query.where(team_id: team.id).count(runtime).should eq(1)
      runtime.using_connection do |connection|
        users = SugarSpec::User::Query.where(team_id: team.id).to_a(connection)
        users.map(&.id).should eq([user.id])
      end
    end
  end

  it "preloads has_many, belongs_to and has_one with one query per association" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      acme = SugarSpec::Team.create!(name: "Acme")
      beta = SugarSpec::Team.create!(name: "Beta")
      solo = SugarSpec::Team.create!(name: "Solo")
      SugarSpec::User.create!(email: "ann@acme.dev", team_id: acme.id)
      bob = SugarSpec::User.create!(email: "bob@acme.dev", team_id: acme.id)
      cy = SugarSpec::User.create!(email: "cy@beta.dev", team_id: beta.id)
      ownership = SugarSpec::Team::DefaultChangeset.new(acme, owner_id: bob.id)
      SugarORM::Repo.update(ownership)
      profile = "INSERT INTO sugar_profiles (bio, team_id) VALUES ($1, $2)"
      SugarORM.sql_exec(profile, "Acme bio", acme.id)

      loaded = [] of SugarORM::Loaded(SugarSpec::Team, SugarSpec::Preloads)
      SugarSpec.statements do
        query = SugarSpec::Team.query.order_by(:name)
        loaded = query.preload(:users).preload(:owner).preload(:profile).to_a
      end.should eq(4)
      loaded.map(&.name).should eq(["Acme", "Beta", "Solo"])
      emails = [["ann@acme.dev", "bob@acme.dev"], ["cy@beta.dev"], [] of String]
      loaded.map(&.users.map(&.email)).should eq(emails)
      loaded.map(&.owner.try(&.email)).should eq(["bob@acme.dev", nil, nil])
      loaded.map(&.profile.try(&.bio)).should eq(["Acme bio", nil, nil])
      loaded.first.record.should eq(SugarSpec::Team.query.find!(acme.id))

      teams = [] of SugarSpec::Team
      SugarSpec.statements do
        users = SugarSpec::User.query.order_by(:email).preload(:team)
        users.each { |user| teams << user.team }
      end.should eq(2)
      teams.map(&.name).should eq(["Acme", "Acme", "Beta"])

      found = SugarSpec::Team.query.preload(:users).find!(beta.id)
      found.users.map(&.id).should eq([cy.id])
      SugarSpec::Team.query.preload(:users).find(solo.id + 1000).should be_nil
    end
  end

  it "filters with scopes, Array, Range and nil conditions, and orders results" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      small = SugarSpec::Team.create!(name: "Small", seats: 2)
      medium = SugarSpec::Team.create!(name: "Medium", seats: 5, billing_email: "m@x.dev")
      large = SugarSpec::Team.create!(name: "Large", seats: 9)
      archived = SugarSpec::Team.create!(name: "Archived", seats: 20, archived: true)

      teams = SugarSpec::Team.query
      larger = teams.active.larger_than(3).order_by(:seats, :desc)
      active = SugarSpec::Team::Query.active.order_by(:name)
      names(larger).should eq(["Large", "Medium"])
      names(active).should eq(["Large", "Medium", "Small"])
      ids = teams.where(id: [small.id, large.id]).order_by(:id).to_a.map(&.id)
      ids.should eq([small.id, large.id])
      teams.where(id: [] of Int64).to_a.should be_empty
      names(teams.where(seats: 2..5).order_by(:seats)).should eq(["Small", "Medium"])
      names(teams.where(seats: 2...5)).should eq(["Small"])
      names(teams.where(seats: 9..).order_by(:seats)).should eq(["Large", "Archived"])
      teams.where(billing_email: nil).count.should eq(3)
      teams.where(billing_email: "m@x.dev").first!.id.should eq(medium.id)
      teams.where(created_at: Time.utc(2000, 1, 1)..).count.should eq(4)

      teams.first.try(&.id).should eq(small.id)
      teams.order_by(:seats, :desc).first.try(&.id).should eq(archived.id)
      names(teams.order_by(:seats).limit(2).offset(1)).should eq(["Medium", "Large"])
      teams.order_by(:seats).limit(2).count.should eq(2)
      teams.where(name: "Nobody").exists?.should be_false
      teams.active.exists?.should be_true
      expect_raises(SugarORM::NotFound) { teams.where(name: "Nobody").first! }
      expect_raises(SugarORM::NotFound) { teams.find!(archived.id + 1000) }
      teams.active.find(archived.id).should be_nil

      teams.where(archived: true).delete_all.should eq(1)
      teams.order_by(:seats, :desc).limit(1).delete_all.should eq(1)
      names(teams.order_by(:seats)).should eq(["Small", "Medium"])
    end
  end

  it "nests transactions with savepoints and binds a connection to the fiber" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner, runtime|
      SugarORM::Repo.transaction do
        SugarSpec::Team.create!(name: "Outer")
        SugarORM::Repo.transaction do
          SugarSpec::Team.create!(name: "Inner")
          SugarORM::Repo.rollback
        end
        SugarORM::Repo.transaction { SugarSpec::Team.create!(name: "Kept inner") }
        owner.query_one("SELECT count(*) FROM sugar_teams", as: Int64).should eq(0)
      end
      SugarSpec::Team.query.order_by(:name).to_a.map(&.name).should eq(["Kept inner", "Outer"])

      expect_raises(Exception, "boom") do
        SugarORM::Repo.transaction do
          SugarSpec::Team.create!(name: "Doomed")
          raise "boom"
        end
      end
      SugarSpec::Team.query.where(name: "Doomed").exists?.should be_false

      SugarORM::Repo.transaction do
        taken = SugarSpec::Team.create(name: "Outer")
        taken.errors.should eq({"name" => ["has already been taken"]})
        SugarSpec::Team.create!(name: "After a mapped violation")
      end
      SugarSpec::Team.query.where(name: "After a mapped violation").exists?.should be_true

      runtime.using_connection do |connection|
        connection.transaction do |transaction|
          SugarORM::Repo.bind(connection) do
            SugarSpec::Team.create!(name: "Uncommitted")
            SugarSpec::Team.query.where(name: "Uncommitted").count.should eq(1)
            count = "SELECT count(*) AS total FROM sugar_teams WHERE name = $1"
            totals = SugarORM.sql(count, "Uncommitted", as: {total: Int64})
            totals.should eq([{total: 1_i64}])
            SugarORM::Repo.connection(&.same?(connection)).should be_true
          end
          SugarORM::Repo.bind(transaction) do
            SugarORM::Repo.transaction do
              SugarSpec::Team.create!(name: "Savepoint")
              SugarORM::Repo.rollback
            end
            SugarSpec::Team.query.where(name: "Savepoint").exists?.should be_false
          end
          uncommitted = "SELECT count(*) FROM sugar_teams WHERE name = 'Uncommitted'"
          owner.query_one(uncommitted, as: Int64).should eq(0)
          transaction.rollback
        end
      end
      SugarSpec::Team.query.where(name: "Uncommitted").exists?.should be_false
    end
  end

  it "returns the connections it checks out to the pool, and never a bound one" do
    SugarSpec.with_tables(owner_url, runtime_url) do |_, runtime|
      checked_out = -> { runtime.pool.stats.open_connections - runtime.pool.stats.idle_connections }
      SugarORM::Repo.exec("SELECT 1")
      SugarSpec::Team.create!(name: "Pooled")
      SugarSpec::Team.query.count(runtime).should eq(1)
      checked_out.call.should eq(0)

      held = runtime.checkout
      begin
        SugarORM::Repo.bind(held) { SugarSpec::Team.create!(name: "Bound") }
        SugarSpec::Team.query.count(held).should eq(2)
        checked_out.call.should eq(1)
      ensure
        held.release
      end
      checked_out.call.should eq(0)
    end
  end

  it "reads typed rows from CTEs, window functions and RETURNING, and checks the column shape" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      acme = SugarSpec::Team.create!(name: "Acme")
      beta = SugarSpec::Team.create!(name: "Beta")
      members = {"ann@acme.dev" => acme, "bob@acme.dev" => acme, "cy@beta.dev" => beta}
      members.each do |email, team|
        SugarSpec::User.create!(email: email, team_id: team.id)
      end

      totals = SugarORM.sql(<<-SQL, as: {team_id: Int64, total: Int64})
        WITH counts AS (SELECT team_id, count(*) AS total FROM sugar_users GROUP BY team_id)
        SELECT team_id, total FROM counts ORDER BY team_id
        SQL
      totals.should eq([{team_id: acme.id, total: 2_i64}, {team_id: beta.id, total: 1_i64}])

      rank = "SELECT email, " \
             "rank() OVER (PARTITION BY team_id ORDER BY email DESC) AS position " \
             "FROM sugar_users ORDER BY email"
      ranked = SugarORM.sql(rank, as: {email: String, position: Int64})
      ranked.should eq([
        {email: "ann@acme.dev", position: 2_i64},
        {email: "bob@acme.dev", position: 1_i64},
        {email: "cy@beta.dev", position: 1_i64},
      ])

      grow = "UPDATE sugar_teams SET seats = seats + $1 WHERE name = $2 " \
             "RETURNING id, seats"
      returned = SugarORM.sql(grow, 4, "Acme", as: {id: Int64, seats: Int32})
      returned.should eq([{id: acme.id, seats: 9}])
      archive = "UPDATE sugar_teams SET archived = true WHERE seats < $1"
      SugarORM.sql_exec(archive, 9).should eq(1)

      shape = {id: Int64, name: String}
      error = expect_raises(SugarORM::ShapeError) do
        SugarORM.sql("SELECT id, name AS title FROM sugar_teams", as: shape)
      end
      mismatch = "expected columns (id, name) but the query returned (id, title)"
      error.message.not_nil!.should contain(mismatch)
      expect_raises(SugarORM::ShapeError) do
        SugarORM.sql("SELECT id FROM sugar_teams", as: shape)
      end
    end
  end

  it "stores a type through a codec without a float round trip, in numeric and jsonb columns" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      exact = "12345678901234567890.1234567890"
      history = [{"price" => "98765432109876543210.0123456789"}]
      snapshot = SugarSpec::Snapshot.new("first", history)
      quote = SugarSpec::Quote.create!(
        rate: SugarSpec::Rate.new(exact), snapshot: snapshot
      )
      quote.rate.text.should eq(exact)
      quote.fee.should be_nil
      quote.snapshot.should eq(snapshot)

      found = SugarSpec::Quote.query.find!(quote.id)
      found.rate.should eq(SugarSpec::Rate.new(exact))
      found.fee.should be_nil
      found.snapshot.history.should eq(history)

      matches = SugarSpec::Quote.query.where(rate: SugarSpec::Rate.new(exact)).to_a
      matches.map(&.id).should eq([quote.id])
      SugarSpec::Quote.query.where(fee: nil).to_a.size.should eq(1)
      SugarSpec::Quote.query.where(fee: SugarSpec::Rate.new("1.0")).to_a.should be_empty

      same = found.update(rate: SugarSpec::Rate.new(exact))
      same.saved?.should be_true
      same.changes.should be_empty

      changed = found.update!(fee: SugarSpec::Rate.new("0.0000000001"))
      changed.fee.should eq(SugarSpec::Rate.new("0.0000000001"))
      changed.update!(fee: nil).fee.should be_nil

      rows = SugarORM.sql(
        "SELECT rate::text AS rate FROM sugar_quotes", as: {rate: String}
      )
      rows.should eq([{rate: exact}])
    end
  end

  it "maps a range check's violation to its field, and an expression check's to on:" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      # reserved: -1 keeps `reserved <= stock`, so only the range check fails.
      below = SugarSpec::Shelf.create(stock: -1, reserved: -1)
      below.saved?.should be_false
      below.errors.should eq({"stock" => ["must be at least 0"]})
      SugarSpec::Shelf.create(stock: 11).errors.should eq({"stock" => ["must be at most 10"]})
      over = SugarSpec::Shelf.create(stock: 2, reserved: 5)
      over.errors.should eq({"reserved" => ["exceeds stock"]})
      SugarSpec::Shelf.query.count.should eq(0)

      SugarORM::Repo.transaction do
        SugarSpec::Shelf.create(stock: -1, reserved: -1).saved?.should be_false
        SugarSpec::Shelf.create!(stock: 3, reserved: 1).stock.should eq(3)
      end
      SugarSpec::Shelf.query.count.should eq(1)
    end
  end

  it "raises CheckViolation for a check no changeset maps, naming its constraint" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      below = SugarSpec::Shelf::DefaultChangeset.new(stock: -1, reserved: -1)
      SugarORM::Repo.insert(below).errors.should eq({"stock" => ["must be at least 0"]})

      unmapped = SugarSpec::Shelf::DefaultChangeset.new(stock: 1, reserved: 2)
      error = expect_raises(SugarORM::CheckViolation) { SugarORM::Repo.insert(unmapped) }
      error.constraint.should eq("check_sugar_shelves_reserved_within_stock")
      error.table.should eq("sugar_shelves")

      raw = "INSERT INTO sugar_shelves (stock, reserved) VALUES (-1, -1)"
      error = expect_raises(SugarORM::CheckViolation) { SugarORM.sql_exec(raw) }
      error.constraint.should eq("check_sugar_shelves_stock")
    end
  end

  it "locks a row with one FOR UPDATE statement inside a transaction" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      team = SugarSpec::Team.create!(name: "Acme")
      SugarORM::Repo.transaction do
        found = [] of SugarSpec::Team
        delta = SugarSpec.statements { found << SugarSpec::Team.query.lock.find!(team.id) }
        delta.should eq(1)
        found.first.name.should eq("Acme")
        SugarSpec::Team.query.where(id: team.id).lock.first!.id.should eq(team.id)
        SugarSpec::Team.query.order_by(:id).lock.to_a.map(&.id).should eq([team.id])
      end
    end
  end

  it "refuses to lock outside a transaction and to count through a lock" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      team = SugarSpec::Team.create!(name: "Acme")
      statements = SugarSpec.statements do
        expect_raises(SugarORM::Error, /no transaction is open/) do
          SugarSpec::Team.query.lock.find!(team.id)
        end
      end
      statements.should eq(0)
      expect_raises(ArgumentError, /count does not lock rows/) do
        SugarSpec::Team.query.lock.count
      end
    end
  end

  it "makes a competing lock wait, then reads what the first transaction committed" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      team = SugarSpec::Team.create!(name: "Acme")
      seen = [] of Int32
      first = -> { SugarSpec::Team.query.lock.find!(team.id).update!(seats: 9) }
      second = -> { seen << SugarSpec::Team.query.lock.find!(team.id).seats }
      SugarSpec.contend(owner, first, second)
      seen.should eq([9])
    end
  end

  it "makes a competing lock wait, then reads the original row after a rollback" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      team = SugarSpec::Team.create!(name: "Acme")
      seen = [] of Int32
      first = -> { SugarSpec::Team.query.lock.find!(team.id).update!(seats: 9) }
      second = -> { seen << SugarSpec::Team.query.lock.find!(team.id).seats }
      SugarSpec.contend(owner, first, second, rollback: true)
      seen.should eq([5])
    end
  end

  it "rejects an update of a record that changed since it was loaded" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      stored = SugarSpec::Sale.create!(tea_id: 1_i64, sold: 1)
      stored.lock_version.should eq(0)
      first = SugarSpec::Sale::Count.new(stored, sold: 2)
      second = SugarSpec::Sale::Count.new(stored, sold: 3)
      SugarORM::Repo.update(first)
      first.saved?.should be_true
      first.record.lock_version.should eq(1)

      SugarORM::Repo.update(second)
      second.saved?.should be_false
      second.stale?.should be_true
      second.errors.should eq({"_base" => ["Record changed since you loaded it"]})
      SugarSpec::Sale.query.find!(stored.id).sold.should eq(2)
    end
  end

  it "checks the version a changeset is given, without a statement when it is old" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      stored = SugarSpec::Sale.create!(tea_id: 1_i64, sold: 1)
      current = SugarORM::Repo.update(SugarSpec::Sale::Count.new(stored, sold: 2)).record
      current.lock_version.should eq(1)

      old = SugarSpec::Sale::Count.new(current, sold: 9, lock_version: 0)
      delta = SugarSpec.statements { SugarORM::Repo.update(old) }
      delta.should eq(0)
      old.stale?.should be_true
      old.errors.should eq({"_base" => ["Record changed since you loaded it"]})

      fresh = SugarSpec::Sale::Count.new(current, sold: 9, lock_version: 1)
      SugarORM::Repo.update(fresh).saved?.should be_true
      fresh.record.lock_version.should eq(2)
      SugarSpec::Sale.query.find!(stored.id).sold.should eq(9)
    end
  end

  it "reports a deleted record as gone, not stale, and bumps updated_at on success" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      stored = SugarSpec::Sale.create!(tea_id: 1_i64, sold: 1)
      owner.exec("UPDATE sugar_sales SET updated_at = '2000-01-01' WHERE id = $1", stored.id)
      bumped = SugarORM::Repo.update(SugarSpec::Sale::Count.new(stored, sold: 2))
      bumped.record.updated_at.should be > Time.utc(2001, 1, 1)

      owner.exec("DELETE FROM sugar_sales WHERE id = $1", stored.id)
      gone = SugarORM::Repo.update(SugarSpec::Sale::Count.new(bumped.record, sold: 3))
      gone.saved?.should be_false
      gone.stale?.should be_false
      gone.errors.should eq({"_base" => ["Record no longer exists"]})
    end
  end

  it "upserts one row per key: the second call updates what update: names" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      first = SugarORM::Repo.insert(SugarSpec::Sale::Record.new(tea_id: 7_i64, sold: 1))
      second = SugarORM::Repo.insert(SugarSpec::Sale::Record.new(tea_id: 7_i64, sold: 4))
      first.saved?.should be_true
      second.saved?.should be_true
      second.record.id.should eq(first.record.id)
      second.record.sold.should eq(4)
      second.record.lock_version.should eq(1)
      SugarSpec::Sale.query.where(tea_id: 7_i64).count.should eq(1)
    end
  end

  it "returns the existing row when an upsert names no update fields" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      first = SugarORM::Repo.insert(SugarSpec::Sale::Seed.new(tea_id: 7_i64, sold: 1))
      second = nil
      delta = SugarSpec.statements do
        second = SugarORM::Repo.insert(SugarSpec::Sale::Seed.new(tea_id: 7_i64, sold: 8))
      end
      delta.should eq(2)
      stored = second.not_nil!
      stored.saved?.should be_true
      stored.record.id.should eq(first.record.id)
      stored.record.sold.should eq(1)
      stored.record.lock_version.should eq(0)
      SugarSpec::Sale.query.count.should eq(1)
    end
  end

  it "requires an upsert's key once, and writes nothing without it" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      keyless = SugarSpec::Sale::Seed.new(sold: 1)
      keyless.errors.should eq({"tea_id" => ["is required"]})
      delta = SugarSpec.statements { SugarORM::Repo.insert(keyless).saved?.should be_false }
      delta.should eq(0)
      SugarSpec::Sale.query.count.should eq(0)
    end
  end

  it "leaves one row when two transactions upsert one key and DO NOTHING" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      results = [] of SugarSpec::Sale::Seed
      first = -> { results << SugarORM::Repo.insert(upsert_seed(1)) }
      second = -> { results << SugarORM::Repo.insert(upsert_seed(2)) }
      SugarSpec.contend(owner, first, second)
      results.map(&.saved?).should eq([true, true])
      results.map(&.record.id).uniq!.size.should eq(1)
      results.map(&.record.sold).should eq([1, 1])
      SugarSpec::Sale.query.where(tea_id: 9_i64).count.should eq(1)
    end
  end

  it "leaves one row when two transactions upsert one key and DO UPDATE" do
    SugarSpec.with_tables(owner_url, runtime_url) do |owner|
      results = [] of SugarSpec::Sale::Record
      first = -> { results << SugarORM::Repo.insert(upsert_record(1)) }
      second = -> { results << SugarORM::Repo.insert(upsert_record(2)) }
      SugarSpec.contend(owner, first, second)
      results.map(&.saved?).should eq([true, true])
      results.map(&.record.id).uniq!.size.should eq(1)
      results.last.record.sold.should eq(2)
      results.last.record.lock_version.should eq(1)
      SugarSpec::Sale.query.where(tea_id: 9_i64).count.should eq(1)
      SugarSpec::Sale.query.find!(results.first.record.id).sold.should eq(2)
    end
  end
end
