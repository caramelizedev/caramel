# SweetTalk's rules on a small shelf: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, and a factory whose event's
# policy runs as the actor who made the aggregate.
require "./support/app"

module RulesSpec
  FAILED = "SELECT last_error FROM caramel_jobs WHERE failed_at IS NOT NULL"

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
end
