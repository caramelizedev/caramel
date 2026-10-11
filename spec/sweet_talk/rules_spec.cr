# SweetTalk's rules on a small shelf: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, a factory whose event's
# policy runs as the actor who made the aggregate, string lengths, a process row two
# steps update at once, a deadline armed for a step's own span, and a retried policy.
require "./support/app"

module RulesSpec
  FAILED  = "SELECT last_error FROM caramel_jobs WHERE failed_at IS NOT NULL"
  TALLIED = "SELECT count(*) AS value FROM caramel_jobs " \
            "WHERE class_name = 'Rules::Shelf::Tally::WhenBoxTallied' AND finished_at IS NOT NULL"

  def self.box(label : String) : Rules::Shelf::Box
    Rules::Shelf::Box.create(label: label, count: Rules::Shelf::Count.new(0))
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
end
