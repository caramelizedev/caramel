require "spec"
require "../../src/caramel/database"
require "../../src/sugar_orm"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
owner_url = ENV["CARAMEL_OWNED_SPEC_URL"]? ||
            raise "Run scripts/check integration; no owned test database provided"
runtime_url = ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"]? ||
              raise "Run scripts/check integration; no runtime role URL provided"

module UuidKeysSpec
  # Declared before the team it belongs to, so its key type is resolved late.
  struct Member < SugarORM::Schema
    schema "uuid_members" do
      field id : UUID, primary: true
      field name : String
      belongs_to team : Team
      json :id, :name, :team_id
    end
  end

  struct Team < SugarORM::Schema
    schema "uuid_teams" do
      field id : UUID, primary: true
      field name : String
      has_many members : Member
    end
  end

  class Team::Keyed < SugarORM::Changeset(Team)
    param id : UUID
    param name : String
  end

  TABLES = "uuid_members, uuid_teams"

  def self.with_tables(owner_url : String, runtime_url : String, &)
    owner = Caramel::Database.open(owner_url)
    runtime = Caramel::Database.open(runtime_url)
    SugarORM::Repo.database = runtime
    begin
      owner.exec(SugarORM::DDL.create_table(Team.__sugar_table))
      owner.exec(SugarORM::DDL.create_table(Member.__sugar_table))
      owner.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON #{TABLES} TO caramel_model_spec")
      yield
    ensure
      owner.exec("DROP TABLE IF EXISTS #{TABLES}")
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

private alias Team = UuidKeysSpec::Team
private alias Member = UuidKeysSpec::Member

describe "UUID primary keys on PostgreSQL" do
  it "mints a UUIDv7 when an insert changeset is built and stores the row under it" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      changeset = Team::DefaultChangeset.new(name: "Reds")
      minted = changeset.id
      minted.version.should eq(UUID::Version::V7)
      SugarORM::Repo.insert(changeset).saved?.should be_true
      changeset.record.id.should eq(minted)
      Team.query.find(minted).try(&.name).should eq("Reds")
    end
  end

  it "preloads both ways in one query each, filters by ids, and writes ids as JSON text" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      team = Team.create!(name: "Reds")
      ada = Member.create!(name: "Ada", team_id: team.id)
      bo = Member.create!(name: "Bo", team_id: team.id)
      members = [] of SugarORM::Loaded(Member, NamedTuple(team: Team))
      UuidKeysSpec.statements { members = Member.query.preload(:team).to_a }.should eq(2)
      members.map(&.team.name).should eq(["Reds", "Reds"])
      teams = [] of SugarORM::Loaded(Team, NamedTuple(members: Array(Member)))
      UuidKeysSpec.statements { teams = Team.query.preload(:members).to_a }.should eq(2)
      teams.first.members.map(&.name).sort!.should eq(["Ada", "Bo"])
      Member.query.where(id: [ada.id, bo.id]).count.should eq(2)
      Member.query.where(id: ada.id..bo.id).count.should eq(2)
      ada.to_json.should eq(%({"id":"#{ada.id}","name":"Ada","team_id":"#{team.id}"}))
    end
  end

  it "pages a UUID-keyed table in the order its ids were minted" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      names = %w[first second third]
      names.each { |name| Team.create!(name: name) }
      page = Team.query.page(2)
      page.records.map(&.name).should eq(names.first(2))
      rest = Team.query.page(2, after: page.after)
      rest.records.map(&.name).should eq(["third"])
      rest.after.should be_nil
    end
  end

  it "stores an id the changeset is given, and maps a taken one to its field" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      given = SugarORM.uuid7
      SugarORM::Repo.insert(Team::Keyed.new(id: given, name: "Reds")).record.id.should eq(given)
      again = SugarORM::Repo.insert(Team::Keyed.new(id: given, name: "Blues"))
      again.saved?.should be_false
      again.errors.should eq({"id" => ["has already been taken"]})
    end
  end

  it "refuses an update that would change a stored record's id" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      team = Team.create!(name: "Reds")
      moved = SugarORM::Repo.update(Team::Keyed.new(team, id: SugarORM.uuid7))
      moved.saved?.should be_false
      moved.errors.should eq({"id" => ["cannot be changed"]})
      Team.query.find!(team.id).name.should eq("Reds")
    end
  end

  it "lets PostgreSQL mint a UUIDv7 for a row written without an id" do
    UuidKeysSpec.with_tables(owner_url, runtime_url) do
      SugarORM.sql_exec("INSERT INTO uuid_teams (name) VALUES ($1)", "Reds")
      versions = SugarORM.sql("SELECT uuid_extract_version(id) AS version FROM uuid_teams",
        as: {version: Int16})
      versions.should eq([{version: 7_i16}])
    end
  end
end
