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

  it "types codec columns by the codec's SQL type and gives them no default" do
    SugarUnit::Quote.__sugar_table.columns.should eq([
      Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
      Catalog::Column.new("price", "numeric(20,8)", false, nil),
      Catalog::Column.new("fee", "numeric(20,8)", true, nil),
      Catalog::Column.new("snapshot", "jsonb", false, nil),
      Catalog::Column.new("extra", "jsonb", true, nil),
    ])
  end

  it "reads codec columns as text and encodes values through the codec" do
    SugarUnit::Quote.__sugar_select_list.should eq(
      %("id", "price"::text, "fee"::text, "snapshot"::text, "extra"::text)
    )
    quote = SugarUnit::Quote.new(
      id: 1_i64, price: "1.50", snapshot: SugarUnit::Snapshot.new(3)
    )
    quote.__sugar_get("price").should eq("1.50")
    quote.__sugar_get("fee").should be_nil
    quote.__sugar_get("snapshot").should eq(%({"total":3}))
  end

  it "accepts only numeric, numeric(P,S), jsonb and text codec column types" do
    ["numeric", "numeric(20,8)", "numeric(5,5)", "jsonb", "text"].each do |type|
      SugarORM::Codec.checked_sql_type(type).should eq(type)
    end
    ["decimal", "numeric(3,4)", "json", "numeric(1001,2)"].each do |type|
      expect_raises(ArgumentError, "must be numeric, numeric(P,S), jsonb or text") do
        SugarORM::Codec.checked_sql_type(type)
      end
    end
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
