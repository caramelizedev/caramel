require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  context Shelf, means: "a shelf for trying the rules" do
    aggregate Tin, means: "a tin of tea" do
      has grams : Int32
    end

    aggregate Jar, means: "a jar of loose tea" do
      has label : String
      has slots : Array(Slot)

      entity Slot, means: "one place in a jar's rack" do
        has tea : String
        has grams : Int32
      end

      sums grams_total, of: Tin.grams
    end
  end
end
