# The tea house's strategic design (ADRs 0036 and 0044): subdomains, a calendar and a money
# kernel that Pricing and Billing share, a published language that a follower and a border
# read, and a border with an outside card gateway, which the specs fake at the wire with
# Corretto.stub_wire.
require "../../../src/caramel/sweet_talk"

module TeaHouse
  include SweetTalk

  kernel Calendar, shared_by: [Money, Pricing, Billing],
    means: "the days the tea house counts in" do
    value Day, Date, means: "a calendar day"
  end

  kernel Money, shared_by: [Pricing, Billing], shares: Calendar,
    means: "the money pricing and billing agree on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"

    aggregate Voucher, means: "an amount off one tea's bill, spent once" do
      has amount : Cents
      has expires_on : Calendar::Day?
      moves unspent >> spent

      event Spent, tea : Int64, on : Calendar::Day, carries: [amount, expires_on],
        means: "a member spent a voucher on a tea"

      finds expiring(from : Calendar::Day, to : Calendar::Day), where: {expires_on: from..to}

      to spend(tea : Int64, on : Calendar::Day) do
        expiry = expires_on
        refuse "A voucher cannot be spent after it expires." if expiry && on > expiry
        spent!
        emit Spent, tea: tea, on: on
      end
    end
  end

  context Pricing, shares: [Money, Calendar], subdomain: :supporting,
    means: "what each tea costs" do
    aggregate Tea, means: "one tea and its price" do
      has name : String
      has price : Money::Cents

      event Repriced, price : Money::Cents, means: "a tea's price changed"

      to reprice(price : Money::Cents) do
        @price = price
        emit Repriced, price: price
      end
    end

    service price_of(tea : Tea::Id), returns: Money::Cents, means: "what one tea costs today" do
      Tea.find(tea).price
    end

    service teas_priced, returns: Int32, means: "how many teas have a price" do
      Tea.all.size
    end

    service give(amount : Money::Cents, expires_on : Calendar::Day?), returns: Money::Voucher::Id,
      means: "give a member an amount off one tea" do
      Money::Voucher.create(amount: amount, expires_on: expires_on).id
    end

    publishes Tea::Id, price_of
  end

  context Billing, follows: Pricing, shares: [Money, Calendar], subdomain: :core,
    means: "charging members for their teas" do
    value Reference, String, length: 1..64, means: "the card gateway's name for one charge"

    aggregate Bill, means: "what a member owes for one tea" do
      has amount : Money::Cents
      has reference : String = ""
      moves open >> charged, open >> declined

      event Opened, amount : Money::Cents, means: "a member owes for a tea"

      factory open(amount : Money::Cents) do
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

    service spend(voucher : Money::Voucher::Id, tea : Pricing::Tea::Id, on : Calendar::Day),
      means: "spend a voucher on one tea" do
      Money::Voucher.find(voucher).spend(tea.raw, on)
    end

    whenever Money::Voucher::Spent do |spent|
      Bill.open(Pricing.price_of(Pricing::Tea::Id.new(spent.tea)) - spent.amount)
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

      def self.charge(bill : Int64, amount : Money::Cents) : Reference
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
