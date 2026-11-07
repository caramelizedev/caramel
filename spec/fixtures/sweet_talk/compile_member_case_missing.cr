require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    value Roast, String, one_of: %w[light medium dark], means: "how far a tea is roasted"
  end
end

# A label for each roast that misses dark, added to the list after the label was written.
def roast_label(roast : Shop::Ordering::Roast) : String
  case roast.member
  in .light?  then "Light"
  in .medium? then "Medium"
  end
end

roast_label(Shop::Ordering::Roast.dark)
SweetTalk.boot
