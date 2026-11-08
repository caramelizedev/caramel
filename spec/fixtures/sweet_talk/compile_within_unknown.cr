require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  within Ordering do
    value Tins, Int32, means: "a count of tins"
  end

  context Ordering, means: "choosing teas and checking out" do
  end
end

SweetTalk.boot
