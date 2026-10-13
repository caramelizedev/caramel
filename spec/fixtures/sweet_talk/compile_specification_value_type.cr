require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"

    aggregate Jar, means: "a jar of loose tea" do
      has label : String
      has count : Count
      has slots : Array(Slot)
      moves on_shelf >> sold_out

      entity Slot, means: "one place in a jar's rack" do
        has tea : String
      end
    end

    specification Full, on: Jar, where: {count: Count.new(5)..}, means: "a jar of five or more"
    specification Odd, on: Jar, where: {count: "five"}, means: "a jar counted in words"
  end
end
