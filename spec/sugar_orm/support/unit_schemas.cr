require "../../../src/sugar_orm"

module SugarUnit
  struct Team < SugarORM::Schema
    schema "unit_teams" do
      field id : Int64, primary: true
      field name : String
      field seats : Int32 = 5
      field ratio : Float64 = 2.5
      field archived : Bool = false
      field motto : String = "it's on"
      field billing_email : String?, renamed_from: :email
      timestamps
      has_many members : Member
      belongs_to owner : Member?
      has_one charter : Charter
      index :name, unique: true
      index :seats, :archived
      drop_column :legacy_code
    end

    scope active { where(archived: false) }
    scope larger_than(seats : Int32) { where("seats > ?", seats) }
  end

  struct Member < SugarORM::Schema
    schema "unit_members" do
      field id : Int64, primary: true
      field email : String
      field joined_at : Time?
      belongs_to team : Team
    end
  end

  struct Charter < SugarORM::Schema
    schema "unit_charters" do
      field id : Int64, primary: true
      field body : String
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

  class Team::ProfileChangeset < SugarORM::Changeset(Team)
    param name : String
    param motto : String
    param seats : Int32
    param billing_email : String?

    def validate(cs)
      cs.validate_presence(:name)
      cs.validate_length(:name, min: 2, max: 10)
      cs.validate_inclusion(:motto, in: ["it's on", "go"])
      cs.validate_less_than(:seats, 100)
      cs.validate_required(:billing_email, message: "needs an address")
    end
  end

  def self.team(**overrides) : Team
    team = Team.new(
      id: 7_i64,
      name: "Acme",
      created_at: Time.utc(2026, 1, 1),
      updated_at: Time.utc(2026, 1, 2),
    )
    team.with(**overrides)
  end
end
