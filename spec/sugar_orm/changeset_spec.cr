require "spec"
require "./support/unit_schemas"

private alias Default = SugarUnit::Team::DefaultChangeset
private alias Update = SugarUnit::Team::UpdateChangeset
private alias Profile = SugarUnit::Team::ProfileChangeset

describe SugarORM::Changeset do
  it "validates inclusion of a codec field against values of its type" do
    ok = SugarUnit::Ticket::GradeChangeset.new(grade: SugarUnit::Grade::Premium)
    ok.errors.should be_empty
    bad = SugarUnit::Ticket::GradeChangeset.new(grade: SugarUnit::Grade::Basic)
    bad.errors["grade"].should eq(["is invalid"])
  end

  it "refuses to insert a changeset that names a version" do
    changeset = SugarUnit::Counter::Count.new(label: "tea", lock_version: 1)
    expect_raises(ArgumentError, /only an update checks/) do
      SugarORM::Repo.insert(changeset)
    end
  end

  it "runs validate(cs) on construction" do
    changeset = Update.new(SugarUnit.team, seats: 0, billing_email: "not-an-address")
    changeset.valid?.should be_false
    changeset.errors.should eq({
      "seats"         => ["must be greater than 0"],
      "billing_email" => ["has invalid format"],
    })
    valid = Update.new(SugarUnit.team, seats: 10, billing_email: "billing@acme.com")
    valid.valid?.should be_true
  end

  it "keeps only the changes that differ from the record" do
    team = SugarUnit.team(seats: 10)
    changeset = Update.new(team, seats: 10, billing_email: "billing@acme.com")
    expected = {"billing_email" => "billing@acme.com"} of String => SugarORM::Value
    changeset.changes.should eq(expected)
    Update.new(team, seats: 10).changes.should be_empty
    billed = team.with(billing_email: "a@b.c")
    cleared = {"billing_email" => nil} of String => SugarORM::Value
    Update.new(billed, billing_email: nil).changes.should eq(cleared)
  end

  it "validates only changed values, so an unchanged invalid value is not re-reported" do
    team = SugarUnit.team(seats: 0)
    Update.new(team, billing_email: "a@b.c").valid?.should be_true
  end

  it "requires every NOT NULL column without a default on insert, " \
     "and rejects nil for NOT NULL columns" do
    Default.new(seats: 3).errors.should eq({"name" => ["is required"]})
    Default.new(name: "Acme").valid?.should be_true
    Default.new(name: "Acme", seats: nil).errors.should eq({"seats" => ["is required"]})
    Update.new(SugarUnit.team, seats: nil).errors.should eq({"seats" => ["is required"]})
    member = SugarUnit::Member::DefaultChangeset.new(email: "a@b.c")
    member.errors.should eq({"team_id" => ["is required"]})
  end

  it "applies presence, length, inclusion, less_than and required validations" do
    team = SugarUnit.team
    errors = Profile.new(team, name: " ", motto: "nope", seats: 100).errors
    errors.should eq({
      "name"          => ["can't be blank", "should be at least 2 character(s)"],
      "motto"         => ["is invalid"],
      "seats"         => ["must be less than 100"],
      "billing_email" => ["needs an address"],
    })
    long = Profile.new(team, name: "A very long name")
    long.errors["name"].should eq(["should be at most 10 character(s)"])
    complete = Profile.new(team, name: "Go", motto: "go", billing_email: "x@y.z")
    complete.valid?.should be_true
    Profile.new(team.with(billing_email: "x@y.z"), name: "Go").valid?.should be_true
  end

  it "exposes the original record for an update and refuses one for an unsaved insert" do
    team = SugarUnit.team
    update = Update.new(team, seats: 11)
    update.record.should eq(team)
    update.saved?.should be_false
    insert = Default.new(name: "New")
    insert.insert?.should be_true
    expect_raises(SugarORM::Error, /has not been inserted/) { insert.record }
  end

  it "accepts errors added by callers and reports them through Invalid" do
    changeset = Update.new(SugarUnit.team, seats: 3)
    changeset.add_error(:seats, "exceeds the plan")
    changeset.add_error("_base", "Team is locked")
    changeset.valid?.should be_false
    expected = "SugarUnit::Team::UpdateChangeset is invalid: " \
               "seats exceeds the plan; Team is locked"
    SugarORM::Invalid.new(changeset).message.should eq(expected)
  end

  it "rejects the wrong kind of Repo operation before touching a database" do
    insert = Default.new(name: "New")
    update = Update.new(SugarUnit.team, seats: 3)
    expect_raises(ArgumentError, /use SugarORM::Repo.insert/) do
      SugarORM::Repo.update(insert)
    end
    expect_raises(ArgumentError, /use SugarORM::Repo.update/) do
      SugarORM::Repo.insert(update)
    end
  end

  it "does not write an invalid changeset" do
    changeset = Default.new(seats: 3)
    before = SugarORM::Repo.statements_executed
    SugarORM::Repo.insert(changeset).saved?.should be_false
    SugarORM::Repo.statements_executed.should eq(before)
  end

  it "refuses check_constraint for a check the schema does not declare" do
    changeset = SugarUnit::Shelf::DefaultChangeset.new(stock: 1)
    expect_raises(ArgumentError, /declares no check named missing/) do
      changeset.check_constraint(:missing)
    end
  end

  it "refuses check_constraint without on: for an expression check" do
    changeset = SugarUnit::Shelf::DefaultChangeset.new(stock: 1)
    expect_raises(ArgumentError, /names an expression check/) do
      changeset.check_constraint(:reserved_within_stock)
    end
    changeset.check_constraint(:reserved_within_stock, on: :reserved)
  end
end
