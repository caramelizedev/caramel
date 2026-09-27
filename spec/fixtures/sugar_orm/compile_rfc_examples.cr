# Every Crystal block of docs/rfc.md RFC-0002 §2.1–§2.4 and §3, copied
# verbatim. Only the scaffolding the snippets assume is added: the User schema,
# a render_form stub, and defs that supply team_id/team and allow `return`.
require "../../../src/sugar_orm"

# app/models/team.cr
struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
    field name : String
    field seats : Int32 = 5
    field billing_email : String?
    timestamps

    # Typed relation: un-preloaded access fails to compile
    has_many users : User
    belongs_to owner : User?
    index :name, unique: true
  end

  scope larger_than(seats : Int32) { where("seats > ?", seats) }
end

struct User < SugarORM::Schema
  schema "users" do
    field id : Int64, primary: true
    field email : String
    belongs_to team : Team
  end
end

# app/changesets/team.cr
class Team::UpdateChangeset < SugarORM::Changeset(Team)
  param seats : Int32
  param billing_email : String?

  def validate(cs)
    cs.validate_greater_than(:seats, 0)
    cs.validate_format(:billing_email, /^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$/)
  end
end

def render_form(errors : Hash(String, Array(String))) : String
  errors.to_s
end

# §2.2
def rfc_preload(team_id : Int64)
  team = Team.query.preload(:users).find!(team_id)
  team.users.each do |user|   # Array(User)
    puts user.email
  end
end

# §2.3
def rfc_facade(team : Team)
  # 1. Developer-Facing Fluent Ergonomics (Rails/Laravel Happiness)
  change = team.update(seats: 10, billing_email: "billing@acme.com")
  return render_form(change.errors) unless change.saved?

  # 2. What the Facade Does Under the Hood:
  changeset = Team::UpdateChangeset.new(team, seats: 10, billing_email: "billing@acme.com")
  SugarORM::Repo.update(changeset)   # => the same changeset: saved?, record, errors
end

# §3
def rfc_sql
  ranked = SugarORM.sql(<<-SQL, 30.days.ago, as: {team_id: Int64, total: Int64, rank: Int32})
    WITH totals AS (SELECT team_id, count(*) AS total FROM users WHERE created_at > $1 GROUP BY team_id)
    SELECT team_id, total, rank() OVER (ORDER BY total DESC)::int4 AS rank FROM totals
    SQL
end

# Type-check every snippet; never run (no database is configured).
if ARGV.includes?("--never")
  rfc_preload(1_i64)
  rfc_facade(Team.query.find!(1_i64))
  rfc_sql
  Team.query.larger_than(3).to_a
end
