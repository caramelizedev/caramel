# The tea house's strategic design (ADR 0036): subdomains, a published language that a
# follower and a border read, and a border with an outside card gateway, which the specs
# fake at the wire with Corretto.stub_wire.
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

    service price_of(tea : Tea::Id), returns: Cents, means: "what one tea costs today" do
      Tea.find(tea).price
    end

    service teas_priced, returns: Int32, means: "how many teas have a price" do
      Tea.all.size
    end

    publishes Cents, Tea::Id, price_of
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

    service bill(tea : Pricing::Tea::Id), returns: Bill::Id,
      means: "bill a member for one tea at today's price" do
      Bill.open(Pricing.price_of(tea)).id
    end

    whenever Bill::Opened do |opened|
      reference = Cards.charge(opened.bill_id.raw, opened.amount)
      Bill.find(opened.bill_id).settle reference
    end

    compensate Bill::Opened do |opened, refusal|
      Bill.find(opened.bill_id).decline
    end

    border Cards, outside: "the card gateway we charge through" do
      CHARGES = "https://cards.example/v1/charges"

      def self.charge(bill : Int64, amount : Pricing::Cents) : Reference
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        body = {bill: bill, amount: amount.raw}.to_json
        response = Caramel::Outbound.post(CHARGES, headers, body)
        case response.status_code
        when 200 then Reference.new(JSON.parse(response.body)["id"].as_s)
        when 402 then raise SweetTalk::Refusal.new("The card was declined.")
        else          raise "Cards answered #{response.status_code}: #{response.body}"
        end
      end
    end
  end

  context Insurance, subdomain: :generic,
    means: "insuring parcels for what their teas cost" do
    aggregate Cover, means: "what one tea's parcels are insured for" do
      has tea : Int64
      has cents : Int64
    end

    border Pricing do
      whenever Pricing::Tea::Repriced do |repriced|
        Cover.create(tea: repriced.tea_id.raw, cents: Pricing.price_of(repriced.tea_id).raw)
      end
    end
  end
end
