# SweetTalk's units (ADR 0046): two boxes, or a box and a crate, changed in one
# transaction under locks taken first in table then id order; a raise or a set rule rolls
# every change back and reloads every instance; a command on a type the unit does not
# change, or on a row it did not lock, is refused; a unit is a service's one change, and
# is refused inside a command or another unit; and `SweetTalk.lock` needs a transaction.
require "./support/app"

module UnitsSpec
  def self.box(label : String) : Rules::Shelf::Box
    Rules::Shelf::Box.create(label: label, count: Rules::Shelf::Count.new(0))
  end

  # The stored count of each of *boxes*, read again.
  def self.counts(*boxes : Rules::Shelf::Box) : Array(Int32)
    boxes.map { |box| Rules::Shelf::Box.find(box.id).count.raw }.to_a
  end
end

describe "SweetTalk's units" do
  it "commits a unit's changes to two boxes together" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      Rules::Shelf.fill_both(first, second, 2)
      UnitsSpec.counts(first, second).should eq([2, 2])
      {first.count.raw, second.count.raw}.should eq({2, 2})
    end
  end

  it "rolls a unit back when it raises after its second command, and reloads both boxes" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(Exception, "the shelf fell over") do
        Rules::Shelf.fill_both(first, second, 13)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
      {first.count.raw, second.count.raw}.should eq({0, 0})
    end
  end

  it "refuses a unit by a rule over the set, after the body, and rolls both back" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(SweetTalk::Refusal, "A box holds at most nine things.") do
        Rules::Shelf.fill_both(first, second, 10)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
      {first.count.raw, second.count.raw}.should eq({0, 0})
    end
  end

  it "locks a box and a crate in table order and commits both" do
    SweetTalkSpec.rolled_back do
      box, crate = UnitsSpec.box("first"), Rules::Shelf::Crate.make("crate")
      Rules::Shelf.tag_and_sign(box.id, crate.id, "paired")
      Rules::Shelf::Box.find(box.id).label.should eq("paired")
      Rules::Shelf::Crate.find(crate.id).maker.should eq("paired")
    end
  end

  it "raises Missing for a locked id with no row, before any command runs" do
    SweetTalkSpec.rolled_back do
      box = UnitsSpec.box("first")
      expect_raises(SweetTalk::Missing, "There is no Crate 0.") do
        Rules::Shelf.tag_and_sign(box.id, Rules::Shelf::Crate::Id.new(0), "paired")
      end
      Rules::Shelf::Box.find(box.id).label.should eq("first")
    end
  end

  it "refuses a command on an aggregate the unit does not change, naming the unit" do
    SweetTalkSpec.rolled_back do
      box = UnitsSpec.box("first")
      tab = Rules::Shelf::Tab.create(label: "tab")
      expect_raises(SweetTalk::Boundary,
        "Rules::Shelf::Tab #{tab.id.raw} changed inside unit Shelf.tag_and_relabel, which " \
        "changes Box: add Tab to its changes:") do
        Rules::Shelf.tag_and_relabel(box.id, tab.id, "stray")
      end
      Rules::Shelf::Box.find(box.id).label.should eq("first")
      Rules::Shelf::Tab.find(tab.id).label.should eq("tab")
    end
  end

  it "refuses a command on an existing row the unit did not lock" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "Rules::Shelf::Box #{second.id.raw} changed inside unit Shelf.fill_unlocked without " \
        "its lock: lock it in locks:") do
        Rules::Shelf.fill_unlocked(first.id, second.id)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
    end
  end

  it "needs no lock for a row the unit created" do
    SweetTalkSpec.rolled_back do
      id = Rules::Shelf.make_filled_pair("new")
      Rules::Shelf::Box.find(id).count.raw.should eq(1)
    end
  end

  it "runs the same unit on the same boxes in opposite order on two connections" do
    SweetTalkSpec.committed do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      done = Channel(Exception?).new
      spawn do
        Rules::Shelf.fill_both(Rules::Shelf::Box.find(first.id), Rules::Shelf::Box.find(second.id),
          1, 300)
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      sleep 50.milliseconds
      Rules::Shelf.fill_both(Rules::Shelf::Box.find(second.id), Rules::Shelf::Box.find(first.id), 1)
      done.receive.should be_nil
      UnitsSpec.counts(first, second).should eq([2, 2])
    end
  end

  it "counts a unit inside a service as the service's one change" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      Rules::Shelf.fill_both_served(first.id, second.id)
      UnitsSpec.counts(first, second).should eq([1, 1])
    end
  end

  it "refuses a command after a unit in one service, and rolls the unit back" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "service Shelf.fill_both_then_one changes one aggregate, and this one already " \
        "changed one: emit an event and react to it in a whenever") do
        Rules::Shelf.fill_both_then_one(first.id, second.id)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
    end
  end

  it "refuses a unit inside a command" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "unit Shelf.fill_both called inside Rules::Shelf::Box #{first.id.raw}'s command: a " \
        "command changes one aggregate") do
        first.fill_both_with(second)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
    end
  end

  it "refuses a unit inside a unit" do
    SweetTalkSpec.rolled_back do
      first, second = UnitsSpec.box("first"), UnitsSpec.box("second")
      expect_raises(SweetTalk::Boundary,
        "unit Shelf.fill_both called inside unit Shelf.fill_both_twice: a unit runs its " \
        "commands itself") do
        Rules::Shelf.fill_both_twice(first, second)
      end
      UnitsSpec.counts(first, second).should eq([0, 0])
    end
  end

  it "refuses SweetTalk.lock outside a transaction" do
    expect_raises(ArgumentError, "SweetTalk.lock runs inside a transaction") do
      SweetTalk.lock(Rules::Shelf::Box::Id.new(1))
    end
  end

  it "lists a unit in the glossary with its meaning" do
    term = SweetTalk.glossary.find { |entry| entry.kind == "unit" && entry.name == "fill_both" }
    term.try(&.context).should eq("Shelf")
    term.try(&.means).should eq("fills two boxes by one count in one transaction")
  end
end
