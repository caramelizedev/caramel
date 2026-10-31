require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"
    value Dose, Int32, within: 1..10, means: "spoons of tea in one brew"

    aggregate Jar, means: "a jar of loose tea" do
      has label : String
      has count : Count
      has dose : Dose
      has opened_at : Time
      has slots : Array(Slot)
      moves on_shelf >> sold_out

      entity Slot, means: "one place in a jar's rack" do
        has tea : String
        has grams : Int32
        has brewed_at : Time
      end

      groups grams_by_tea, of: Slot.grams, by: :label
    end

    aggregate Tin, means: "a tin of tea" do
      has grams : Int32
    end
  end
end
