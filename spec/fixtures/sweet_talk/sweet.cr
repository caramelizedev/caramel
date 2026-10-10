require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String

      to rename(name : String) do
        @name = name
      end
    end
  end
end

# Never runs, but compiles the command in.
if ARGV.includes?("--never")
  Shop::Catalogue::Tea.find(Shop::Catalogue::Tea::Id.new(1_i64)).rename "Sencha"
end
puts "sweet"
