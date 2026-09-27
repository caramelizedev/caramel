require "./schemas"

class User::CreateChangeset < SugarORM::Changeset(User)
  param email : String
  param team_id : Int64

  def validate(cs)
    cs.validate_required(:email)
    cs.unique_constraint(:email)
  end
end

def exercise(db : DB::Database)
  SugarORM::Repo.database = db
  team = Team.create!(name: "Acme")
  Team.create(db, name: "Beta").saved?
  team = team.update!(seats: 10, billing_email: "billing@acme.com")
  team.update(db, seats: 11).errors
  User.create!(db, email: "founder@caramel.dev", team_id: team.id)
  SugarORM::Repo.update(Team::UpdateChangeset.new(team, seats: 12)).record.seats
  SugarORM::Repo.insert(Team::DefaultChangeset.new(name: "Gamma", owner_id: nil)).saved?

  Team::Query.where(name: "Acme").first!(db).seats
  User::Query.where(team_id: team.id).count(db)
  Team.query.active.larger_than(3).where(id: [1_i64], seats: 1..5, billing_email: nil).order_by(:name, :desc).limit(5).offset(1).to_a.map(&.name)
  Team.query.where("seats > ?", 3).each { |row| row.with(name: "copy").name }

  Team.query.preload(:users).preload(:owner).preload(:profile).to_a.each do |loaded|
    loaded.users.each { |user| user.email }
    loaded.owner.try(&.email)
    loaded.profile.try(&.bio)
    loaded.name
  end
  User.query.preload(:team).find!(1).team.name
  Team.query.preload(:users).find(team.id).try(&.users.size)

  SugarORM::Repo.transaction do
    SugarORM.sql("SELECT team_id, count(*) AS total FROM users GROUP BY team_id", as: {team_id: Int64, total: Int64}).first?.try(&.[:total])
    SugarORM.sql_exec("UPDATE teams SET seats = seats + $1", 1)
    SugarORM::Repo.transaction { SugarORM::Repo.rollback }
  end
  team.delete
  SugarORM::Catalog.declared.map(&.name)
  team.to_json
  SugarORM.sql(db, "SELECT 1::bigint AS one", as: {one: Int64}).first[:one]
  SugarORM.sql_exec(db, "DELETE FROM users WHERE email = $1", "gone@caramel.dev")
  SugarORM::Repo.insert(db, Team::DefaultChangeset.new(name: "Delta")).saved?
  Team::Query.each(db) { |row| row.id }
  Team.query.exists?(db) && Team.query.delete_all(db)
end

exercise(DB.open("postgres://unused@localhost/unused")) if ARGV.includes?("--never")
