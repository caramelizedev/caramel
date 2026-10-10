# A small shelf for SweetTalk's rules: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, and a factory whose
# event's policy runs as the actor who made the aggregate.
require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"
    value Price, Int64, at_least: 0, times: Count, means: "what one thing costs"

    aggregate Box, means: "a box on the shelf" do
      has label : String
      has count : Count
      moves draft >> live >> sold, draft >> scrapped, live >> scrapped

      event Shared, means: "a box asked every box to be tagged"

      to fill(count : Count) do
        @count += count
      end

      to fill_with(other : Box) do
        @count += Count.new(1)
        other.fill Count.new(1)
      end

      to tag(label : String) do
        @label = label
      end

      to share do
        emit Shared
      end

      to go_live do
        live!
      end

      to sell do
        sold!
      end

      to scrap do
        scrapped!
      end
    end

    aggregate Crate, means: "a crate on the shelf, signed by whoever made it" do
      has label : String
      has maker : String = "nobody"

      event Made, label : String, means: "someone made a crate"

      factory make(label : String) do
        emit Made, label: label
      end

      to sign(maker : String) do
        @maker = maker
      end
    end

    whenever Box::Shared do |shared|
      Box.all.each(&.tag("shared"))
    end

    whenever Crate::Made do |made|
      Crate.find(made.crate_id).sign made.actor || "nobody"
    end

    service fill_two(first : Box::Id, second : Box::Id), means: "fills two boxes in one call" do
      Box.find(first).fill Count.new(1)
      Box.find(second).fill Count.new(1)
    end
  end
end
