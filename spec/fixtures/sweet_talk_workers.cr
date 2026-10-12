require "../../src/caramel"
require "../sweet_talk/support/rules"

# The application scripts/check sweet-talk-workers runs: the rules domain behind
# `Caramel.run`, so `work` goes through the path production takes. Its words
# `issue` and `report` drive and read the domain from the same binary.

struct SweetTalkWorkersHealth < Caramel::Action
  contract do
  end

  def layout(page : Caramel::Page) : String
    page.body
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "ok")
  end
end

module App
  TITLE = "Rules workers"

  # The migration that creates every declared table, with the version and name
  # spec/sweet_talk/support/app.cr gives it.
  def self.schemas : SugarORM::Migration
    plan = SugarORM::Differ.diff(SugarORM::Catalog.declared, [] of SugarORM::Catalog::Table)
    statements = SugarORM::DDL.statements(plan.transactional)
    SugarORM::Migration.new(20261009000000_i64, "create_sweet_talk", statements)
  end

  MIGRATIONS = Caramel::ColdBrew::MIGRATIONS + [schemas]

  def self.seed(_db : DB::Database) : Nil
  end

  # `Router.draw` needs at least one route.
  Caramel::Router.draw do
    get "/health", SweetTalkWorkersHealth
  end
end

module SweetTalkWorkers
  TALLIED = "class_name = 'Rules::Shelf::Tally::WhenBoxTallied'"

  # `issue COUNT PAUSE`: ten new boxes, then COUNT tally commands spread over
  # them, the nth tallying n, each step pausing PAUSE milliseconds.
  def self.issue(count : Int32, pause : Int32) : Nil
    boxes = Array.new(10) do |index|
      Rules::Shelf::Box.create(label: "box#{index}", count: Rules::Shelf::Count.new(0))
    end
    count.times { |index| boxes[index % 10].tally(index + 1, pause: pause) }
  end

  # `report`: the tally steps' progress and every box's Tally total, as JSON.
  def self.report : String
    jobs = SugarORM.sql(<<-SQL, as: {finished: Int64, locked: Int64, max_attempts: Int32}).first
      SELECT count(finished_at) AS finished,
             count(*) FILTER (WHERE locked_at IS NOT NULL AND finished_at IS NULL) AS locked,
             coalesce(max(attempts), 0) AS max_attempts
      FROM caramel_jobs WHERE #{TALLIED}
      SQL
    totals = Rules::Shelf::Tally.all.map { |row| [row.box.raw, row.total.to_i64] }.sort!
    {finished: jobs[:finished], locked: jobs[:locked],
     max_attempts: jobs[:max_attempts], totals: totals}.to_json
  end
end

if ARGV.first?.in?("issue", "report")
  SugarORM::Repo.database = Caramel::Database.open(ENV["DATABASE_URL"], 2)
  if ARGV.first == "issue"
    SweetTalkWorkers.issue(ARGV[1].to_i, ARGV[2].to_i)
  else
    puts SweetTalkWorkers.report
  end
  exit 0
end

Caramel.run(App)
