require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  requirements "AC-1"

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"

    calculation share(total : Cents, parts : Int32), returns: Cents,
      means: "one part of a total" do
      never "a part is more than the total", assures: "AC-9" do
        result > total
      end
      total
    end
  end
end

SweetTalk.boot
