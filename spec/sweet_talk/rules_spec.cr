# SweetTalk's rules on a small shelf: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, a factory whose event's
# policy runs as the actor who made the aggregate, string lengths, a process row two
# steps update at once, a deadline armed for a step's own span, a retried policy, and
# entities stored again by a second aggregate or after a failed create.
require "./support/app"

module RulesSpec
  FAILED  = "SELECT last_error FROM caramel_jobs WHERE failed_at IS NOT NULL"
  TALLIED = "SELECT count(*) AS value FROM caramel_jobs " \
            "WHERE class_name = 'Rules::Shelf::Tally::WhenBoxTallied' AND finished_at IS NOT NULL"

  def self.box(label : String) : Rules::Shelf::Box
    Rules::Shelf::Box.create(label: label, count: Rules::Shelf::Count.new(0))
  end

  # Ten jars, the first to the tenth: label, count, size, sealed, note, and a move.
  JARS = [
    {"assam", 1, {1, 1}, false, nil, nil},
    {"bancha", 5, {2, 2}, true, "gift", nil},
    {"ceylon", 7, {1, 2}, true, nil, nil},
    {"darjeeling", 2, {2, 2}, true, "gift", "sell_out"},
    {"earl grey", 3, {1, 1}, false, "", "scrap"},
    {"fujian", 10, {2, 2}, false, nil, "scrap"},
    {"genmaicha", 4, {1, 2}, true, nil, nil},
    {"hojicha", 6, {2, 2}, false, "fragile", nil},
    {"irish", 9, {1, 1}, true, "gift", nil},
    {"jasmine", 1, {2, 2}, true, "fragile", nil},
  ]

  # Creates the ten jars and returns them in order.
  def self.jars : Array(Rules::Shelf::Jar)
    JARS.map do |(label, count, (width, depth), sealed, note, move)|
      size = Rules::Shelf::Size.new(width: Rules::Shelf::Count.new(width),
        depth: Rules::Shelf::Count.new(depth))
      jar = Rules::Shelf::Jar.create(label: label, count: Rules::Shelf::Count.new(count),
        size: size, sealed: sealed, note: note)
      jar.sell_out if move == "sell_out"
      jar.scrap if move == "scrap"
      jar
    end
  end

  # Each found jar's place among *jars*, counting from 1, since ids differ between runs.
  def self.places(jars : Array(Rules::Shelf::Jar), found : Array(Rules::Shelf::Jar))
    found.map { |jar| jars.map(&.id).index!(jar.id) + 1 }
  end

  # Where *rule* puts the jars, read by PostgreSQL and then by Crystal over *all*.
  def self.readings(jars : Array(Rules::Shelf::Jar), all : Array(Rules::Shelf::Jar),
                    rule : S.class) forall S
    {places(jars, Rules::Shelf::Jar.all(satisfying: rule)),
     places(jars, all.select { |jar| rule.satisfied_by?(jar) })}
  end
end

describe "SweetTalk's rules" do
  it "refuses a command that changes a second aggregate, and rolls the first back" do
    SweetTalkSpec.rolled_back do
      first, second = RulesSpec.box("first"), RulesSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "Rules::Shelf::Box #{second.id.raw} changed inside " \
        "Rules::Shelf::Box #{first.id.raw}'s command") do
        first.fill_with(second)
      end
      first.count.raw.should eq(0)
      Rules::Shelf::Box.find(first.id).count.raw.should eq(0)
      Rules::Shelf::Box.find(second.id).count.raw.should eq(0)
    end
  end

  it "fails a handler that changes a second aggregate" do
    SweetTalkSpec.rolled_back do |connection|
      first, second = RulesSpec.box("first"), RulesSpec.box("second")
      first.share
      Caramel::ColdBrew.drain_queue(connection).should eq(1)
      errors = SugarORM.sql(RulesSpec::FAILED, as: {last_error: String}).map(&.[:last_error])
      errors.size.should eq(1)
      errors.first.should contain("a whenever handler changes one aggregate")
      labels = [first, second].map { |box| Rules::Shelf::Box.find(box.id).label }
      labels.should eq(["first", "second"])
    end
  end

  it "multiplies a price by a count because Price declares times: Count" do
    (Rules::Shelf::Price.new(250) * Rules::Shelf::Count.new(3)).raw.should eq(750)
  end

  it "moves along any declared chain, and refuses from states before none of them" do
    SweetTalkSpec.rolled_back do
      scrapped_draft = RulesSpec.box("draft")
      scrapped_draft.scrap
      scrapped_draft.scrapped?.should be_true

      live = RulesSpec.box("live")
      live.go_live
      live.scrap
      live.scrapped?.should be_true
      expect_raises(SweetTalk::Refusal, "Box cannot become sold while scrapped") { live.sell }

      draft = RulesSpec.box("unsold")
      expect_raises(SweetTalk::Refusal, "Box cannot become sold while draft") { draft.sell }
    end
  end

  it "finds a two-word state after a save" do
    SweetTalkSpec.rolled_back do
      first = Rules::Shelf::Tab.create(label: "a")
      second = Rules::Shelf::Tab.create(label: "b")
      first.relabel("c")
      second.pay
      states = SugarORM.sql("SELECT state FROM shelf_tabs ORDER BY id", as: {state: String})
      states.map(&.[:state]).should eq(["awaiting_payment", "paid"])
      Rules::Shelf::Tab.awaiting.map(&.id).should eq([first.id])
    end
  end

  it "refuses a service that changes a second aggregate, and rolls both back" do
    SweetTalkSpec.rolled_back do
      first, second = RulesSpec.box("first"), RulesSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "service Shelf.fill_two changes one aggregate, and this one already changed one: " \
        "emit an event and react to it in a whenever") do
        Rules::Shelf.fill_two(first.id, second.id)
      end
      [first, second].map { |box| Rules::Shelf::Box.find(box.id).count.raw }.should eq([0, 0])
    end
  end

  it "makes a crate only through its factory, and its policy signs it as the actor" do
    SweetTalkSpec.rolled_back do |connection|
      crate = SweetTalk.acting("member:7") { Rules::Shelf::Crate.make("oak") }
      Caramel::ColdBrew.drain_queue!(connection).should eq(1)
      Rules::Shelf::Crate.find(crate.id).maker.should eq("member:7")
    end
  end

  it "refuses a string whose length is outside an open or exclusive range" do
    expect_raises(SweetTalk::Refusal, "Tag must be at least 2 characters") do
      Rules::Shelf::Tag.new("a")
    end
    expect_raises(SweetTalk::Refusal, "Note must be at most 8 characters") do
      Rules::Shelf::Note.new("x" * 9)
    end
    expect_raises(SweetTalk::Refusal, "Code must be between 2 and 4 characters") do
      Rules::Shelf::Code.new("a")
    end
  end

  it "keeps both changes when two steps update one process row at once" do
    SweetTalkSpec.committed do
      box = RulesSpec.box("tallied")
      box.tally 1
      Caramel::ColdBrew.drain_queue!(SweetTalkSpec.runtime).should eq(1)
      box.tally 2, pause: 300
      worker = Caramel::ColdBrew::Worker.new("default", 2, SweetTalkSpec.runtime)
      begin
        worker.start
        sleep 100.milliseconds # the first step now holds the row in its pause
        box.tally 4
        SweetTalkSpec.eventually("three tally steps finished") do
          SugarORM.sql(RulesSpec::TALLIED, as: {value: Int64}).first[:value] == 3
        end
      ensure
        worker.stop
      end
      Rules::Shelf::Tally.all.map { |row| {row.box.raw, row.total} }.should eq([{box.id.raw, 7}])
    end
  end

  it "arms a deadline for the span a step names" do
    SweetTalkSpec.rolled_back do |connection|
      RulesSpec.box("quiet").tally 3
      Caramel::ColdBrew.drain_queue!(connection).should eq(1)
      due = Rules::Shelf::Tally.all.first.quiet_due.not_nil!
      (due - Time.utc).should be_close(3.hours, 1.minute)
    end
  end

  it "hands a retried policy the event id it had the first time, a key for side effects" do
    SweetTalkSpec.rolled_back do |connection|
      Rules::Shelf.notes.clear
      RulesSpec.box("noted").note
      Caramel::ColdBrew.drain_queue(connection).should eq(1)
      Caramel::ColdBrew.drain_queue!(connection, include_scheduled: true).should eq(1)
      meta = SugarORM.sql("SELECT payload->>'meta' AS meta FROM caramel_jobs", as: {meta: String})
      id = JSON.parse(meta.first[:meta])["id"].as_s
      Rules::Shelf.notes.should eq([id, id])
    end
  end

  it "inserts held entities again after a create that failed" do
    SweetTalkSpec.rolled_back do
      box = RulesSpec.box("held")
      held = Rules::Shelf::Rack::Slot.new(box)
      missing = Rules::Shelf::Rack::Slot.new(Rules::Shelf::Box::Id.new(999_999))
      expect_raises(PQ::PQError, "fk_shelf_rack_slots_box_id") do
        Rules::Shelf::Rack.create(slots: [held, missing])
      end
      rack = Rules::Shelf::Rack.create(slots: [held])
      Rules::Shelf::Rack.find(rack.id).slots.map(&.box).should eq([box.id])
    end
  end

  it "copies an entity taken from another aggregate instead of moving its row" do
    SweetTalkSpec.rolled_back do
      box = RulesSpec.box("shared")
      first = Rules::Shelf::Rack.create(slots: [Rules::Shelf::Rack::Slot.new(box)])
      second = Rules::Shelf::Rack.create(slots: Rules::Shelf::Rack.find(first.id).slots)
      [first, second].map { |rack| Rules::Shelf::Rack.find(rack.id).slots.size }.should eq([1, 1])
    end
  end

  it "spells a two-word state in a lifecycle refusal as moves does" do
    SweetTalkSpec.rolled_back do
      size = Rules::Shelf::Size.new(width: Rules::Shelf::Count.new(1),
        depth: Rules::Shelf::Count.new(1))
      jar = Rules::Shelf::Jar.create(label: "keemun", count: Rules::Shelf::Count.new(1),
        size: size, sealed: true)
      jar.sell_out
      expect_raises(SweetTalk::Refusal, "Jar cannot become scrapped while sold_out") { jar.scrap }
    end
  end

  it "reads every specification alike in Crystal and in PostgreSQL" do
    SweetTalkSpec.rolled_back do
      jars = RulesSpec.jars
      all = Rules::Shelf::Jar.all
      {% for rule, expected in {OnSale: [2, 3, 7, 9, 10], Full: [2, 3, 6, 8, 9],
                                Gift: [2, 4, 9], Plain: [1, 3, 5, 6, 7, 8, 10],
                                Wide: [2, 4, 6, 8, 10], Unnoted: [1, 3, 6, 7],
                                Gone: [4, 5, 6], Stocked: [2, 3, 4, 6, 8, 9],
                                Featured: [2, 3, 9]} %}
        readings = RulesSpec.readings(jars, all, Rules::Shelf::{{ rule.id }})
        wanted = {{ expected }}
        { {{ rule.stringify }}, readings }.should eq({ {{ rule.stringify }}, {wanted, wanted} })
      {% end %}
    end
  end

  it "keeps a forgotten jar out of a specification that joins two with |" do
    SweetTalkSpec.rolled_back do
      jars = RulesSpec.jars
      jars[5].forget
      found = Rules::Shelf::Jar.all(satisfying: Rules::Shelf::Stocked)
      RulesSpec.places(jars, found).should eq([2, 3, 4, 8, 9])
    end
  end

  it "refuses through a specification in an invariant and a guard" do
    SweetTalkSpec.rolled_back do
      jars = RulesSpec.jars
      expect_raises(SweetTalk::Refusal, "A jar on sale needs a label.") { jars[1].relabel("") }
      expect_raises(SweetTalk::Refusal, "Only a jar on sale sells out.") { jars[0].sell_out }
      RulesSpec.places(jars, Rules::Shelf::Jar.on_sale_labelled("ceylon")).should eq([3])
      Rules::Shelf::Jar.on_sale_labelled("assam").should be_empty
    end
  end

  it "lists specifications in the glossary" do
    terms = SweetTalk.glossary.select { |term| term.kind == "specification" }
    terms.count(&.context.==("Shelf")).should eq(9)
    on_sale = terms.find! { |term| term.name == "OnSale" }
    {on_sale.kind, on_sale.name, on_sale.context, on_sale.means}
      .should eq({"specification", "OnSale", "Shelf", "a sealed jar still on the shelf"})
  end
end
