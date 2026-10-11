# A small shelf for SweetTalk's rules: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, a factory whose event's
# policy runs as the actor who made the aggregate, values whose bounds and lengths
# PostgreSQL checks too, except one that opts out, a process whose steps may overlap and
# whose deadline a step arms for its own span, and a policy whose first delivery fails.
require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  TALLEST = 3

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"
    value Price, Int64, at_least: 0, times: Count, means: "what one thing costs"

    aggregate Box, means: "a box on the shelf" do
      has label : String
      has count : Count
      moves draft >> live >> sold, draft >> scrapped, live >> scrapped

      event Shared, means: "a box asked every box to be tagged"
      event Tallied, by : Int32, pause : Int32, means: "a box was counted again"
      event Noted, means: "a box asked to be noted down"

      to tally(by : Int32, pause : Int32 = 0) do
        emit Tallied, by: by, pause: pause
      end

      to note do
        emit Noted
      end

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

    value Stack, Int32, at_most: TALLEST, database_check: false,
      means: "how many bins stand on one another"
    value Code, String, length: 2..4, means: "the code painted on a bin"
    value Tag, String, length: 2.., means: "a word written on a box"
    value Note, String, length: ...9, means: "a short note on a box"

    value Size, means: "the width and depth of a bin, in boxes" do
      part width : Count
      part depth : Count
    end

    aggregate Bin, means: "a bin whose values PostgreSQL checks too" do
      has stack : Stack
      has size : Size
      has code : Code
    end

    process Tally, means: "how much a box was counted, until it goes quiet" do
      key box : Box
      has total : Int32 = 0

      whenever Box::Tallied, key: tallied.box_id do |tallied|
        @total += tallied.by
        arm quiet, after: tallied.by.hours
        sleep tallied.pause.milliseconds
      end

      deadline quiet, after: 1.day do
        @total = 0
      end
    end

    @@notes = [] of String

    # The event ids the Noted policy has seen, one per delivery.
    def self.notes : Array(String)
      @@notes
    end

    whenever Box::Shared do |shared|
      Box.all.each(&.tag("shared"))
    end

    whenever Crate::Made do |made|
      Crate.find(made.crate_id).sign made.actor || "nobody"
    end

    whenever Box::Noted do |noted|
      notes << noted.event_id
      raise "the first delivery of a note fails" if notes.count(noted.event_id) == 1
    end

    service fill_two(first : Box::Id, second : Box::Id), means: "fills two boxes in one call" do
      Box.find(first).fill Count.new(1)
      Box.find(second).fill Count.new(1)
    end
  end
end
