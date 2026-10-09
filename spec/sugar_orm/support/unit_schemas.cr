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

  record Snapshot, total : Int32 do
    include JSON::Serializable
  end

  module PriceCodec
    def self.sql_type : String
      "numeric(20,8)"
    end

    def self.encode(value : String) : String
      value
    end

    def self.decode(text : String) : String
      text
    end
  end

  struct Quote < SugarORM::Schema
    schema "unit_quotes" do
      field id : Int64, primary: true
      field price : String, codec: PriceCodec
      field fee : String?, codec: PriceCodec
      field snapshot : Snapshot, codec: SugarORM::JSONB(Snapshot)
      field extra : Snapshot?, codec: SugarORM::JSONB(Snapshot)
    end
  end

  enum Grade
    Basic
    Premium
  end

  module GradeCodec
    def self.sql_type : String
      "text"
    end

    def self.encode(value : Grade) : String
      value.to_s
    end

    def self.decode(text : String) : Grade
      Grade.parse(text)
    end
  end

  struct Ticket < SugarORM::Schema
    schema "unit_tickets" do
      field id : Int64, primary: true
      field grade : Grade, codec: GradeCodec
    end
  end

  class Ticket::GradeChangeset < SugarORM::Changeset(Ticket)
    param grade : Grade

    def validate(cs)
      cs.validate_inclusion(:grade, in: [Grade::Premium])
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
