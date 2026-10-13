# The tea house's strategic design (ADR 0036): one context per subdomain.
require "../../../src/caramel/sweet_talk"

module TeaHouse
  include SweetTalk

  context Pricing, subdomain: :supporting, means: "what each tea costs" do
    value Cents, Int64, at_least: 0, means: "an amount of money"

    aggregate Tea, means: "one tea and its price" do
      has name : String
      has price : Cents

      event Repriced, price : Cents, means: "a tea's price changed"

      to reprice(price : Cents) do
        @price = price
        emit Repriced, price: price
      end
    end
  end

  context Billing, follows: Pricing, subdomain: :core,
    means: "charging members for their teas" do
    value Reference, String, length: 1..64, means: "the card gateway's name for one charge"

    aggregate Bill, means: "what a member owes for one tea" do
      has amount : Pricing::Cents
      has reference : String = ""
      moves open >> charged, open >> declined

      event Opened, amount : Pricing::Cents, means: "a member owes for a tea"

      factory open(amount : Pricing::Cents) do
        emit Opened, amount: amount
      end

      to settle(reference : Reference) do
        charged!
        @reference = reference.raw
      end

      to decline do
        declined!
      end
    end
  end

  context Insurance, subdomain: :generic,
    means: "insuring parcels for what their teas cost" do
    aggregate Cover, means: "what one tea's parcels are insured for" do
      has tea : Int64
      has cents : Int64
    end
  end
end
