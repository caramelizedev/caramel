require "spec"
require "./support/unit_schemas"

private SELECT = %(SELECT "id", "name", "seats", "ratio", "archived", ) \
                 %("motto", "billing_email", "created_at", "updated_at", "owner_id" ) \
                 %(FROM "unit_teams")

describe SugarORM::Query do
  it "renders keyword conditions as bound predicates: value, nil, Array and Range" do
    query = SugarUnit::Team.query.where(
      name: "Acme",
      billing_email: nil,
      id: [1_i64, 2_i64],
      seats: 3..7,
    )
    expected = %(#{SELECT} WHERE "id" = ANY($1) AND "name" = $2 ) \
               %(AND "seats" BETWEEN $3 AND $4 AND "billing_email" IS NULL)
    query.to_sql.should eq(expected)
    query.binds.should eq([[1_i64, 2_i64], "Acme", 3, 7] of SugarORM::Value)
  end

  it "renders half-open and endless ranges" do
    teams = SugarUnit::Team.query
    half_open = %(WHERE "seats" >= $1 AND "seats" < $2)
    teams.where(seats: 3...7).to_sql.should end_with(half_open)
    teams.where(seats: 3..).to_sql.should end_with(%(WHERE "seats" >= $1))
    teams.where(seats: ..7).to_sql.should end_with(%(WHERE "seats" <= $1))
    teams.where(seats: ...7).to_sql.should end_with(%(WHERE "seats" < $1))
    at = Time.utc(2026, 1, 1)
    query = SugarUnit::Member.query.where(joined_at: at..)
    query.to_sql.should end_with(%(WHERE "joined_at" >= $1))
    query.binds.should eq([at] of SugarORM::Value)
  end

  it "numbers raw fragment binds after keyword binds and checks their count" do
    fragment = "seats > ? AND ratio < ?"
    query = SugarUnit::Team.query.where(name: "Acme").where(fragment, 3, 1.5)
    query.to_sql.should eq(%(#{SELECT} WHERE "name" = $1 AND (seats > $2 AND ratio < $3)))
    query.binds.should eq(["Acme", 3, 1.5] of SugarORM::Value)
    expect_raises(ArgumentError, /2 '\?' placeholders but 1 values/) do
      SugarUnit::Team.query.where("a = ? OR b = ?", 1)
    end
  end

  it "chains scopes, ordering, limit and offset into a new query each time" do
    base = SugarUnit::Team.query.active
    ordered = base.larger_than(3).order_by(:seats, :desc).order_by(:name)
    narrowed = ordered.limit(5).offset(10)
    expected = %(#{SELECT} WHERE "archived" = $1 AND (seats > $2) ) \
               %(ORDER BY "seats" DESC, "name" ASC LIMIT 5 OFFSET 10)
    narrowed.to_sql.should eq(expected)
    narrowed.binds.should eq([false, 3] of SugarORM::Value)
    base.to_sql.should eq(%(#{SELECT} WHERE "archived" = $1))
  end

  it "starts class-level queries from an empty query" do
    query_type = SugarUnit::Team::Query
    query = SugarUnit::Team.query
    query_type.where(name: "Acme").to_sql.should eq(query.where(name: "Acme").to_sql)
    query_type.active.larger_than(2).to_sql.should eq(query.active.larger_than(2).to_sql)
    expected = %(#{SELECT} ORDER BY "created_at" DESC)
    query_type.order_by(:created_at, :desc).to_sql.should eq(expected)
  end

  it "accumulates preloads in the query type without changing the SELECT" do
    acme = SugarUnit::Team.query.where(name: "Acme")
    query = acme.preload(:members).preload(:owner).preload(:charter)
    typeof(query).should eq(SugarUnit::Team::QueryOf(NamedTuple(
      members: SugarORM::HasMany(SugarUnit::Team, SugarUnit::Member),
      owner: SugarORM::BelongsTo(SugarUnit::Team, SugarUnit::Member, SugarUnit::Member?),
      charter: SugarORM::HasOne(SugarUnit::Team, SugarUnit::Charter))))
    query.to_sql.should eq(%(#{SELECT} WHERE "name" = $1))
    members = SugarUnit::Member.query.preload(:team)
    typeof(members).should eq(SugarUnit::Member::QueryOf(NamedTuple(
      team: SugarORM::BelongsTo(SugarUnit::Member, SugarUnit::Team, SugarUnit::Team))))
  end

  it "rejects negative limits and offsets and unknown directions" do
    expect_raises(ArgumentError) { SugarUnit::Team.query.limit(-1) }
    expect_raises(ArgumentError) { SugarUnit::Team.query.offset(-1) }
    expect_raises(ArgumentError, /must be :asc or :desc, not :sideways/) do
      SugarUnit::Team.query.order_by(:name, :sideways)
    end
  end
end
