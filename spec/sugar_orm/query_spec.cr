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

  it "renders nil on any nullable column as IS NULL and combines it with other conditions" do
    unbilled = SugarUnit::Team.query.where(billing_email: nil)
    unbilled.to_sql.should eq(%(#{SELECT} WHERE "billing_email" IS NULL))
    unbilled.binds.should be_empty
    named = SugarUnit::Team::Query.where(owner_id: nil).where(name: "Acme")
    named.to_sql.should end_with(%(WHERE "owner_id" IS NULL AND "name" = $1))
  end

  it "renders rest as the complement of a query's conditions" do
    teams = SugarUnit::Team.query
    teams.where(name: "Acme").rest.to_sql.should end_with(%(WHERE ("name" = $1) IS NOT TRUE))
    teams.where(seats: ..3).rest.to_sql.should end_with(%(WHERE ("seats" <= $1) IS NOT TRUE))
    teams.where(billing_email: nil).rest.to_sql
      .should end_with(%(WHERE ("billing_email" IS NULL) IS NOT TRUE))
    both = teams.where(archived: true, seats: 0).rest
    both.to_sql.should end_with(%(WHERE ("seats" = $1 AND "archived" = $2) IS NOT TRUE))
    both.binds.should eq([0, true] of SugarORM::Value)
    teams.where(name: "Acme").rest.where(seats: 1..).to_sql
      .should end_with(%(WHERE ("name" = $1) IS NOT TRUE AND "seats" >= $2))
    teams.rest.to_sql.should end_with("WHERE FALSE")
    expect_raises(ArgumentError, "rest takes a query without joins") do
      SugarUnit::Member.query.joins(:team).rest
    end
    expect_raises(ArgumentError, "rest takes a query without limit or offset") do
      teams.limit(5).rest
    end
  end

  it "takes a value narrowed from a nilable one" do
    email = ["billing@acme.test", nil].first
    query = SugarUnit::Team.query
    query = query.where(billing_email: email) if email
    query.to_sql.should end_with(%(WHERE "billing_email" = $1))
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

  it "renders a Range on a column whose codec is ORDERABLE, binding the encoded days" do
    first = SugarORM::Date.new(2026, 10, 1)
    last = SugarORM::Date.new(2026, 10, 31)
    deadlines = SugarUnit::Deadline.query
    closed = deadlines.where(due_on: first..last)
    closed.to_sql.should end_with(%(WHERE "due_on" BETWEEN $1 AND $2))
    closed.binds.should eq(["2026-10-01", "2026-10-31"] of SugarORM::Value)
    half_open = deadlines.where(due_on: first...last)
    half_open.to_sql.should end_with(%(WHERE "due_on" >= $1 AND "due_on" < $2))
    half_open.binds.should eq(["2026-10-01", "2026-10-31"] of SugarORM::Value)
    from = deadlines.where(due_on: first..)
    from.to_sql.should end_with(%(WHERE "due_on" >= $1))
    from.binds.should eq(["2026-10-01"] of SugarORM::Value)
    until_last = deadlines.where(due_on: ..last)
    until_last.to_sql.should end_with(%(WHERE "due_on" <= $1))
    deadlines.where(due_on: ...last).to_sql.should end_with(%(WHERE "due_on" < $1))
    nullable = deadlines.where(done_on: first..last, due_on: first)
    nullable.to_sql.should end_with(%(WHERE "due_on" = $1 AND "done_on" BETWEEN $2 AND $3))
    nullable.binds.should eq(["2026-10-01", "2026-10-01", "2026-10-31"] of SugarORM::Value)
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
      members: SugarORM::HasMany(SugarUnit::Team, SugarUnit::Member, Int64),
      owner: SugarORM::BelongsTo(SugarUnit::Team, SugarUnit::Member, SugarUnit::Member?, Int64),
      charter: SugarORM::HasOne(SugarUnit::Team, SugarUnit::Charter, Int64))))
    query.to_sql.should eq(%(#{SELECT} WHERE "name" = $1))
    members = SugarUnit::Member.query.preload(:team)
    typeof(members).should eq(SugarUnit::Member::QueryOf(NamedTuple(
      team: SugarORM::BelongsTo(SugarUnit::Member, SugarUnit::Team, SugarUnit::Team, Int64))))
  end

  it "adds FOR UPDATE last when locked, and leaves an unlocked query alone" do
    teams = SugarUnit::Team.query.where(seats: 3).limit(1)
    teams.to_sql.should eq(%(#{SELECT} WHERE "seats" = $1 LIMIT 1))
    teams.lock.to_sql.should eq(%(#{SELECT} WHERE "seats" = $1 LIMIT 1 FOR UPDATE))
    ordered = SugarUnit::Team.query.lock.order_by(:id).where(seats: 3)
    ordered.to_sql.should end_with(%(WHERE "seats" = $1 ORDER BY "id" ASC FOR UPDATE))
    SugarUnit::Team.query.lock.to_sql.should eq("#{SELECT} FOR UPDATE")
  end

  it "refuses to count, test or delete through a lock" do
    locked = SugarUnit::Team.query.lock
    expect_raises(ArgumentError, "count does not lock rows; remove .lock from this query") do
      locked.count
    end
    expect_raises(ArgumentError, "exists? does not lock rows") { locked.exists? }
    expect_raises(ArgumentError, "delete_all does not lock rows") { locked.delete_all }
  end

  it "narrows by a parent query whose binds follow the outer query's" do
    teams = SugarUnit::Team.query.where(archived: false).where(name: "Acme")
    members = SugarUnit::Member.query.where(email: "a@b.c").where(team: teams)
    parent = %(SELECT "id" FROM "unit_teams" WHERE "archived" = $2 AND "name" = $3)
    members.to_sql.should end_with(%(WHERE "email" = $1 AND "team_id" IN (#{parent})))
    members.binds.should eq(["a@b.c", false, "Acme"] of SugarORM::Value)

    left_out = SugarUnit::Member.query.where(team: not(teams))
    parent = %(SELECT "id" FROM "unit_teams" WHERE "archived" = $1 AND "name" = $2)
    left_out.to_sql.should end_with(%(WHERE NOT ("team_id" IN (#{parent}))))

    owners = SugarUnit::Member.query.where(email: "x")
    parent = %(SELECT "id" FROM "unit_members" WHERE "email" = $1)
    SugarUnit::Team.query.where(owner: not(owners)).to_sql
      .should end_with(%(WHERE ("owner_id" IN (#{parent})) IS NOT TRUE))
    SugarUnit::Team.query.where(owner: not(owners, unknown: :drop)).to_sql
      .should end_with(%(WHERE NOT ("owner_id" IN (#{parent}))))
  end

  it "renders each word of a keyword where" do
    teams = SugarUnit::Team.query
    teams.where(name: not("Acme")).to_sql.should end_with(%(WHERE "name" <> $1))
    teams.where(billing_email: not("a@b.c")).to_sql
      .should end_with(%(WHERE "billing_email" IS DISTINCT FROM $1))
    teams.where(billing_email: not("a@b.c", unknown: :drop)).to_sql
      .should end_with(%(WHERE "billing_email" <> $1))
    teams.where(billing_email: not(["a", "b"])).to_sql
      .should end_with(%(WHERE ("billing_email" = ANY($1)) IS NOT TRUE))
    teams.where(billing_email: not(nil)).to_sql
      .should end_with(%(WHERE "billing_email" IS NOT NULL))
    teams.where(seats: over(3)).to_sql.should end_with(%(WHERE "seats" > $1))
    teams.where(seats: under(3)).to_sql.should end_with(%(WHERE "seats" < $1))
    teams.where(seats: not(1..3)).to_sql.should end_with(%(WHERE NOT ("seats" BETWEEN $1 AND $2)))

    starts = teams.where(name: starting_with("Ac"))
    starts.to_sql.should end_with(%(WHERE "name" LIKE $1))
    starts.binds.should eq(["Ac%"] of SugarORM::Value)
    within = teams.where(name: containing("50%", any_case: true))
    within.to_sql.should end_with(%(WHERE "name" ILIKE $1))
    within.binds.should eq(["%50\\%%"] of SugarORM::Value)
    ends = teams.where(name: not(ending_with("me")))
    ends.to_sql.should end_with(%(WHERE NOT ("name" LIKE $1)))
    ends.binds.should eq(["%me"] of SugarORM::Value)
    teams.where(billing_email: not(containing("x"))).to_sql
      .should end_with(%(WHERE ("billing_email" LIKE $1) IS NOT TRUE))
  end

  it "widens an Int32 literal in a word to the column's Int64 or Float64" do
    teams = SugarUnit::Team.query
    teams.where(id: not(3)).binds.first.should be_a(Int64)
    teams.where(id: over(3)).binds.first.should be_a(Int64)
    teams.where(ratio: under(2)).binds.first.should be_a(Float64)
  end

  it "renders one SQL text for a list of any length" do
    teams = SugarUnit::Team.query
    teams.where(name: not(["a"])).to_sql.should eq(teams.where(name: not(["a", "b", "c"])).to_sql)
  end

  it "refuses to sum through a lock, and to group an ordered or cut query" do
    expect_raises(ArgumentError, "sum_text does not lock rows; remove .lock from this query") do
      SugarUnit::Team.query.lock.sum_text(:seats)
    end
    expect_raises(ArgumentError, "group_sum_text orders by its key; remove order_by") do
      SugarUnit::Team.query.order_by(:seats).group_sum_text(:archived, :seats)
    end
    expect_raises(ArgumentError, /groups every matching row; remove limit and offset/) do
      SugarUnit::Team.query.limit(2).group_sum_text(:archived, :seats)
    end
  end

  it "refuses a lock outside a transaction before it runs any SQL" do
    expect_raises(SugarORM::Error, /no transaction is open/) do
      SugarUnit::Team.query.lock.to_a
    end
    expect_raises(SugarORM::Error, /no transaction is open/) do
      SugarUnit::Team.query.lock.find!(1_i64)
    end
  end

  it "rejects negative limits and offsets and unknown directions" do
    expect_raises(ArgumentError) { SugarUnit::Team.query.limit(-1) }
    expect_raises(ArgumentError) { SugarUnit::Team.query.offset(-1) }
    expect_raises(ArgumentError, /must be :asc or :desc, not :sideways/) do
      SugarUnit::Team.query.order_by(:name, :sideways)
    end
  end
end
