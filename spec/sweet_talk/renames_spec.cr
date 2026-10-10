# A domain renamed with `renamed_from:` keeps the names it stored: tables, an entity's
# parent column, the channel, and jobs queued under the old names.
require "./support/app"

alias Pantry = Renamed::Pantry

module RenamesSpec
  # A row the domain stored as Store::Tea, with one Tin, and its Stockroom row.
  def self.stored_tea : Int64
    tea = SugarORM.sql(<<-SQL, as: {id: Int64}).first[:id]
      INSERT INTO store_teas (name, stock, created_at, updated_at)
      VALUES ('Sencha', 5, now(), now()) RETURNING id
      SQL
    SugarORM.sql_exec(<<-SQL, tea)
      INSERT INTO store_tea_tins (tea_id, label, created_at, updated_at)
      VALUES ($1, 'first', now(), now())
      SQL
    SugarORM.sql_exec(<<-SQL, tea)
      INSERT INTO store_stockrooms (tea_id, restocked, created_at, updated_at)
      VALUES ($1, 3, now(), now())
      SQL
    tea
  end
end

describe "SweetTalk renames" do
  it "keeps every renamed kind's table and channel" do
    Pantry::SWEETTALK_STORED.should eq("store")
    Pantry::Blend::SWEETTALK_TABLE.should eq("store_teas")
    Pantry::Blend::Can::SWEETTALK_TABLE.should eq("store_tea_tins")
    Pantry::Blend::Can::SWEETTALK_PARENT[0].should eq("tea")
    Pantry::Larder::SWEETTALK_TABLE.should eq("store_stockrooms")
    Pantry::Blend::Refilled::SWEETTALK_CHANNEL.should eq("sweettalk.store.tea.restocked")
  end

  it "reads rows stored under the old names" do
    SweetTalkSpec.rolled_back do
      tea = RenamesSpec.stored_tea
      blend = Pantry::Blend.find(Pantry::Blend::Id.new(tea))
      {blend.name, blend.stock.raw, blend.cans.map(&.label)}.should eq({"Sencha", 5, ["first"]})
      Pantry::Larder.all.map { |row| {row.tea.raw, row.restocked} }.should eq([{tea, 3}])
    end
  end

  it "runs a job queued under its old name" do
    SweetTalkSpec.rolled_back do |connection|
      tea = RenamesSpec.stored_tea
      meta = {id: UUID.random.to_s, at: Time.utc.to_rfc3339(fraction_digits: 6), by: nil}
      payload = {subject: tea, fields: %({"tins":2}), meta: meta.to_json}
      queued = "INSERT INTO caramel_jobs (class_name, payload) VALUES ($1, $2::jsonb)"
      old = "Renamed::Store::Stockroom::WhenTeaRestocked"
      SugarORM.sql_exec(queued, old, payload.to_json)

      Caramel::ColdBrew.drain_queue!(connection).should eq(1)
      Pantry::Larder.all.map { |row| {row.tea.raw, row.restocked} }.should eq([{tea, 5}])
    end
  end
end
