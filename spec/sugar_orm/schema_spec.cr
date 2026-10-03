require "spec"
require "json"
require "./support/unit_schemas"

private alias Catalog = SugarORM::Catalog

describe SugarORM::Schema do
  it "describes its table for the migration engine " \
     "with PostgreSQL types, literal defaults and intent" do
    table = SugarUnit::Team.__sugar_table
    table.name.should eq("unit_teams")
    table.columns.should eq([
      Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
      Catalog::Column.new("name", "text", false, nil),
      Catalog::Column.new("seats", "integer", false, "5"),
      Catalog::Column.new("ratio", "double precision", false, "2.5"),
      Catalog::Column.new("archived", "boolean", false, "false"),
      Catalog::Column.new("motto", "text", false, "'it''s on'"),
      Catalog::Column.new("billing_email", "text", true, nil, renamed_from: "email"),
      Catalog::Column.new("created_at", "timestamp with time zone", false, "CURRENT_TIMESTAMP"),
      Catalog::Column.new("updated_at", "timestamp with time zone", false, "CURRENT_TIMESTAMP"),
      Catalog::Column.new("owner_id", "bigint", true, nil),
    ])
    table.indexes.should eq([
      Catalog::Index.new("index_unit_teams_on_owner_id", ["owner_id"]),
      Catalog::Index.new("index_unit_teams_on_name", ["name"], unique: true),
      Catalog::Index.new("index_unit_teams_on_seats_and_archived", ["seats", "archived"]),
    ])
    owner = Catalog::ForeignKey.new("fk_unit_teams_owner_id", ["owner_id"], "unit_members")
    table.foreign_keys.should eq([owner])
    table.drops.should eq(["legacy_code"])
  end

  it "makes a NOT NULL belongs_to column, foreign key and index" do
    column = Catalog::Column.new("team_id", "bigint", false, nil)
    foreign_key = Catalog::ForeignKey.new("fk_unit_members_team_id", ["team_id"], "unit_teams")
    index = Catalog::Index.new("index_unit_members_on_team_id", ["team_id"])
    table = SugarUnit::Member.__sugar_table
    table.columns.last.should eq(column)
    table.foreign_keys.should eq([foreign_key])
    table.indexes.should eq([index])
  end

  it "declares every concrete schema in the program, sorted by table name" do
    names = Catalog.declared.map(&.name)
    names.should eq(names.sort)
    names.should contain("unit_charters")
    names.should contain("unit_members")
    names.should contain("unit_teams")
    teams = Catalog.declared.find { |table| table.name == "unit_teams" }
    teams.should eq(SugarUnit::Team.__sugar_table)
  end

  it "is an immutable value: with returns a changed copy and leaves the original alone" do
    team = SugarUnit.team
    renamed = team.with(name: "Beta", billing_email: "b@example.com")
    renamed.name.should eq("Beta")
    renamed.billing_email.should eq("b@example.com")
    renamed.id.should eq(team.id)
    team.name.should eq("Acme")
    team.billing_email.should be_nil
    team.with(name: "Acme").should eq(team)
  end

  it "applies literal defaults and nil for nilable fields when built directly" do
    team = SugarUnit.team
    team.seats.should eq(5)
    team.ratio.should eq(2.5)
    team.archived.should be_false
    team.motto.should eq("it's on")
    team.owner_id.should be_nil
  end

  it "serializes declared columns in declaration order and never association sentinels" do
    json = SugarUnit.team(billing_email: "a@b.c").to_json
    columns = %w[
      id name seats ratio archived motto billing_email
      created_at updated_at owner_id
    ]
    JSON.parse(json).as_h.keys.should eq(columns)
    json.should contain(%("created_at":"2026-01-01T00:00:00Z"))
    json.should_not contain("members")
    json.should_not contain("charter")
  end
end
