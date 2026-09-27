require "../../../src/sugar_orm"

struct Team < SugarORM::Schema
  schema "teams" do
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
  schema "users" do
    field id : Int64, primary: true
    field email : String
    belongs_to team : Team
  end
end

struct Profile < SugarORM::Schema
  schema "profiles" do
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
