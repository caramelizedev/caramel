require "spec"
require "../../src/caramel/database"
require "../../src/sugar_orm"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
owner_url = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"
runtime_url = ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"]? || raise "Run scripts/check integration; no runtime role URL provided"

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
      owner.exec("CREATE TABLE sugar_profiles (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, bio text NOT NULL, team_id bigint NOT NULL REFERENCES sugar_teams (id))")
      owner.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON sugar_teams, sugar_users, sugar_profiles TO caramel_model_spec")
      owner.exec("GRANT USAGE, SELECT ON SEQUENCE sugar_teams_id_seq, sugar_users_id_seq, sugar_profiles_id_seq TO caramel_model_spec")
      yield owner, runtime
    ensure
      owner.exec("DROP TABLE IF EXISTS sugar_profiles, sugar_users, sugar_teams")
      runtime.close
      owner.close
    end
  end

  def self.statements(&) : Int64
    before = SugarORM::Repo.statements_executed
    yield
    SugarORM::Repo.statements_executed - before
  end
end

describe "SugarORM with PostgreSQL" do
  it "runs as a restricted role that can write rows but cannot create tables" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      SugarORM.sql("SELECT current_user::text AS name", as: {name: String}).should eq([{name: "caramel_model_spec"}])
      expect_raises(PQ::PQError, /permission denied/) { SugarORM.sql_exec("CREATE TABLE sugar_forbidden (id integer)") }
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
      expect_raises(SugarORM::Invalid, "SugarSpec::Team::DefaultChangeset is invalid: name has already been taken") { SugarSpec::Team.create!(name: "Acme") }

      SugarSpec.statements { SugarSpec::Team.create(seats: 3).errors.should eq({"name" => ["is required"]}) }.should eq(0)

      owner.exec("UPDATE sugar_teams SET name = 'Acme Corp', updated_at = '2000-01-01' WHERE id = $1", team.id)
      updated = SugarSpec.statements { team.update!(seats: 10, billing_email: "billing@acme.com").seats.should eq(10) }
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
      SugarSpec::User.create(email: "no-at-sign", team_id: team.id).errors.should eq({"email" => ["has invalid format"]})
      SugarSpec::User.create(email: "founder@caramel.dev", team_id: team.id).errors.should eq({"email" => ["is already registered"]})
      SugarSpec::Team::Query.where(name: "Acme Corp").first!(runtime).id.should eq(team.id)
      SugarSpec::User::Query.where(team_id: team.id).count(runtime).should eq(1)
      runtime.using_connection do |connection|
        SugarSpec::User::Query.where(team_id: team.id).to_a(connection).map(&.id).should eq([user.id])
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
      SugarSpec::Team::DefaultChangeset.new(acme, owner_id: bob.id).tap { |changeset| SugarORM::Repo.update(changeset) }
      SugarORM.sql_exec("INSERT INTO sugar_profiles (bio, team_id) VALUES ($1, $2)", "Acme bio", acme.id)

      loaded = [] of SugarORM::Loaded(SugarSpec::Team, NamedTuple(users: Array(SugarSpec::User), owner: SugarSpec::User?, profile: SugarSpec::Profile?))
      SugarSpec.statements do
        loaded = SugarSpec::Team.query.order_by(:name).preload(:users).preload(:owner).preload(:profile).to_a
      end.should eq(4)
      loaded.map(&.name).should eq(["Acme", "Beta", "Solo"])
      loaded.map(&.users.map(&.email)).should eq([["ann@acme.dev", "bob@acme.dev"], ["cy@beta.dev"], [] of String])
      loaded.map(&.owner.try(&.email)).should eq(["bob@acme.dev", nil, nil])
      loaded.map(&.profile.try(&.bio)).should eq(["Acme bio", nil, nil])
      loaded.first.record.should eq(SugarSpec::Team.query.find!(acme.id))

      teams = [] of SugarSpec::Team
      SugarSpec.statements do
        SugarSpec::User.query.order_by(:email).preload(:team).each { |user| teams << user.team }
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

      SugarSpec::Team.query.active.larger_than(3).order_by(:seats, :desc).to_a.map(&.name).should eq(["Large", "Medium"])
      SugarSpec::Team::Query.active.order_by(:name).to_a.map(&.name).should eq(["Large", "Medium", "Small"])
      SugarSpec::Team.query.where(id: [small.id, large.id]).order_by(:id).to_a.map(&.id).should eq([small.id, large.id])
      SugarSpec::Team.query.where(id: [] of Int64).to_a.should be_empty
      SugarSpec::Team.query.where(seats: 2..5).order_by(:seats).to_a.map(&.name).should eq(["Small", "Medium"])
      SugarSpec::Team.query.where(seats: 2...5).to_a.map(&.name).should eq(["Small"])
      SugarSpec::Team.query.where(seats: 9..).order_by(:seats).to_a.map(&.name).should eq(["Large", "Archived"])
      SugarSpec::Team.query.where(billing_email: nil).count.should eq(3)
      SugarSpec::Team.query.where(billing_email: "m@x.dev").first!.id.should eq(medium.id)
      SugarSpec::Team.query.where(created_at: Time.utc(2000, 1, 1)..).count.should eq(4)

      SugarSpec::Team.query.first.try(&.id).should eq(small.id)
      SugarSpec::Team.query.order_by(:seats, :desc).first.try(&.id).should eq(archived.id)
      SugarSpec::Team.query.order_by(:seats).limit(2).offset(1).to_a.map(&.name).should eq(["Medium", "Large"])
      SugarSpec::Team.query.order_by(:seats).limit(2).count.should eq(2)
      SugarSpec::Team.query.where(name: "Nobody").exists?.should be_false
      SugarSpec::Team.query.active.exists?.should be_true
      expect_raises(SugarORM::NotFound) { SugarSpec::Team.query.where(name: "Nobody").first! }
      expect_raises(SugarORM::NotFound) { SugarSpec::Team.query.find!(archived.id + 1000) }
      SugarSpec::Team.query.active.find(archived.id).should be_nil

      SugarSpec::Team.query.where(archived: true).delete_all.should eq(1)
      SugarSpec::Team.query.order_by(:seats, :desc).limit(1).delete_all.should eq(1)
      SugarSpec::Team.query.order_by(:seats).to_a.map(&.name).should eq(["Small", "Medium"])
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
        SugarSpec::Team.create(name: "Outer").errors.should eq({"name" => ["has already been taken"]})
        SugarSpec::Team.create!(name: "After a mapped violation")
      end
      SugarSpec::Team.query.where(name: "After a mapped violation").exists?.should be_true

      runtime.using_connection do |connection|
        connection.transaction do |transaction|
          SugarORM::Repo.bind(connection) do
            SugarSpec::Team.create!(name: "Uncommitted")
            SugarSpec::Team.query.where(name: "Uncommitted").count.should eq(1)
            SugarORM.sql("SELECT count(*) AS total FROM sugar_teams WHERE name = $1", "Uncommitted", as: {total: Int64}).should eq([{total: 1_i64}])
            SugarORM::Repo.connection(&.same?(connection)).should be_true
          end
          SugarORM::Repo.bind(transaction) do
            SugarORM::Repo.transaction do
              SugarSpec::Team.create!(name: "Savepoint")
              SugarORM::Repo.rollback
            end
            SugarSpec::Team.query.where(name: "Savepoint").exists?.should be_false
          end
          owner.query_one("SELECT count(*) FROM sugar_teams WHERE name = 'Uncommitted'", as: Int64).should eq(0)
          transaction.rollback
        end
      end
      SugarSpec::Team.query.where(name: "Uncommitted").exists?.should be_false
    end
  end

  it "reads typed rows from CTEs, window functions and RETURNING, and checks the column shape" do
    SugarSpec.with_tables(owner_url, runtime_url) do
      acme = SugarSpec::Team.create!(name: "Acme")
      beta = SugarSpec::Team.create!(name: "Beta")
      {"ann@acme.dev" => acme, "bob@acme.dev" => acme, "cy@beta.dev" => beta}.each do |email, team|
        SugarSpec::User.create!(email: email, team_id: team.id)
      end

      totals = SugarORM.sql(<<-SQL, as: {team_id: Int64, total: Int64})
        WITH counts AS (SELECT team_id, count(*) AS total FROM sugar_users GROUP BY team_id)
        SELECT team_id, total FROM counts ORDER BY team_id
        SQL
      totals.should eq([{team_id: acme.id, total: 2_i64}, {team_id: beta.id, total: 1_i64}])

      ranked = SugarORM.sql("SELECT email, rank() OVER (PARTITION BY team_id ORDER BY email DESC) AS position FROM sugar_users ORDER BY email", as: {email: String, position: Int64})
      ranked.should eq([{email: "ann@acme.dev", position: 2_i64}, {email: "bob@acme.dev", position: 1_i64}, {email: "cy@beta.dev", position: 1_i64}])

      returned = SugarORM.sql("UPDATE sugar_teams SET seats = seats + $1 WHERE name = $2 RETURNING id, seats", 4, "Acme", as: {id: Int64, seats: Int32})
      returned.should eq([{id: acme.id, seats: 9}])
      SugarORM.sql_exec("UPDATE sugar_teams SET archived = true WHERE seats < $1", 9).should eq(1)

      error = expect_raises(SugarORM::ShapeError) { SugarORM.sql("SELECT id, name AS title FROM sugar_teams", as: {id: Int64, name: String}) }
      error.message.not_nil!.should contain("expected columns (id, name) but the query returned (id, title)")
      expect_raises(SugarORM::ShapeError) { SugarORM.sql("SELECT id FROM sugar_teams", as: {id: Int64, name: String}) }
    end
  end
end
